unit MCPForms.Core;

{ delphi-mcp-forms
  WebMCP-style tools for Delphi applications, served over the Model Context
  Protocol (MCP).

  This unit has no VCL/FMX dependency. It holds the tool registry (the Delphi
  counterpart of WebMCP's document.modelContext), the resource providers, a
  JSON Schema builder and the MCP JSON-RPC dispatcher. Transports (see
  MCPForms.Transport.HTTP) only move strings in and out of
  TModelContext.HandleMessage; those that can also carry messages from the
  server to the client pass an IMCPSession, and then get notifications:
  tools/list_changed, resources/list_changed and resources/updated.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults;

const
  MCPFormsVersion = '0.1.0';
  /// Protocol revisions this server answers with, newest first.
  MCPProtocolVersions: array[0..2] of string = ('2025-11-25', '2025-06-18', '2025-03-26');

type
  /// Raise from a tool to return a descriptive error the model can act on.
  EMCPToolError = class(Exception);

  /// JSON-RPC level error (unknown tool, bad params...).
  EMCPProtocolError = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer; const AMessage: string);
    property Code: Integer read FCode;
  end;

  /// Same hints as WebMCP. Mapped to MCP annotations as:
  /// ReadOnlyHint -> readOnlyHint, ConsequentialHint -> destructiveHint,
  /// UntrustedContentHint -> openWorldHint.
  TMCPToolAnnotations = record
    ReadOnlyHint: Boolean;
    ConsequentialHint: Boolean;
    UntrustedContentHint: Boolean;
    class function None: TMCPToolAnnotations; static;
    class function ReadOnly: TMCPToolAnnotations; static;
    class function Consequential: TMCPToolAnnotations; static;
  end;

  /// Where Execute runs. mtMainThread is the safe default for code that
  /// touches VCL/FMX objects.
  TMCPThreading = (mtMainThread, mtCallerThread);

  TMCPExecuteFunc = reference to function(const Args: TJSONObject): string;
  TMCPSchemaFunc = reference to function: TJSONObject;

  IMCPTool = interface
    ['{6C1E2B57-3F0A-4D8E-9B61-2E7A5C4D9F10}']
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetAnnotations: TMCPToolAnnotations;
    function GetThreading: TMCPThreading;
    function HasDynamicSchema: Boolean;
    /// Returns a new schema object; the caller owns it.
    function NewInputSchema: TJSONObject;
    function Execute(const Args: TJSONObject): string;
    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property Annotations: TMCPToolAnnotations read GetAnnotations;
    property Threading: TMCPThreading read GetThreading;
  end;

  /// Full tool definition, the counterpart of the object passed to
  /// document.modelContext.registerTool(). Use TMCPToolDef.Create to get a
  /// properly initialised record.
  TMCPToolDef = record
    Name: string;
    Title: string;
    Description: string;
    /// Static schema. Ownership passes to the registry.
    InputSchema: TJSONObject;
    /// Alternative to InputSchema: built on demand, always on the main thread.
    SchemaFunc: TMCPSchemaFunc;
    Annotations: TMCPToolAnnotations;
    Threading: TMCPThreading;
    Execute: TMCPExecuteFunc;
    class function Create(const AName, ADescription: string;
      AInputSchema: TJSONObject; const AExecute: TMCPExecuteFunc): TMCPToolDef; static;
  end;

  /// A one-shot result slot a worker thread can wait on (like a JS Promise).
  IMCPAwaitable = interface
    ['{A4C0F7E2-5B1D-4E36-8C2A-9D7B3E1F6A05}']
    procedure Resolve(const Text: string);
    procedure Reject(const Msg: string);
    function Settled: Boolean;
    /// Blocks until settled or timed out. Raises EMCPToolError on reject/timeout.
    function Wait(TimeoutMs: Cardinal): string;
  end;

  /// One resource, as resources/list shows it.
  TMCPResourceInfo = record
    Uri: string;
    Name: string;
    Title: string;
    Description: string;
    MimeType: string;
  end;

  /// A set of resources that can change while the application runs (e.g. its
  /// open windows). Both methods run on the main thread.
  IMCPResourceProvider = interface
    ['{3B8E6A21-9C4F-4D7A-B5E2-1F0C8D6A4E93}']
    function ListResources: TArray<TMCPResourceInfo>;
    /// False when Uri is not one of this provider's resources.
    function ReadResource(const Uri: string; out MimeType, Text: string): Boolean;
  end;

  /// A client connection that can receive messages from the server. A
  /// transport implements it for each connected client and passes it to
  /// HandleMessage.
  IMCPSession = interface
    ['{9D2C4F7B-1E6A-4B83-A0D5-7C3E9F1B2A64}']
    /// Delivers one JSON-RPC message (a notification). Any thread.
    procedure Send(const MessageJSON: string);
    /// False once the client is gone: the session is then dropped.
    function Alive: Boolean;
  end;

  TMCPLogProc = reference to procedure(const Msg: string);
  /// Asked on the main thread before a tool with ConsequentialHint runs.
  TMCPConfirmFunc = reference to function(const Tool: IMCPTool; const Args: TJSONObject): Boolean;

  /// Fluent JSON Schema builder:
  ///   TMCPSchema.Create.Str('customer', 'Customer name', True).Int('qty', 'Quantity').Build
  /// Build returns the schema and frees the builder.
  TMCPSchema = class
  private
    FRoot: TJSONObject;
    FProps: TJSONObject;
    FRequired: TJSONArray;
    function Add(const Name, JsonType, Description: string; Required: Boolean): TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    function Str(const Name, Description: string; Required: Boolean = False): TMCPSchema;
    function Int(const Name, Description: string; Required: Boolean = False): TMCPSchema; overload;
    function Int(const Name, Description: string; Min, Max: Int64; Required: Boolean = False): TMCPSchema; overload;
    function Num(const Name, Description: string; Required: Boolean = False): TMCPSchema;
    function Bool(const Name, Description: string; Required: Boolean = False): TMCPSchema;
    function Enum(const Name, Description: string; const Values: array of string;
      Required: Boolean = False): TMCPSchema;
    /// Adds a raw property schema (ownership passes to the builder).
    function Prop(const Name: string; Schema: TJSONObject; Required: Boolean = False): TMCPSchema;
    function Build: TJSONObject;
    class function Empty: TJSONObject; static;
  end;

  TModelContext = class
  private
    FLock: TCriticalSection;
    FTools: TList<IMCPTool>;
    FPending: TList<IMCPAwaitable>;
    FServerName: string;
    FServerVersion: string;
    FInstructions: string;
    FConfirmHandler: TMCPConfirmFunc;
    FOnLog: TMCPLogProc;
    FOnToolChange: TProc;
    FToolChangeListeners: TDictionary<Integer, TProc>;
    FNextListenerId: Integer;
    FMainThreadTimeout: Cardinal;
    FProviders: TList<TPair<Integer, IMCPResourceProvider>>;
    FNextProviderId: Integer;
    FSessions: TObjectList<TObject>; // TMCPSessionState
    FWatcher: TThread;
    FResourcePollInterval: Cardinal;
    function FindState(const Session: IMCPSession): TObject;
    procedure SendToSessions(const MessageJSON: string; const OnlyUri: string = '');
    function HasLiveSessions: Boolean;
    function SubscribedUris: TArray<string>;
    function HandleResourcesList: TJSONObject;
    function HandleResourcesRead(Params: TJSONObject): TJSONObject;
    function HandleSubscribe(Params: TJSONObject; const Session: IMCPSession;
      Subscribe: Boolean): TJSONObject;
    function FindTool(const Name: string): IMCPTool;
    procedure ToolsChanged;
    function ErrorResponse(Id: TJSONValue; Code: Integer; const Msg: string): string;
    function HandleInitialize(Params: TJSONObject; WithSession: Boolean): TJSONObject;
    function HandleToolsList: TJSONObject;
    function HandleToolsCall(Params: TJSONObject): TJSONObject;
    function ToolToJSON(const Tool: IMCPTool): TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Log(const Msg: string);

    /// registerTool(). Raises if the name is invalid or already registered.
    function RegisterTool(const Def: TMCPToolDef): IMCPTool; overload;
    function RegisterTool(const Name, Description: string; InputSchema: TJSONObject;
      const Execute: TMCPExecuteFunc): IMCPTool; overload;
    function RegisterTool(const Name, Description: string; InputSchema: TJSONObject;
      const Annotations: TMCPToolAnnotations; const Execute: TMCPExecuteFunc): IMCPTool; overload;
    /// Removes a tool. Calls already running are not cancelled.
    procedure UnregisterTool(const Name: string);
    /// getTools(): alphabetical.
    function GetTools: TArray<IMCPTool>;
    /// executeTool(): runs a tool as if an agent called it.
    function ExecuteTool(const Name: string; const Args: TJSONObject; out IsError: Boolean): string;

    /// The whole MCP endpoint as a function: one JSON-RPC message in, the
    /// response out ('' for notifications). Call it from a worker thread:
    /// tools that wait for the user would block the main thread otherwise.
    /// Session: the connection the message came from, when the transport can
    /// send it notifications (it is attached on first use).
    function HandleMessage(const RequestJSON: string;
      const Session: IMCPSession = nil): string;

    /// Sessions receive notifications until they are detached or not Alive.
    procedure AttachSession(const Session: IMCPSession);
    procedure DetachSession(const Session: IMCPSession);

    /// resources/list and resources/read are answered by the providers, in
    /// registration order. Returns an id for UnregisterResourceProvider.
    function RegisterResourceProvider(const Provider: IMCPResourceProvider): Integer;
    procedure UnregisterResourceProvider(Id: Integer);
    /// All resources of all providers. Any thread.
    function ListResources: TArray<TMCPResourceInfo>;
    /// Text of a resource. Any thread. Raises EMCPProtocolError -32002 when
    /// no provider knows Uri.
    function ReadResource(const Uri: string; out MimeType: string): string;

    /// Sends a notification to every initialized session. Takes Params.
    procedure Notify(const Method: string; Params: TJSONObject = nil);
    /// The list of resources changed (notifications/resources/list_changed).
    /// Not needed for changes the poller sees.
    procedure ResourcesChanged;
    /// A resource changed (notifications/resources/updated to its subscribers).
    procedure ResourceUpdated(const Uri: string);

    /// Runs Func on the main thread and returns its result. Direct call when
    /// already on the main thread.
    function RunOnMainThread(const Func: TFunc<string>): string;
    function NewAwaitable: IMCPAwaitable;
    function WaitFor(const Awaitable: IMCPAwaitable; TimeoutMs: Cardinal): string;
    /// Rejects every pending wait (used when a transport shuts down).
    procedure CancelPending(const Reason: string);

    property ServerName: string read FServerName write FServerName;
    property ServerVersion: string read FServerVersion write FServerVersion;
    /// Optional text sent to the client in the initialize result.
    property Instructions: string read FInstructions write FInstructions;
    /// Like OnToolChange, for more than one listener (e.g. a transport that
    /// notifies its clients). Called from any thread. Returns an id for
    /// RemoveToolChangeListener.
    function AddToolChangeListener(const Listener: TProc): Integer;
    procedure RemoveToolChangeListener(Id: Integer);

    property ConfirmHandler: TMCPConfirmFunc read FConfirmHandler write FConfirmHandler;
    /// Called from any thread.
    property OnLog: TMCPLogProc read FOnLog write FOnLog;
    /// Called (from any thread) after a tool is registered or unregistered.
    property OnToolChange: TProc read FOnToolChange write FOnToolChange;
    property MainThreadTimeout: Cardinal read FMainThreadTimeout write FMainThreadTimeout;
    /// While a session is connected, the resource list and the subscribed
    /// resources are read every ResourcePollInterval ms (on the main thread)
    /// and the changes are notified. 0 turns polling off. Default 1000.
    property ResourcePollInterval: Cardinal read FResourcePollInterval write FResourcePollInterval;
  end;

/// The process-wide registry, like document.modelContext.
function ModelContext: TModelContext;

/// True when Name is a valid MCP tool name (1-64 chars: letters, digits, _ - .).
function MCPIsValidToolName(const Name: string): Boolean;

implementation

uses
  System.StrUtils;

{ EMCPProtocolError }

constructor EMCPProtocolError.Create(ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
end;

{ TMCPToolAnnotations }

class function TMCPToolAnnotations.None: TMCPToolAnnotations;
begin
  Result.ReadOnlyHint := False;
  Result.ConsequentialHint := False;
  Result.UntrustedContentHint := False;
end;

class function TMCPToolAnnotations.ReadOnly: TMCPToolAnnotations;
begin
  Result := None;
  Result.ReadOnlyHint := True;
end;

class function TMCPToolAnnotations.Consequential: TMCPToolAnnotations;
begin
  Result := None;
  Result.ConsequentialHint := True;
end;

{ TMCPToolDef }

class function TMCPToolDef.Create(const AName, ADescription: string;
  AInputSchema: TJSONObject; const AExecute: TMCPExecuteFunc): TMCPToolDef;
begin
  Result.Name := AName;
  Result.Title := '';
  Result.Description := ADescription;
  Result.InputSchema := AInputSchema;
  Result.SchemaFunc := nil;
  Result.Annotations := TMCPToolAnnotations.None;
  Result.Threading := mtMainThread;
  Result.Execute := AExecute;
end;

{ TMCPTool }

type
  TMCPTool = class(TInterfacedObject, IMCPTool)
  private
    FDef: TMCPToolDef;
  public
    constructor Create(const ADef: TMCPToolDef);
    destructor Destroy; override;
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetAnnotations: TMCPToolAnnotations;
    function GetThreading: TMCPThreading;
    function HasDynamicSchema: Boolean;
    function NewInputSchema: TJSONObject;
    function Execute(const Args: TJSONObject): string;
  end;

constructor TMCPTool.Create(const ADef: TMCPToolDef);
begin
  inherited Create;
  FDef := ADef;
end;

destructor TMCPTool.Destroy;
begin
  FDef.InputSchema.Free;
  inherited;
end;

function TMCPTool.GetName: string;
begin
  Result := FDef.Name;
end;

function TMCPTool.GetTitle: string;
begin
  Result := FDef.Title;
end;

function TMCPTool.GetDescription: string;
begin
  Result := FDef.Description;
end;

function TMCPTool.GetAnnotations: TMCPToolAnnotations;
begin
  Result := FDef.Annotations;
end;

function TMCPTool.GetThreading: TMCPThreading;
begin
  Result := FDef.Threading;
end;

function TMCPTool.HasDynamicSchema: Boolean;
begin
  Result := Assigned(FDef.SchemaFunc);
end;

function TMCPTool.NewInputSchema: TJSONObject;
begin
  if Assigned(FDef.SchemaFunc) then
    Result := FDef.SchemaFunc()
  else if FDef.InputSchema <> nil then
    Result := TJSONObject(FDef.InputSchema.Clone)
  else
    Result := nil;
  if Result = nil then
    Result := TMCPSchema.Empty;
end;

function TMCPTool.Execute(const Args: TJSONObject): string;
begin
  Result := FDef.Execute(Args);
end;

{ TMCPAwaitable }

type
  TMCPAwaitable = class(TInterfacedObject, IMCPAwaitable)
  private
    FEvent: TEvent;
    FState: Integer; // 0 = pending, 1 = settled
    FText: string;
    FIsError: Boolean;
    function Settle(const Text: string; IsError: Boolean): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Resolve(const Text: string);
    procedure Reject(const Msg: string);
    function Settled: Boolean;
    function Wait(TimeoutMs: Cardinal): string;
  end;

constructor TMCPAwaitable.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TMCPAwaitable.Destroy;
begin
  FEvent.Free;
  inherited;
end;

function TMCPAwaitable.Settle(const Text: string; IsError: Boolean): Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, 1, 0) = 0;
  if Result then
  begin
    FText := Text;
    FIsError := IsError;
    FEvent.SetEvent;
  end;
end;

procedure TMCPAwaitable.Resolve(const Text: string);
begin
  Settle(Text, False);
end;

procedure TMCPAwaitable.Reject(const Msg: string);
begin
  Settle(Msg, True);
end;

function TMCPAwaitable.Settled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, 0, 0) <> 0;
end;

