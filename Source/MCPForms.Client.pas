unit MCPForms.Client;

{ delphi-mcp-forms - an MCP client.

  TMCPClient speaks MCP (JSON-RPC) through a transport: initialize, tools,
  resources, subscriptions and notifications. It is how the in-app assistant
  (MCPForms.Claude) reaches the forms - the same protocol and the same tools an
  external client such as Claude Code gets, not a shortcut.

  TMCPInProcessTransport talks to the TModelContext of this process: no port,
  no window, and it is a session, so it receives notifications.

  Every call blocks until the server answers, and a form tool answers only when
  the user saves the form: call the client from a worker thread, never from the
  main thread.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  System.Generics.Collections,
  MCPForms.Core;

type
  EMCPClientError = class(Exception);

  /// Moves JSON-RPC messages to a server and back.
  IMCPClientTransport = interface
    ['{5E1A7C93-2D84-4B6F-A3C9-8F0D1E2B7A46}']
    /// Sends one message and returns the response ('' for a notification).
    /// Blocks.
    function Request(const MessageJSON: string): string;
    /// Messages the server sends on its own. Called from any thread.
    procedure SetNotificationHandler(const Handler: TProc<string>);
    procedure Close;
  end;

  /// The server of this process (ModelContext), reached directly.
  TMCPInProcessTransport = class(TInterfacedObject, IMCPClientTransport, IMCPSession)
  private
    FContext: TModelContext;
    FLock: TCriticalSection;
    FHandler: TProc<string>;
    FClosed: Boolean;
  public
    constructor Create(AContext: TModelContext = nil);
    destructor Destroy; override;
    { IMCPClientTransport }
    function Request(const MessageJSON: string): string;
    procedure SetNotificationHandler(const Handler: TProc<string>);
    procedure Close;
    { IMCPSession: the server talks to us }
    procedure Send(const MessageJSON: string);
    function Alive: Boolean;
  end;

  TMCPClientTool = record
    Name: string;
    Title: string;
    Description: string;
    /// The input JSON Schema, as JSON text.
    InputSchema: string;
    ReadOnly: Boolean;
    Destructive: Boolean;
  end;

  TMCPToolResult = record
    /// The text blocks of the result, joined.
    Text: string;
    IsError: Boolean;
  end;

  /// Method and params of a notification. Called from any thread.
  TMCPNotificationProc = reference to procedure(const Method: string; Params: TJSONObject);

  TMCPClient = class
  private
    FTransport: IMCPClientTransport;
    FNextId: Integer;
    FServerName: string;
    FServerVersion: string;
    FInstructions: string;
    FCapabilities: TJSONObject;
    FOnNotification: TMCPNotificationProc;
    procedure HandleNotification(const MessageJSON: string);
    /// The "result" of a request, owned by the caller. Raises EMCPClientError
    /// on a JSON-RPC error.
    function Call(const Method: string; Params: TJSONObject = nil): TJSONValue;
  public
    /// Takes the transport. In-process when nil.
    constructor Create(const ATransport: IMCPClientTransport = nil);
    destructor Destroy; override;
    procedure Initialize(const ClientName: string = 'delphi-mcp-forms';
      const ClientVersion: string = MCPFormsVersion);
    function ListTools: TArray<TMCPClientTool>;
    /// Args is not taken.
    function CallTool(const Name: string; Args: TJSONObject): TMCPToolResult;
    function ListResources: TArray<TMCPResourceInfo>;
    function ReadResource(const Uri: string; out MimeType: string): string;
    procedure Subscribe(const Uri: string);
    procedure Unsubscribe(const Uri: string);
    /// True when the server offers resource subscriptions to this client.
    function CanSubscribe: Boolean;
    property ServerName: string read FServerName;
    property ServerVersion: string read FServerVersion;
    property Instructions: string read FInstructions;
    property OnNotification: TMCPNotificationProc read FOnNotification write FOnNotification;
  end;

implementation

{ TMCPInProcessTransport }

constructor TMCPInProcessTransport.Create(AContext: TModelContext);
begin
  inherited Create;
  FContext := AContext;
  if FContext = nil then
    FContext := ModelContext;
  FLock := TCriticalSection.Create;
end;

destructor TMCPInProcessTransport.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMCPInProcessTransport.Request(const MessageJSON: string): string;
begin
  if FClosed then
    raise EMCPClientError.Create('The connection is closed.');
  Result := FContext.HandleMessage(MessageJSON, Self);
end;

procedure TMCPInProcessTransport.SetNotificationHandler(const Handler: TProc<string>);
begin
  FLock.Enter;
  try
    FHandler := Handler;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPInProcessTransport.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  SetNotificationHandler(nil);
  FContext.DetachSession(Self);
end;

procedure TMCPInProcessTransport.Send(const MessageJSON: string);
var
  H: TProc<string>;
begin
  FLock.Enter;
  try
    H := FHandler;
  finally
    FLock.Leave;
  end;
  if Assigned(H) and not FClosed then
    H(MessageJSON);
end;

function TMCPInProcessTransport.Alive: Boolean;
begin
  Result := not FClosed;
end;

{ TMCPClient }

constructor TMCPClient.Create(const ATransport: IMCPClientTransport);
begin
  inherited Create;
  FTransport := ATransport;
  if FTransport = nil then
    FTransport := TMCPInProcessTransport.Create;
  FTransport.SetNotificationHandler(
    procedure(Msg: string)
    begin
      HandleNotification(Msg);
    end);
end;

destructor TMCPClient.Destroy;
begin
  if FTransport <> nil then
    FTransport.Close;
  FTransport := nil;
  FCapabilities.Free;
  inherited;
end;

procedure TMCPClient.HandleNotification(const MessageJSON: string);
var
  V: TJSONValue;
  Method: string;
  Params: TJSONObject;
begin
  if not Assigned(FOnNotification) then
    Exit;
  V := TJSONObject.ParseJSONValue(MessageJSON);
  try
    if (V is TJSONObject) and TJSONObject(V).TryGetValue<string>('method', Method) then
    begin
      Params := TJSONObject(V).GetValue('params') as TJSONObject;
      FOnNotification(Method, Params);
    end;
  finally
    V.Free;
  end;
end;

function TMCPClient.Call(const Method: string; Params: TJSONObject): TJSONValue;
var
  Req: TJSONObject;
  Reply: string;
  V, Err: TJSONValue;
  Msg: string;
begin
  Req := TJSONObject.Create;
  try
    Req.AddPair('jsonrpc', '2.0');
    Req.AddPair('id', TJSONNumber.Create(TInterlocked.Increment(FNextId)));
    Req.AddPair('method', Method);
    if Params <> nil then
      Req.AddPair('params', Params.Clone as TJSONObject);
    Reply := FTransport.Request(Req.ToJSON);
  finally
    Req.Free;
  end;
  V := TJSONObject.ParseJSONValue(Reply);
  try
    if not (V is TJSONObject) then
      raise EMCPClientError.CreateFmt('%s: the server sent no valid response.', [Method]);
    Err := TJSONObject(V).GetValue('error');
    if Err is TJSONObject then
    begin
      if not TJSONObject(Err).TryGetValue<string>('message', Msg) then
        Msg := Err.ToJSON;
      raise EMCPClientError.Create(Msg);
    end;
    Result := TJSONObject(V).GetValue('result');
    if Result = nil then
      raise EMCPClientError.CreateFmt('%s: the response has no result.', [Method]);
    Result := Result.Clone as TJSONValue;
  finally
    V.Free;
  end;
end;

procedure TMCPClient.Initialize(const ClientName, ClientVersion: string);
var
  Params, Info, Server: TJSONObject;
  R: TJSONValue;
  Caps: TJSONValue;
  Note: TJSONObject;
begin
  Params := TJSONObject.Create;
  try
    Params.AddPair('protocolVersion', MCPProtocolVersions[0]);
    Params.AddPair('capabilities', TJSONObject.Create);
    Info := TJSONObject.Create;
    Info.AddPair('name', ClientName);
    Info.AddPair('version', ClientVersion);
    Params.AddPair('clientInfo', Info);
    R := Call('initialize', Params);
  finally
    Params.Free;
  end;
  try
    if R is TJSONObject then
    begin
      Server := TJSONObject(R).GetValue('serverInfo') as TJSONObject;
      if Server <> nil then
      begin
        Server.TryGetValue<string>('name', FServerName);
        Server.TryGetValue<string>('version', FServerVersion);
      end;
      TJSONObject(R).TryGetValue<string>('instructions', FInstructions);
      Caps := TJSONObject(R).GetValue('capabilities');
      FreeAndNil(FCapabilities);
      if Caps is TJSONObject then
        FCapabilities := Caps.Clone as TJSONObject;
    end;
  finally
    R.Free;
  end;
  Note := TJSONObject.Create;
  try
    Note.AddPair('jsonrpc', '2.0');
    Note.AddPair('method', 'notifications/initialized');
    FTransport.Request(Note.ToJSON);
  finally
    Note.Free;
  end;
end;

function TMCPClient.CanSubscribe: Boolean;
var
  Res: TJSONValue;
  B: Boolean;
begin
  Result := False;
  if FCapabilities = nil then
    Exit;
  Res := FCapabilities.GetValue('resources');
  if (Res is TJSONObject) and TJSONObject(Res).TryGetValue<Boolean>('subscribe', B) then
    Result := B;
end;

function TMCPClient.ListTools: TArray<TMCPClientTool>;
var
  R, Schema: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONValue;
  O, Ann: TJSONObject;
  T: TMCPClientTool;
begin
  Result := nil;
  R := Call('tools/list');
  try
    Arr := TJSONObject(R).GetValue('tools') as TJSONArray;
    if Arr = nil then
      Exit;
    for Item in Arr do
    begin
      O := Item as TJSONObject;
      T := Default(TMCPClientTool);
      O.TryGetValue<string>('name', T.Name);
      O.TryGetValue<string>('title', T.Title);
      O.TryGetValue<string>('description', T.Description);
      Schema := O.GetValue('inputSchema');
      if Schema <> nil then
        T.InputSchema := Schema.ToJSON
      else
        T.InputSchema := '{"type":"object","properties":{}}';
      Ann := O.GetValue('annotations') as TJSONObject;
      if Ann <> nil then
      begin
        Ann.TryGetValue<Boolean>('readOnlyHint', T.ReadOnly);
        Ann.TryGetValue<Boolean>('destructiveHint', T.Destructive);
      end;
      Result := Result + [T];
    end;
  finally
    R.Free;
  end;
end;

function TMCPClient.CallTool(const Name: string; Args: TJSONObject): TMCPToolResult;
var
  Params: TJSONObject;
  R: TJSONValue;
  Content: TJSONArray;
  Item: TJSONValue;
  Kind, Text: string;
begin
  Params := TJSONObject.Create;
  try
    Params.AddPair('name', Name);
    if Args <> nil then
      Params.AddPair('arguments', Args.Clone as TJSONObject)
    else
      Params.AddPair('arguments', TJSONObject.Create);
    R := Call('tools/call', Params);
  finally
    Params.Free;
  end;
  try
    Result.IsError := False;
    TJSONObject(R).TryGetValue<Boolean>('isError', Result.IsError);
    Result.Text := '';
    Content := TJSONObject(R).GetValue('content') as TJSONArray;
    if Content <> nil then
      for Item in Content do
        if (Item is TJSONObject) and TJSONObject(Item).TryGetValue<string>('type', Kind) and
           (Kind = 'text') and TJSONObject(Item).TryGetValue<string>('text', Text) then
        begin
          if Result.Text <> '' then
            Result.Text := Result.Text + sLineBreak;
          Result.Text := Result.Text + Text;
        end;
  finally
    R.Free;
  end;
end;

function TMCPClient.ListResources: TArray<TMCPResourceInfo>;
var
  R: TJSONValue;
  Arr: TJSONArray;
  Item: TJSONValue;
  O: TJSONObject;
  Info: TMCPResourceInfo;
begin
  Result := nil;
  R := Call('resources/list');
  try
    Arr := TJSONObject(R).GetValue('resources') as TJSONArray;
    if Arr = nil then
      Exit;
    for Item in Arr do
    begin
      O := Item as TJSONObject;
      Info := Default(TMCPResourceInfo);
      O.TryGetValue<string>('uri', Info.Uri);
      O.TryGetValue<string>('name', Info.Name);
      O.TryGetValue<string>('title', Info.Title);
      O.TryGetValue<string>('description', Info.Description);
      O.TryGetValue<string>('mimeType', Info.MimeType);
      Result := Result + [Info];
    end;
  finally
    R.Free;
  end;
end;

function TMCPClient.ReadResource(const Uri: string; out MimeType: string): string;
var
  Params: TJSONObject;
  R: TJSONValue;
  Arr: TJSONArray;
begin
  Params := TJSONObject.Create;
  try
    Params.AddPair('uri', Uri);
    R := Call('resources/read', Params);
  finally
    Params.Free;
  end;
  try
    Result := '';
    MimeType := '';
    Arr := TJSONObject(R).GetValue('contents') as TJSONArray;
    if (Arr <> nil) and (Arr.Count > 0) and (Arr.Items[0] is TJSONObject) then
    begin
      TJSONObject(Arr.Items[0]).TryGetValue<string>('text', Result);
      TJSONObject(Arr.Items[0]).TryGetValue<string>('mimeType', MimeType);
    end;
  finally
    R.Free;
  end;
end;

procedure TMCPClient.Subscribe(const Uri: string);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  try
    Params.AddPair('uri', Uri);
    Call('resources/subscribe', Params).Free;
  finally
    Params.Free;
  end;
end;

procedure TMCPClient.Unsubscribe(const Uri: string);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  try
    Params.AddPair('uri', Uri);
    Call('resources/unsubscribe', Params).Free;
  finally
    Params.Free;
  end;
end;

end.
