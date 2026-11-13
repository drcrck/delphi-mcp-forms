unit MCPForms.Core;

{ delphi-mcp-forms
  WebMCP-style tools for Delphi applications, served over the Model Context
  Protocol (MCP).

  This unit has no VCL/FMX dependency. It holds the tool registry (the Delphi
  counterpart of WebMCP's document.modelContext), a JSON Schema builder and the
  MCP JSON-RPC dispatcher. Transports (see MCPForms.Transport.HTTP) only move
  strings in and out of TModelContext.HandleMessage.

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
    FMainThreadTimeout: Cardinal;
    function FindTool(const Name: string): IMCPTool;
    procedure ToolsChanged;
    function ErrorResponse(Id: TJSONValue; Code: Integer; const Msg: string): string;
    function HandleInitialize(Params: TJSONObject): TJSONObject;
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
    function HandleMessage(const RequestJSON: string): string;

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
    property ConfirmHandler: TMCPConfirmFunc read FConfirmHandler write FConfirmHandler;
    /// Called from any thread.
    property OnLog: TMCPLogProc read FOnLog write FOnLog;
    /// Called (from any thread) after a tool is registered or unregistered.
    property OnToolChange: TProc read FOnToolChange write FOnToolChange;
    property MainThreadTimeout: Cardinal read FMainThreadTimeout write FMainThreadTimeout;
  end;

/// The process-wide registry, like document.modelContext.
function ModelContext: TModelContext;

/// True when Name is a valid MCP tool name (1-64 chars: letters, digits, _ - .).
function MCPIsValidToolName(const Name: string): Boolean;

implementation

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
  FServerName := ChangeFileExt(ExtractFileName(ParamStr(0)), '');
  FServerVersion := MCPFormsVersion;
  FMainThreadTimeout := 5 * 60 * 1000;
end;

destructor TModelContext.Destroy;
begin
  CancelPending('The application is closing.');
  FPending.Free;
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
begin
  if Assigned(FOnToolChange) then
    FOnToolChange();
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

function TModelContext.HandleInitialize(Params: TJSONObject): TJSONObject;
var
  Requested, Version, V: string;
  Caps, ToolsCap, Info: TJSONObject;
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
  ToolsCap.AddPair('listChanged', TJSONBool.Create(False));
  Caps.AddPair('tools', ToolsCap);
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

function TModelContext.HandleMessage(const RequestJSON: string): string;
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
        ResultObj := HandleInitialize(Params)
      else if Method = 'ping' then
        ResultObj := TJSONObject.Create
      else if Method = 'tools/list' then
        ResultObj := HandleToolsList
      else if Method = 'tools/call' then
        ResultObj := HandleToolsCall(Params)
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