function TMCPAwaitable.Wait(TimeoutMs: Cardinal): string;
begin
  if FEvent.WaitFor(TimeoutMs) <> wrSignaled then
    Settle('Timed out waiting for the application.', True);
  // Settled either by us or by another thread: both write before SetEvent.
  FEvent.WaitFor(INFINITE);
  if FIsError then
    raise EMCPToolError.Create(FText);
  Result := FText;
end;

{ Sessions and the resource watcher }

type
  TMCPSessionState = class
  public
    Session: IMCPSession;
    Initialized: Boolean;
    Subscriptions: TStringList;
    constructor Create(const ASession: IMCPSession);
    destructor Destroy; override;
  end;

  /// Reads the resource list and the subscribed resources every
  /// ResourcePollInterval ms and notifies what changed.
  TMCPResourceWatcher = class(TThread)
  private
    FContext: TModelContext;
    FWake: TEvent;
    FLastList: string;
    FHaveList: Boolean;
    FLast: TDictionary<string, string>;
    procedure Poll;
  protected
    procedure Execute; override;
  public
    constructor Create(AContext: TModelContext);
    destructor Destroy; override;
    procedure Stop;
  end;

constructor TMCPSessionState.Create(const ASession: IMCPSession);
begin
  inherited Create;
  Session := ASession;
  Subscriptions := TStringList.Create;
  Subscriptions.Sorted := True;
  Subscriptions.Duplicates := dupIgnore;
  Subscriptions.CaseSensitive := True;
