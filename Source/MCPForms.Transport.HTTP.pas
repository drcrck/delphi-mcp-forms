unit MCPForms.Transport.HTTP;

{ delphi-mcp-forms - MCP "Streamable HTTP" transport on localhost (Indy).

  POST /mcp   one JSON-RPC message -> application/json response, or 202
              Accepted for notifications. The response to "initialize" carries
              an Mcp-Session-Id header; a client that sends it back gets a
              session, and with it notifications and resource subscriptions.
  GET  /mcp   with Mcp-Session-Id: a Server-Sent Events stream of the server's
              notifications (tools/list_changed, resources/list_changed,
              resources/updated). One stream per session; a new one replaces it.
  DELETE /mcp with Mcp-Session-Id: ends the session.

  Clients that never send the session id keep working, without notifications.

  Binds to 127.0.0.1 only, rejects browser requests from foreign origins
  (DNS rebinding) and can require a bearer token.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  IdContext, IdCustomHTTPServer, IdHTTPServer,
  MCPForms.Core;

type
  TMCPHttpServer = class
  private
    FServer: TIdHTTPServer;
    FContext: TModelContext;
    FPort: Word;
    FPath: string;
    FToken: string;
    FStopping: Boolean;
    FSessionLock: TCriticalSection;
    FSessions: TDictionary<string, IMCPSession>;
    procedure HandleRequest(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePost(ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo; const SessionId: string);
    procedure HandleStream(AContext: TIdContext; AResponseInfo: TIdHTTPResponseInfo;
      const SessionId: string);
    procedure HandleDelete(AResponseInfo: TIdHTTPResponseInfo; const SessionId: string);
    function FindSession(const Id: string): IMCPSession;
    procedure CloseSessions;
    function OriginAllowed(const Origin: string): Boolean;
    function GetActive: Boolean;
    procedure SendText(AResponseInfo: TIdHTTPResponseInfo; Code: Integer;
      const ContentType, Text: string);
  public
    constructor Create(APort: Word = 8765; AContext: TModelContext = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Url: string;
    property Active: Boolean read GetActive;
    property Port: Word read FPort write FPort;
    /// Endpoint path, default '/mcp'.
    property Path: string read FPath write FPath;
    /// When set, clients must send "Authorization: Bearer <Token>".
    property Token: string read FToken write FToken;
  end;

implementation

uses
  System.JSON, IdGlobal;

const
  SessionHeader = 'Mcp-Session-Id';
  /// Messages kept for a session while no stream is connected.
  MaxQueued = 200;
  /// A session with no stream and no request for this long is dropped.
  SessionIdleMs = 30 * 60 * 1000;
  KeepAliveMs = 15000;

type
  THttpSession = class(TInterfacedObject, IMCPSession)
  private
    FId: string;
    FLock: TCriticalSection;
    FQueue: TQueue<string>;
    FSignal: TEvent;
    FClosed: Boolean;
    FLastSeen: UInt64;
    FStreamGen: Integer;
    FStreaming: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Send(const MessageJSON: string);
    function Alive: Boolean;
    procedure Touch;
    procedure Close;
    function TakeAll: TArray<string>;
    property Id: string read FId;
  end;

{ THttpSession }

constructor THttpSession.Create;
begin
  inherited Create;
  FId := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').ToLower;
  FLock := TCriticalSection.Create;
  FQueue := TQueue<string>.Create;
  FSignal := TEvent.Create(nil, False, False, '');
  Touch;
end;

destructor THttpSession.Destroy;
begin
  FSignal.Free;
  FQueue.Free;
  FLock.Free;
  inherited;
end;

procedure THttpSession.Send(const MessageJSON: string);
begin
  FLock.Enter;
  try
    if FClosed then
      Exit;
    FQueue.Enqueue(MessageJSON);
    while FQueue.Count > MaxQueued do
      FQueue.Dequeue;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

function THttpSession.Alive: Boolean;
begin
  FLock.Enter;
  try
    Result := not FClosed and (FStreaming or (TThread.GetTickCount64 - FLastSeen < SessionIdleMs));
  finally
    FLock.Leave;
  end;
end;

procedure THttpSession.Touch;
begin
  FLastSeen := TThread.GetTickCount64;
end;

procedure THttpSession.Close;
begin
  FLock.Enter;
  try
    FClosed := True;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

function THttpSession.TakeAll: TArray<string>;
begin
  FLock.Enter;
  try
    Result := FQueue.ToArray;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
end;

{ TMCPHttpServer }

constructor TMCPHttpServer.Create(APort: Word; AContext: TModelContext);
begin
  inherited Create;
  FPort := APort;
  FPath := '/mcp';
  FContext := AContext;
  if FContext = nil then
    FContext := ModelContext;
  FSessionLock := TCriticalSection.Create;
  FSessions := TDictionary<string, IMCPSession>.Create;
  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := HandleRequest;
  FServer.OnCommandOther := HandleRequest;
  FServer.KeepAlive := True;
  FServer.ParseParams := False;
end;

destructor TMCPHttpServer.Destroy;
begin
  Stop;
  FServer.Free;
  FSessions.Free;
  FSessionLock.Free;
  inherited;
end;

procedure TMCPHttpServer.Start;
begin
  if FServer.Active then
    Exit;
  FStopping := False;
  FServer.Bindings.Clear;
  with FServer.Bindings.Add do
  begin
    IP := '127.0.0.1';
    Port := FPort;
  end;
  FServer.DefaultPort := FPort;
  FServer.Active := True;
  FContext.Log('MCP server listening on ' + Url);
end;

procedure TMCPHttpServer.Stop;
begin
  if not FServer.Active then
    Exit;
  FStopping := True;
  // End the event streams and release worker threads waiting on the main
  // thread before Indy joins them.
  CloseSessions;
  FContext.CancelPending('The MCP server is stopping.');
  FServer.Active := False;
end;

procedure TMCPHttpServer.CloseSessions;
var
  S: IMCPSession;
  All: TArray<IMCPSession>;
begin
  FSessionLock.Enter;
  try
    All := FSessions.Values.ToArray;
    FSessions.Clear;
  finally
    FSessionLock.Leave;
  end;
  for S in All do
  begin
    FContext.DetachSession(S);
    THttpSession(S).Close;
  end;
end;

function TMCPHttpServer.FindSession(const Id: string): IMCPSession;
begin
  FSessionLock.Enter;
  try
    if not FSessions.TryGetValue(Id, Result) then
      Result := nil;
  finally
    FSessionLock.Leave;
  end;
end;

function TMCPHttpServer.GetActive: Boolean;
begin
  Result := FServer.Active;
end;

function TMCPHttpServer.Url: string;
begin
  Result := Format('http://127.0.0.1:%d%s', [FPort, FPath]);
end;

function TMCPHttpServer.OriginAllowed(const Origin: string): Boolean;
var
  Host: string;
  P: Integer;
begin
  // Origin looks like "http://localhost:3000"
  Host := LowerCase(Origin);
  P := Pos('://', Host);
  if P = 0 then
    Exit(False);
  Delete(Host, 1, P + 2);
  if (Host <> '') and (Host[1] = '[') then
  begin
    P := Pos(']', Host);
    Host := Copy(Host, 1, P);
  end
  else
  begin
    P := Pos(':', Host);
    if P > 0 then
      Host := Copy(Host, 1, P - 1);
    P := Pos('/', Host);
    if P > 0 then
      Host := Copy(Host, 1, P - 1);
  end;
  Result := (Host = 'localhost') or (Host = '127.0.0.1') or (Host = '[::1]');
end;

procedure TMCPHttpServer.SendText(AResponseInfo: TIdHTTPResponseInfo; Code: Integer;
  const ContentType, Text: string);
begin
  AResponseInfo.ResponseNo := Code;
  AResponseInfo.ContentType := ContentType;
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentStream := TStringStream.Create(Text, TEncoding.UTF8);
  AResponseInfo.FreeContentStream := True;
end;

procedure TMCPHttpServer.HandleRequest(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Doc, Origin, SessionId: string;
begin
  Doc := ARequestInfo.Document;
  if (Doc <> FPath) and (Doc <> FPath + '/') then
  begin
    SendText(AResponseInfo, 404, 'text/plain', 'Not found');
    Exit;
  end;

  Origin := ARequestInfo.RawHeaders.Values['Origin'];
  if (Origin <> '') and not OriginAllowed(Origin) then
  begin
    SendText(AResponseInfo, 403, 'text/plain', 'Origin not allowed');
    Exit;
  end;

  if (FToken <> '') and
     (ARequestInfo.RawHeaders.Values['Authorization'] <> 'Bearer ' + FToken) then
  begin
    AResponseInfo.CustomHeaders.Values['WWW-Authenticate'] := 'Bearer';
    SendText(AResponseInfo, 401, 'text/plain', 'Unauthorized');
    Exit;
  end;

  if FStopping then
  begin
    SendText(AResponseInfo, 503, 'text/plain', 'Server stopping');
    Exit;
  end;

  SessionId := Trim(ARequestInfo.RawHeaders.Values[SessionHeader]);
  case ARequestInfo.CommandType of
    hcPOST:
      HandlePost(ARequestInfo, AResponseInfo, SessionId);
    hcGET:
      HandleStream(AContext, AResponseInfo, SessionId);
    hcDELETE:
      HandleDelete(AResponseInfo, SessionId);
  else
    AResponseInfo.CustomHeaders.Values['Allow'] := 'GET, POST, DELETE';
    SendText(AResponseInfo, 405, 'text/plain', 'Method not allowed');
  end;
end;

function IsInitialize(const Body: string): Boolean;
var
  V: TJSONValue;
  M: string;
begin
  V := TJSONObject.ParseJSONValue(Body);
  try
    Result := (V is TJSONObject) and TJSONObject(V).TryGetValue<string>('method', M) and
      (M = 'initialize');
  finally
    V.Free;
  end;
end;

procedure TMCPHttpServer.HandlePost(ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo; const SessionId: string);
var
  Body, Reply: string;
  Bytes: TBytes;
  Session: IMCPSession;
  NewSession: THttpSession;
  Old: TPair<string, IMCPSession>;
begin
  Body := '';
  if (ARequestInfo.PostStream <> nil) and (ARequestInfo.PostStream.Size > 0) then
  begin
    SetLength(Bytes, ARequestInfo.PostStream.Size);
    ARequestInfo.PostStream.Position := 0;
    ARequestInfo.PostStream.ReadBuffer(Bytes[0], Length(Bytes));
    Body := TEncoding.UTF8.GetString(Bytes);
  end;

  Session := nil;
  if SessionId <> '' then
  begin
    Session := FindSession(SessionId);
    if Session = nil then
    begin
      // expired or unknown: the client starts again with initialize
      SendText(AResponseInfo, 404, 'text/plain', 'Session not found');
      Exit;
    end;
    THttpSession(Session).Touch;
  end
  else if IsInitialize(Body) then
  begin
    NewSession := THttpSession.Create;
    Session := NewSession;
    FSessionLock.Enter;
    try
      // forget the sessions of clients that went away
      for Old in FSessions.ToArray do
        if not Old.Value.Alive then
        begin
          FSessions.Remove(Old.Key);
          FContext.DetachSession(Old.Value);
        end;
      FSessions.Add(NewSession.Id, Session);
    finally
      FSessionLock.Leave;
    end;
    AResponseInfo.CustomHeaders.Values[SessionHeader] := NewSession.Id;
  end;

  Reply := FContext.HandleMessage(Body, Session);
  if Reply = '' then
  begin
    AResponseInfo.ResponseNo := 202;
    AResponseInfo.ContentText := '';
  end
  else
    SendText(AResponseInfo, 200, 'application/json', Reply);
end;

procedure TMCPHttpServer.HandleStream(AContext: TIdContext;
  AResponseInfo: TIdHTTPResponseInfo; const SessionId: string);
var
  Session: IMCPSession;
  S: THttpSession;
  Gen: Integer;
  Msg: string;

  procedure WriteChunk(const Text: string);
  var
    Bytes: TBytes;
  begin
    // the response is chunked: an event stream has no length
    Bytes := TEncoding.UTF8.GetBytes(Text);
    AContext.Connection.IOHandler.Write(IntToHex(Length(Bytes), 1) + #13#10);
    AContext.Connection.IOHandler.Write(TIdBytes(Bytes));
    AContext.Connection.IOHandler.Write(#13#10);
  end;

begin
  if SessionId = '' then
  begin
    SendText(AResponseInfo, 400, 'text/plain', 'The ' + SessionHeader +
      ' header is required: send initialize first.');
    Exit;
  end;
  Session := FindSession(SessionId);
  if Session = nil then
  begin
    SendText(AResponseInfo, 404, 'text/plain', 'Session not found');
    Exit;
  end;
  S := THttpSession(Session);
  Gen := TInterlocked.Increment(S.FStreamGen); // a newer stream ends this one
  S.FStreaming := True;
  S.FSignal.SetEvent; // wake an older stream so it sees it was replaced

  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentType := 'text/event-stream';
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.TransferEncoding := 'chunked';
  AResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  AResponseInfo.CustomHeaders.Values[SessionHeader] := SessionId;
  AResponseInfo.CloseConnection := True;
  AResponseInfo.WriteHeader;
  try
    try
      WriteChunk(': connected'#10#10);
      while not FStopping and not S.FClosed and (S.FStreamGen = Gen) and
            AContext.Connection.Connected do
      begin
        for Msg in S.TakeAll do
          WriteChunk('event: message'#10'data: ' + Msg + #10#10);
        if S.FSignal.WaitFor(KeepAliveMs) = wrTimeout then
          WriteChunk(': keepalive'#10#10);
        S.Touch;
      end;
      if AContext.Connection.Connected then
        AContext.Connection.IOHandler.Write('0'#13#10#13#10);
    except
      // the client went away
    end;
  finally
    if S.FStreamGen = Gen then
    begin
      S.FStreaming := False;
      S.Touch;
    end;
  end;
end;

procedure TMCPHttpServer.HandleDelete(AResponseInfo: TIdHTTPResponseInfo;
  const SessionId: string);
var
  Session: IMCPSession;
begin
  Session := FindSession(SessionId);
  if Session = nil then
  begin
    SendText(AResponseInfo, 404, 'text/plain', 'Session not found');
    Exit;
  end;
  FSessionLock.Enter;
  try
    FSessions.Remove(SessionId);
  finally
    FSessionLock.Leave;
  end;
  FContext.DetachSession(Session);
  THttpSession(Session).Close;
  AResponseInfo.ResponseNo := 200;
  AResponseInfo.ContentText := '';
end;

end.