end;

destructor TMCPSessionState.Destroy;
begin
  Subscriptions.Free;
  inherited;
end;

constructor TMCPResourceWatcher.Create(AContext: TModelContext);
begin
  FContext := AContext;
  FWake := TEvent.Create(nil, False, False, '');
  FLast := TDictionary<string, string>.Create;
  inherited Create(False);
end;

destructor TMCPResourceWatcher.Destroy;
begin
  inherited; // waits for Execute
  FLast.Free;
  FWake.Free;
end;

procedure TMCPResourceWatcher.Stop;
begin
  Terminate;
  FWake.SetEvent;
end;

procedure TMCPResourceWatcher.Execute;
var
  Interval: Cardinal;
begin
  NameThreadForDebugging('MCPForms resource watcher');
  while not Terminated do
  begin
    Interval := FContext.FResourcePollInterval;
    if Interval = 0 then
      Interval := 1000
    else if Interval < 100 then
      Interval := 100;
    FWake.WaitFor(Interval);
    if Terminated then
      Break;
    if (FContext.FResourcePollInterval = 0) or not FContext.HasLiveSessions then
    begin
      FHaveList := False;
      FLast.Clear;
      Continue;
    end;
    try
      Poll;
    except
      // the main thread may be busy or closing: try again next time
    end;
  end;
end;

procedure TMCPResourceWatcher.Poll;
var
  Uris: TArray<string>;
  ListKey: string;
  Contents: TArray<string>;
  Ctx: TModelContext;
  I: Integer;
  Old: string;
  Keep: TList<string>;
  K: string;
begin
  Ctx := FContext;
  Uris := Ctx.SubscribedUris;
  SetLength(Contents, Length(Uris));
  Ctx.RunOnMainThread(
    function: string
    var
      R: TMCPResourceInfo;
      J: Integer;
      Mime: string;
    begin
      ListKey := '';
      for R in Ctx.ListResources do
        ListKey := ListKey + R.Uri + #9 + R.Title + #10;
      for J := 0 to High(Uris) do
        try
          Contents[J] := Ctx.ReadResource(Uris[J], Mime);
        except
          Contents[J] := #0'missing';
        end;
      Result := '';
    end);
  if Terminated then
    Exit;

  if FHaveList and (ListKey <> FLastList) then
    Ctx.ResourcesChanged;
  FLastList := ListKey;
  FHaveList := True;

  for I := 0 to High(Uris) do
  begin
    if FLast.TryGetValue(Uris[I], Old) and (Old <> Contents[I]) then
      Ctx.ResourceUpdated(Uris[I]);
    FLast.AddOrSetValue(Uris[I], Contents[I]);
  end;
  // forget what nobody subscribes to any more
  Keep := TList<string>.Create;
  try
    Keep.AddRange(Uris);
    for K in FLast.Keys.ToArray do
      if not Keep.Contains(K) then
        FLast.Remove(K);
  finally
    Keep.Free;
  end;
end;

{ TMCPSchema }

constructor TMCPSchema.Create;
begin
  inherited Create;
  FRoot := TJSONObject.Create;
  FRoot.AddPair('type', 'object');
  FProps := TJSONObject.Create;
  FRoot.AddPair('properties', FProps);
  FRequired := TJSONArray.Create;
end;

destructor TMCPSchema.Destroy;
begin
  FRoot.Free;
  FRequired.Free;
  inherited;
end;

function TMCPSchema.Add(const Name, JsonType, Description: string; Required: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', JsonType);
  if Description <> '' then
    Result.AddPair('description', Description);
  Prop(Name, Result, Required);
end;

function TMCPSchema.Prop(const Name: string; Schema: TJSONObject; Required: Boolean): TMCPSchema;
begin
  FProps.AddPair(Name, Schema);
  if Required then
    FRequired.Add(Name);
  Result := Self;
end;

function TMCPSchema.Str(const Name, Description: string; Required: Boolean): TMCPSchema;
begin
  Add(Name, 'string', Description, Required);
  Result := Self;
end;

function TMCPSchema.Int(const Name, Description: string; Required: Boolean): TMCPSchema;
begin
  Add(Name, 'integer', Description, Required);
  Result := Self;
end;

function TMCPSchema.Int(const Name, Description: string; Min, Max: Int64; Required: Boolean): TMCPSchema;
var
  P: TJSONObject;
begin
  P := Add(Name, 'integer', Description, Required);
  P.AddPair('minimum', TJSONNumber.Create(Min));
  P.AddPair('maximum', TJSONNumber.Create(Max));
  Result := Self;
end;

function TMCPSchema.Num(const Name, Description: string; Required: Boolean): TMCPSchema;
begin
  Add(Name, 'number', Description, Required);
  Result := Self;
end;

function TMCPSchema.Bool(const Name, Description: string; Required: Boolean): TMCPSchema;
begin
  Add(Name, 'boolean', Description, Required);
  Result := Self;
end;

function TMCPSchema.Enum(const Name, Description: string; const Values: array of string;
  Required: Boolean): TMCPSchema;
var
  P: TJSONObject;
  A: TJSONArray;
  S: string;
begin
  P := Add(Name, 'string', Description, Required);
  A := TJSONArray.Create;
  for S in Values do
    A.Add(S);
  P.AddPair('enum', A);
  Result := Self;
end;

function TMCPSchema.Build: TJSONObject;
begin
  if FRequired.Count > 0 then
  begin
    FRoot.AddPair('required', FRequired);
    FRequired := nil;
  end;
  Result := FRoot;
  FRoot := nil;
  Free;
end;

class function TMCPSchema.Empty: TJSONObject;
begin
  Result := TMCPSchema.Create.Build;
end;

{ Helpers }

function MCPIsValidToolName(const Name: string): Boolean;
var
  C: Char;
begin
  Result := (Length(Name) >= 1) and (Length(Name) <= 64);
  if Result then
    for C in Name do
      if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.']) then
        Exit(False);
end;

{ TModelContext }

constructor TModelContext.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTools := TList<IMCPTool>.Create;
  FPending := TList<IMCPAwaitable>.Create;
  FToolChangeListeners := TDictionary<Integer, TProc>.Create;
  FProviders := TList<TPair<Integer, IMCPResourceProvider>>.Create;
  FSessions := TObjectList<TObject>.Create(True);
  FResourcePollInterval := 1000;
  FServerName := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
  FServerVersion := MCPFormsVersion;
  FMainThreadTimeout := 5 * 60 * 1000;
end;

destructor TModelContext.Destroy;
begin
  if FWatcher <> nil then
  begin
    TMCPResourceWatcher(FWatcher).Stop;
    CancelPending('The application is closing.'); // releases a pending poll
    FreeAndNil(FWatcher);
  end;
  FSessions.Free;
  FProviders.Free;
  CancelPending('The application is closing.');
  FPending.Free;
  FToolChangeListeners.Free;
  FTools.Free;
  FLock.Free;
  inherited;
end;

procedure TModelContext.Log(const Msg: string);
begin
  if Assigned(FOnLog) then
    try
      FOnLog(Msg);
    except
      // logging must never break a call
    end;
end;

procedure TModelContext.ToolsChanged;
var
  Listeners: TArray<TProc>;
  L: TProc;
begin
  if Assigned(FOnToolChange) then
    FOnToolChange();
  FLock.Enter;
  try
    Listeners := FToolChangeListeners.Values.ToArray;
  finally
    FLock.Leave;
  end;
  for L in Listeners do
    try
      L();
    except
      // a listener must never break a registration
    end;
  Notify('notifications/tools/list_changed');
end;

function TModelContext.AddToolChangeListener(const Listener: TProc): Integer;
begin
  FLock.Enter;
  try
    Inc(FNextListenerId);
    Result := FNextListenerId;
    FToolChangeListeners.Add(Result, Listener);
  finally
    FLock.Leave;
  end;
end;

procedure TModelContext.RemoveToolChangeListener(Id: Integer);
begin
  FLock.Enter;
  try
    FToolChangeListeners.Remove(Id);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.FindTool(const Name: string): IMCPTool;
var
  T: IMCPTool;
begin
  Result := nil;
  FLock.Enter;
  try
    for T in FTools do
      if T.Name = Name then
        Exit(T);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.RegisterTool(const Def: TMCPToolDef): IMCPTool;
begin
  if not MCPIsValidToolName(Def.Name) then
  begin
    Def.InputSchema.Free;
    raise EArgumentException.CreateFmt('Invalid MCP tool name "%s" (use 1-64 letters, digits, _ - .)', [Def.Name]);
  end;
  if Trim(Def.Description) = '' then
  begin
    Def.InputSchema.Free;
    raise EArgumentException.CreateFmt('Tool "%s" needs a description', [Def.Name]);
  end;
  if not Assigned(Def.Execute) then
  begin
    Def.InputSchema.Free;
    raise EArgumentException.CreateFmt('Tool "%s" needs an Execute function', [Def.Name]);
  end;
  FLock.Enter;
  try
    if FindTool(Def.Name) <> nil then
    begin
      Def.InputSchema.Free;
      raise EArgumentException.CreateFmt('Tool "%s" is already registered', [Def.Name]);
    end;
    Result := TMCPTool.Create(Def);
    FTools.Add(Result);
  finally
    FLock.Leave;
  end;
  Log('registered ' + Def.Name);
  ToolsChanged;
end;

function TModelContext.RegisterTool(const Name, Description: string; InputSchema: TJSONObject;
  const Execute: TMCPExecuteFunc): IMCPTool;
begin
  Result := RegisterTool(TMCPToolDef.Create(Name, Description, InputSchema, Execute));
end;

function TModelContext.RegisterTool(const Name, Description: string; InputSchema: TJSONObject;
  const Annotations: TMCPToolAnnotations; const Execute: TMCPExecuteFunc): IMCPTool;
var
  Def: TMCPToolDef;
begin
  Def := TMCPToolDef.Create(Name, Description, InputSchema, Execute);
  Def.Annotations := Annotations;
  Result := RegisterTool(Def);
end;

procedure TModelContext.UnregisterTool(const Name: string);
var
  I: Integer;
  Removed: Boolean;
begin
  Removed := False;
  FLock.Enter;
  try
    for I := FTools.Count - 1 downto 0 do
      if FTools[I].Name = Name then
      begin
        FTools.Delete(I);
        Removed := True;
      end;
  finally
    FLock.Leave;
  end;
  if Removed then
  begin
    Log('unregistered ' + Name);
    ToolsChanged;
  end;
end;

function TModelContext.GetTools: TArray<IMCPTool>;
begin
  FLock.Enter;
  try
    Result := FTools.ToArray;
  finally
    FLock.Leave;
  end;
  TArray.Sort<IMCPTool>(Result, TComparer<IMCPTool>.Construct(
    function(const L, R: IMCPTool): Integer
    begin
      Result := CompareStr(L.Name, R.Name);
    end));
end;

function TModelContext.NewAwaitable: IMCPAwaitable;
begin
  Result := TMCPAwaitable.Create;
  FLock.Enter;
  try
    FPending.Add(Result);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.WaitFor(const Awaitable: IMCPAwaitable; TimeoutMs: Cardinal): string;
begin
  try
    Result := Awaitable.Wait(TimeoutMs);
  finally
    FLock.Enter;
    try
      FPending.Remove(Awaitable);
    finally
      FLock.Leave;
    end;
  end;
end;

procedure TModelContext.CancelPending(const Reason: string);
var
  Items: TArray<IMCPAwaitable>;
  A: IMCPAwaitable;
begin
  FLock.Enter;
  try
    Items := FPending.ToArray;
  finally
    FLock.Leave;
  end;
  for A in Items do
    A.Reject(Reason);
end;

function TModelContext.RunOnMainThread(const Func: TFunc<string>): string;
var
  A: IMCPAwaitable;
begin
  if TThread.CurrentThread.ThreadID = MainThreadID then
    Exit(Func());
  A := NewAwaitable;
  TThread.Queue(nil,
    procedure
    begin
      if A.Settled then
        Exit; // the caller gave up (timeout or shutdown)
      try
        A.Resolve(Func());
      except
        on E: Exception do
          A.Reject(E.Message);
      end;
    end);
  Result := WaitFor(A, FMainThreadTimeout);
end;

function TModelContext.ExecuteTool(const Name: string; const Args: TJSONObject;
  out IsError: Boolean): string;
var
  Tool: IMCPTool;
  Allowed: Boolean;
  Output: string;
  CallArgs: TJSONObject;
begin
  Tool := FindTool(Name);
  if Tool = nil then
    raise EMCPProtocolError.Create(-32602, 'Unknown tool: ' + Name);
  CallArgs := Args;
  Log('call ' + Name + ' ' + CallArgs.ToJSON);
  try
    if Tool.Annotations.ConsequentialHint and Assigned(FConfirmHandler) then
    begin
      Allowed := False;
      RunOnMainThread(
        function: string
        begin
          Allowed := FConfirmHandler(Tool, CallArgs);
          Result := '';
        end);
      if not Allowed then
        raise EMCPToolError.Create('The user declined this action.');
    end;
    if Tool.Threading = mtMainThread then
      Output := RunOnMainThread(
        function: string
        begin
          Result := Tool.Execute(CallArgs);
        end)
    else
      Output := Tool.Execute(CallArgs);
    IsError := False;
  except
    on E: Exception do
    begin
      Output := E.Message;
      IsError := True;
    end;
  end;
  if IsError then
    Log('error ' + Name + ': ' + Output)
  else
    Log('result ' + Name + ': ' + Output);
  Result := Output;
end;

{ Sessions and notifications }

function TModelContext.FindState(const Session: IMCPSession): TObject;
var
  O: TObject;
begin
  // FLock held by the caller
  for O in FSessions do
    if TMCPSessionState(O).Session = Session then
      Exit(O);
  Result := nil;
end;

procedure TModelContext.AttachSession(const Session: IMCPSession);
begin
  if Session = nil then
    Exit;
  FLock.Enter;
  try
    if FindState(Session) = nil then
      FSessions.Add(TMCPSessionState.Create(Session));
    if FWatcher = nil then
      FWatcher := TMCPResourceWatcher.Create(Self);
  finally
    FLock.Leave;
  end;
end;

procedure TModelContext.DetachSession(const Session: IMCPSession);
var
  S: TObject;
begin
  FLock.Enter;
  try
    S := FindState(Session);
    if S <> nil then
      FSessions.Remove(S);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.HasLiveSessions: Boolean;
var
  O: TObject;
begin
  Result := False;
  FLock.Enter;
  try
    for O in FSessions do
      if TMCPSessionState(O).Initialized then
        Exit(True);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.SubscribedUris: TArray<string>;
var
  O: TObject;
  All: TStringList;
begin
  All := TStringList.Create;
  try
    All.Sorted := True;
    All.Duplicates := dupIgnore;
    All.CaseSensitive := True;
    FLock.Enter;
    try
      for O in FSessions do
        All.AddStrings(TMCPSessionState(O).Subscriptions);
    finally
      FLock.Leave;
    end;
    Result := All.ToStringArray;
  finally
    All.Free;
  end;
end;

procedure TModelContext.SendToSessions(const MessageJSON: string; const OnlyUri: string);
var
  Targets: TList<IMCPSession>;
  Dead: TList<IMCPSession>;
  O: TObject;
  St: TMCPSessionState;
  S: IMCPSession;
begin
  Targets := TList<IMCPSession>.Create;
  Dead := TList<IMCPSession>.Create;
  try
    FLock.Enter;
    try
      for O in FSessions do
      begin
        St := TMCPSessionState(O);
        if not St.Initialized then
          Continue;
        if (OnlyUri <> '') and (St.Subscriptions.IndexOf(OnlyUri) < 0) then
          Continue;
        Targets.Add(St.Session);
      end;
    finally
      FLock.Leave;
    end;
    // outside the lock: a transport may block for a while
    for S in Targets do
      try
        if S.Alive then
          S.Send(MessageJSON)
        else
          Dead.Add(S);
      except
        Dead.Add(S);
      end;
    for S in Dead do
      DetachSession(S);
  finally
    Dead.Free;
    Targets.Free;
  end;
end;

procedure TModelContext.Notify(const Method: string; Params: TJSONObject);
var
  Msg: TJSONObject;
  Text: string;
begin
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('jsonrpc', '2.0');
    Msg.AddPair('method', Method);
    if Params <> nil then
    begin
      Msg.AddPair('params', Params);
      Params := nil;
    end;
    Text := Msg.ToJSON;
  finally
    Msg.Free;
    Params.Free;
  end;
  SendToSessions(Text);
end;

procedure TModelContext.ResourcesChanged;
begin
  Log('resources changed');
  Notify('notifications/resources/list_changed');
end;

procedure TModelContext.ResourceUpdated(const Uri: string);
var
  Msg, Params: TJSONObject;
  Text: string;
begin
  Log('resource updated ' + Uri);
  Msg := TJSONObject.Create;
  try
    Msg.AddPair('jsonrpc', '2.0');
    Msg.AddPair('method', 'notifications/resources/updated');
    Params := TJSONObject.Create;
    Params.AddPair('uri', Uri);
    Msg.AddPair('params', Params);
    Text := Msg.ToJSON;
  finally
    Msg.Free;
  end;
  SendToSessions(Text, Uri);
end;

{ Resources }

function TModelContext.RegisterResourceProvider(const Provider: IMCPResourceProvider): Integer;
begin
  FLock.Enter;
  try
    Inc(FNextProviderId);
    Result := FNextProviderId;
    FProviders.Add(TPair<Integer, IMCPResourceProvider>.Create(Result, Provider));
  finally
    FLock.Leave;
  end;
end;

procedure TModelContext.UnregisterResourceProvider(Id: Integer);
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := FProviders.Count - 1 downto 0 do
      if FProviders[I].Key = Id then
        FProviders.Delete(I);
  finally
    FLock.Leave;
  end;
end;

function TModelContext.ListResources: TArray<TMCPResourceInfo>;
var
  Providers: TArray<TPair<Integer, IMCPResourceProvider>>;
  List: TArray<TMCPResourceInfo>;
begin
  FLock.Enter;
  try
    Providers := FProviders.ToArray;
  finally
    FLock.Leave;
  end;
  List := nil;
  RunOnMainThread(
    function: string
    var
      P: TPair<Integer, IMCPResourceProvider>;
    begin
      for P in Providers do
        List := List + P.Value.ListResources;
      Result := '';
    end);
  Result := List;
end;

function TModelContext.ReadResource(const Uri: string; out MimeType: string): string;
var
  Providers: TArray<TPair<Integer, IMCPResourceProvider>>;
  Found: Boolean;
  Mime, Text: string;
begin
  FLock.Enter;
  try
    Providers := FProviders.ToArray;
  finally
    FLock.Leave;
  end;
  Found := False;
  RunOnMainThread(
    function: string
    var
      P: TPair<Integer, IMCPResourceProvider>;
    begin
      for P in Providers do
        if P.Value.ReadResource(Uri, Mime, Text) then
        begin
          Found := True;
          Break;
        end;
      Result := '';
    end);
  if not Found then
    raise EMCPProtocolError.Create(-32002, 'Resource not found: ' + Uri);
  MimeType := Mime;
  Result := Text;
end;

function TModelContext.HandleResourcesList: TJSONObject;
var
  Arr: TJSONArray;
  R: TMCPResourceInfo;
  O: TJSONObject;
begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Result.AddPair('resources', Arr);
  for R in ListResources do
  begin
    O := TJSONObject.Create;
    O.AddPair('uri', R.Uri);
    O.AddPair('name', R.Name);
    if R.Title <> '' then
      O.AddPair('title', R.Title);
    if R.Description <> '' then
      O.AddPair('description', R.Description);
    if R.MimeType <> '' then
      O.AddPair('mimeType', R.MimeType);
    Arr.Add(O);
  end;
end;

function TModelContext.HandleResourcesRead(Params: TJSONObject): TJSONObject;
var
  Uri, Mime, Text: string;
  Arr: TJSONArray;
  O: TJSONObject;
begin
  if (Params = nil) or not Params.TryGetValue<string>('uri', Uri) then
    raise EMCPProtocolError.Create(-32602, 'Missing "uri"');
  Text := ReadResource(Uri, Mime);
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Result.AddPair('contents', Arr);
  O := TJSONObject.Create;
  O.AddPair('uri', Uri);
  if Mime <> '' then
    O.AddPair('mimeType', Mime);
  O.AddPair('text', Text);
  Arr.Add(O);
end;

function TModelContext.HandleSubscribe(Params: TJSONObject; const Session: IMCPSession;
  Subscribe: Boolean): TJSONObject;
var
  Uri: string;
  St: TMCPSessionState;
  I: Integer;
begin
  if (Params = nil) or not Params.TryGetValue<string>('uri', Uri) then
    raise EMCPProtocolError.Create(-32602, 'Missing "uri"');
  if Session = nil then
    raise EMCPProtocolError.Create(-32601,
      'This transport cannot send notifications: subscriptions are not available.');
  FLock.Enter;
  try
    St := TMCPSessionState(FindState(Session));
    if St <> nil then
      if Subscribe then
        St.Subscriptions.Add(Uri)
      else
      begin
        I := St.Subscriptions.IndexOf(Uri);
        if I >= 0 then
          St.Subscriptions.Delete(I);
      end;
  finally
    FLock.Leave;
  end;
  Log(IfThen(Subscribe, 'subscribe ', 'unsubscribe ') + Uri);
  Result := TJSONObject.Create;
end;

function TModelContext.ErrorResponse(Id: TJSONValue; Code: Integer; const Msg: string): string;
var
  Resp, Err: TJSONObject;
begin
  Resp := TJSONObject.Create;
  try
    Resp.AddPair('jsonrpc', '2.0');
    if Id <> nil then
      Resp.AddPair('id', TJSONValue(Id.Clone))
    else
      Resp.AddPair('id', TJSONNull.Create);
    Err := TJSONObject.Create;
    Err.AddPair('code', TJSONNumber.Create(Code));
    Err.AddPair('message', Msg);
    Resp.AddPair('error', Err);
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

function TModelContext.HandleInitialize(Params: TJSONObject; WithSession: Boolean): TJSONObject;
var
  Requested, Version, V: string;
  Caps, ToolsCap, ResCap, Info: TJSONObject;
begin
  Version := MCPProtocolVersions[0];
  if (Params <> nil) and Params.TryGetValue<string>('protocolVersion', Requested) then
    for V in MCPProtocolVersions do
      if V = Requested then
        Version := V;

  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', Version);
  Caps := TJSONObject.Create;
  ToolsCap := TJSONObject.Create;
  // Notifications need a channel from the server to the client.
  ToolsCap.AddPair('listChanged', TJSONBool.Create(WithSession));
  Caps.AddPair('tools', ToolsCap);
  ResCap := TJSONObject.Create;
  ResCap.AddPair('subscribe', TJSONBool.Create(WithSession));
  ResCap.AddPair('listChanged', TJSONBool.Create(WithSession));
  Caps.AddPair('resources', ResCap);
  Result.AddPair('capabilities', Caps);
  Info := TJSONObject.Create;
  Info.AddPair('name', FServerName);
  Info.AddPair('version', FServerVersion);
  Result.AddPair('serverInfo', Info);
  if FInstructions <> '' then
    Result.AddPair('instructions', FInstructions);
end;

function TModelContext.ToolToJSON(const Tool: IMCPTool): TJSONObject;
var
  Ann: TJSONObject;
  Schema: TJSONObject;
  A: TMCPToolAnnotations;
begin
  if Tool.HasDynamicSchema then
  begin
    Schema := nil;
    RunOnMainThread(
      function: string
      begin
        Schema := Tool.NewInputSchema;
        Result := '';
      end);
  end
  else
    Schema := Tool.NewInputSchema;

  Result := TJSONObject.Create;
  Result.AddPair('name', Tool.Name);
  if Tool.Title <> '' then
    Result.AddPair('title', Tool.Title);
  Result.AddPair('description', Tool.Description);
  Result.AddPair('inputSchema', Schema);

  A := Tool.Annotations;
  Ann := TJSONObject.Create;
  if Tool.Title <> '' then
    Ann.AddPair('title', Tool.Title);
  Ann.AddPair('readOnlyHint', TJSONBool.Create(A.ReadOnlyHint));
  if not A.ReadOnlyHint then
    Ann.AddPair('destructiveHint', TJSONBool.Create(A.ConsequentialHint));
  Ann.AddPair('openWorldHint', TJSONBool.Create(A.UntrustedContentHint));
  Result.AddPair('annotations', Ann);
end;

function TModelContext.HandleToolsList: TJSONObject;
var
  Arr: TJSONArray;
  T: IMCPTool;
begin
  Arr := TJSONArray.Create;
  try
    for T in GetTools do
      Arr.AddElement(ToolToJSON(T));
  except
    Arr.Free;
    raise;
  end;
  Result := TJSONObject.Create;
  Result.AddPair('tools', Arr);
end;

function TModelContext.HandleToolsCall(Params: TJSONObject): TJSONObject;
var
  Name, Output: string;
  ArgsValue, Parsed: TJSONValue;
  Args: TJSONObject;
  OwnsArgs, IsError: Boolean;
  Content: TJSONArray;
  Item: TJSONObject;
begin
  if (Params = nil) or not Params.TryGetValue<string>('name', Name) then
    raise EMCPProtocolError.Create(-32602, 'Missing tool name');

  OwnsArgs := False;
  ArgsValue := Params.GetValue('arguments');
  if ArgsValue is TJSONObject then
    Args := TJSONObject(ArgsValue)
  else if ArgsValue is TJSONString then
  begin
    // JSON-stringified arguments (deprecated, still accepted)
    Parsed := TJSONObject.ParseJSONValue(ArgsValue.Value);
    if not (Parsed is TJSONObject) then
    begin
      Parsed.Free;
      raise EMCPProtocolError.Create(-32602, 'arguments must be an object');
    end;
    Args := TJSONObject(Parsed);
    OwnsArgs := True;
  end
  else
  begin
    Args := TJSONObject.Create;
    OwnsArgs := True;
  end;

  try
    Output := ExecuteTool(Name, Args, IsError);
  finally
    if OwnsArgs then
      Args.Free;
  end;

  Result := TJSONObject.Create;
  Content := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.AddPair('type', 'text');
  Item.AddPair('text', Output);
  Content.AddElement(Item);
  Result.AddPair('content', Content);
  Result.AddPair('isError', TJSONBool.Create(IsError));
end;

function TModelContext.HandleMessage(const RequestJSON: string;
  const Session: IMCPSession): string;
var
  V, Id, MethodValue, ParamsValue: TJSONValue;
  Req, Resp, Params, ResultObj: TJSONObject;
  Method: string;
begin
  Result := '';
  V := TJSONObject.ParseJSONValue(RequestJSON);
  if not (V is TJSONObject) then
  begin
    V.Free;
    Exit(ErrorResponse(nil, -32700, 'Parse error: expected one JSON-RPC object'));
  end;
  Req := TJSONObject(V);
  if Session <> nil then
    AttachSession(Session);
  try
    Id := Req.GetValue('id');
    MethodValue := Req.GetValue('method');
    if MethodValue = nil then
      Exit(''); // a response to a server request: nothing to do
    Method := MethodValue.Value;
    if Id = nil then
    begin
      Log('notification ' + Method);
      Exit('');
    end;

    Params := nil;
    ParamsValue := Req.GetValue('params');
    if ParamsValue is TJSONObject then
      Params := TJSONObject(ParamsValue);

    try
      if Method = 'initialize' then
      begin
        ResultObj := HandleInitialize(Params, Session <> nil);
        if Session <> nil then
        begin
          FLock.Enter;
          try
            if FindState(Session) <> nil then
              TMCPSessionState(FindState(Session)).Initialized := True;
          finally
            FLock.Leave;
          end;
        end;
      end
      else if Method = 'ping' then
        ResultObj := TJSONObject.Create
      else if Method = 'tools/list' then
        ResultObj := HandleToolsList
      else if Method = 'tools/call' then
        ResultObj := HandleToolsCall(Params)
      else if Method = 'resources/list' then
        ResultObj := HandleResourcesList
      else if Method = 'resources/read' then
        ResultObj := HandleResourcesRead(Params)
      else if Method = 'resources/templates/list' then
      begin
        ResultObj := TJSONObject.Create;
        ResultObj.AddPair('resourceTemplates', TJSONArray.Create);
      end
      else if Method = 'resources/subscribe' then
        ResultObj := HandleSubscribe(Params, Session, True)
      else if Method = 'resources/unsubscribe' then
        ResultObj := HandleSubscribe(Params, Session, False)
      else
        Exit(ErrorResponse(Id, -32601, 'Method not found: ' + Method));

      Resp := TJSONObject.Create;
      try
        Resp.AddPair('jsonrpc', '2.0');
        Resp.AddPair('id', TJSONValue(Id.Clone));
        Resp.AddPair('result', ResultObj);
        Result := Resp.ToJSON;
      finally
        Resp.Free;
      end;
    except
      on E: EMCPProtocolError do
        Result := ErrorResponse(Id, E.Code, E.Message);
      on E: Exception do
        Result := ErrorResponse(Id, -32603, E.Message);
    end;
  finally
    Req.Free;
  end;
end;

var
  GModelContext: TModelContext;

function ModelContext: TModelContext;
begin
  if GModelContext = nil then
    GModelContext := TModelContext.Create;
  Result := GModelContext;
end;

initialization

finalization
  FreeAndNil(GModelContext);

end.
