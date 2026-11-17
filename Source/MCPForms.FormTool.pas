unit MCPForms.FormTool;

{ delphi-mcp-forms - framework-neutral base of the declarative API.

  A form tool turns a form (or a panel) into one MCP tool, the way WebMCP turns
  <form toolname="..." tooldescription="..."> into a tool:
    - each input control becomes a parameter of the input schema;
    - a call fills the controls, highlights the form and waits for the submit
      (the user's click, or an automatic one with AutoSubmit);
    - OnSubmit plays the role of SubmitEvent.respondWith(): its Response is
      what the agent receives; Reject() returns an error the agent can fix.

  MCPForms.VCL and MCPForms.FMX implement the control-specific parts.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.JSON,
  MCPForms.Core;

type
  /// Response: text returned to the agent (default 'The form was submitted.').
  TMCPSubmitEvent = procedure(Sender: TObject; AgentInvoked: Boolean;
    var Response: string) of object;

  TMCPCustomFormTool = class(TComponent)
  private
    FActive: Boolean;
    FToolName: string;
    FToolTitle: string;
    FToolDescription: string;
    FReadOnlyHint: Boolean;
    FConsequentialHint: Boolean;
    FUntrustedContentHint: Boolean;
    FAutoSubmit: Boolean;
    FSubmitTimeout: Cardinal;
    FRegisteredName: string;
    FPending: IMCPAwaitable;
    FOnSubmit: TMCPSubmitEvent;
    FOnToolActivated: TNotifyEvent;
    FOnToolCancel: TNotifyEvent;
    procedure SetActive(Value: Boolean);
    procedure SetToolName(const Value: string);
    procedure SetToolDescription(const Value: string);
    procedure SetToolTitle(const Value: string);
    procedure SetHint(var Field: Boolean; Value: Boolean);
    procedure SetReadOnlyHint(Value: Boolean);
    procedure SetConsequentialHint(Value: Boolean);
    procedure SetUntrustedContentHint(Value: Boolean);
    function ExecuteFromAgent(const Args: TJSONObject): string;
    /// Main thread: checks the form, fills it, highlights it, and clicks the
    /// submit control with AutoSubmit. A is set as soon as the call is pending,
    /// so a caller can settle it if a later step raises.
    procedure Activate(const Args: TJSONObject; var A: IMCPAwaitable);
    procedure ClearPending;
  protected
    procedure Loaded; override;
    procedure UpdateRegistration;
    procedure Unregister;

    { Framework hooks, always called on the main thread. }
    function BuildInputSchema: TJSONObject; virtual; abstract;
    /// Fill the controls. Raise EMCPToolError with a clear message on bad input.
    procedure ApplyArguments(const Args: TJSONObject); virtual; abstract;
    /// The form is open and enabled.
    function IsUsable: Boolean; virtual; abstract;
    procedure ShowActive(Value: Boolean); virtual; abstract;
    /// Programmatic click on the submit control (AutoSubmit).
    procedure ClickSubmit; virtual; abstract;

    /// Subclasses call these from their control hooks.
    procedure HandleSubmit;
    procedure HandleCancel;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// Ends the pending agent call with an error the agent can act on
    /// (e.g. a validation failure). Call it from your save handler.
    procedure Reject(const Msg: string);
    /// True while an agent call is waiting for this form to be submitted.
    function AgentInvoked: Boolean;
    /// The name the tool is registered under, '' when it is not registered.
    property RegisteredName: string read FRegisteredName;
  published
    property Active: Boolean read FActive write SetActive default True;
    /// toolname: 1-64 letters, digits, _ - .  Prefer a precise verb: "create-order".
    property ToolName: string read FToolName write SetToolName;
    property ToolTitle: string read FToolTitle write SetToolTitle;
    /// tooldescription: what the tool does and when to use it.
    property ToolDescription: string read FToolDescription write SetToolDescription;
    property ReadOnlyHint: Boolean read FReadOnlyHint write SetReadOnlyHint default False;
    property ConsequentialHint: Boolean read FConsequentialHint write SetConsequentialHint default False;
    property UntrustedContentHint: Boolean read FUntrustedContentHint write SetUntrustedContentHint default False;
    /// toolautosubmit: click the submit control right after filling the form.
    property AutoSubmit: Boolean read FAutoSubmit write FAutoSubmit default False;
    /// How long a call waits for the user to submit, in ms.
    property SubmitTimeout: Cardinal read FSubmitTimeout write FSubmitTimeout default 300000;
    property OnSubmit: TMCPSubmitEvent read FOnSubmit write FOnSubmit;
    /// toolactivated: the agent filled the form.
    property OnToolActivated: TNotifyEvent read FOnToolActivated write FOnToolActivated;
    /// toolcancel: the user cancelled or the form closed during a call.
    property OnToolCancel: TNotifyEvent read FOnToolCancel write FOnToolCancel;
  end;

{ Helpers shared by the VCL and FMX units. }

/// "edtCustomer" -> "customer", "cbPayment" -> "payment", "Edit1" -> "Edit1".
function MCPParamNameFromComponent(const ComponentName: string): string;
/// Removes '&' accelerators and a trailing ':'.
function MCPCleanCaption(const S: string): string;

type
  TMCPLabelCandidate = record
    Rect: TRectF;
    Text: string;
  end;

/// Picks the label that most likely describes a control at Target: on the
/// same row to the left, or right above it. '' when none fits.
function MCPPickLabel(const Target: TRectF; const Labels: TArray<TMCPLabelCandidate>): string;

/// Value conversion with errors the model can understand.
function MCPArgString(const Param: string; V: TJSONValue): string;
function MCPArgInt(const Param: string; V: TJSONValue): Int64;
function MCPArgFloat(const Param: string; V: TJSONValue): Double;
function MCPArgBool(const Param: string; V: TJSONValue): Boolean;
/// "YYYY-MM-DD"
function MCPArgDate(const Param: string; V: TJSONValue): TDateTime;
/// "HH:MM" or "HH:MM:SS"
function MCPArgTime(const Param: string; V: TJSONValue): TDateTime;
/// Case-insensitive match against Items; raises listing the allowed values.
function MCPMatchItem(const Param: string; Items: TStrings; V: TJSONValue): Integer;
/// Adds "enum" with the non-empty items.
procedure MCPAddEnum(Schema: TJSONObject; Items: TStrings);
/// Adds "examples" with up to 20 items.
procedure MCPAddExamples(Schema: TJSONObject; Items: TStrings);

{ Lists and grids: read by screen snapshots, never written by a form tool. }

/// A list: an array of strings, or of {"text", "checked"} objects.
function MCPListSchema(Checkable: Boolean = False): TJSONObject;
/// A table: an array of objects, one property per column (Keys), titled with
/// the column captions (Titles).
function MCPTableSchema(const Keys, Titles: TArray<string>): TJSONObject;
/// Unique, non-empty property names from column captions.
function MCPColumnKeys(const Captions: TArray<string>): TArray<string>;
/// A list item: the text, or {"text", "checked"}.
function MCPListItem(const Text: string; Checkable, Checked: Boolean): TJSONValue;
/// The error SetValue raises on a list or a grid.
function MCPReadOnlyDataError(const Param: string): EMCPToolError;

implementation

uses
  System.StrUtils, System.Math, System.Generics.Collections;

var
  // Live form tools (main thread only): a queued call checks it before
  // touching a tool whose form may have been closed in the meantime.
  GAliveTools: TList<TObject>;

{ Helpers }

function MCPParamNameFromComponent(const ComponentName: string): string;
var
  I: Integer;
begin
  Result := ComponentName;
  // lowercase prefix of 1-4 chars followed by an uppercase letter
  I := 1;
  while (I <= Length(Result)) and CharInSet(Result[I], ['a'..'z']) do
    Inc(I);
  if (I >= 2) and (I <= 5) and (I <= Length(Result)) and CharInSet(Result[I], ['A'..'Z']) then
  begin
    Result := Copy(Result, I, MaxInt);
    Result[1] := LowerCase(Result[1])[1];
  end;
end;

function MCPCleanCaption(const S: string): string;
begin
  Result := StringReplace(S, '&&', #1, [rfReplaceAll]);
  Result := StringReplace(Result, '&', '', [rfReplaceAll]);
  Result := StringReplace(Result, #1, '&', [rfReplaceAll]);
  Result := Trim(Result);
  while EndsStr(':', Result) do
    Result := Trim(Copy(Result, 1, Length(Result) - 1));
end;

function MCPPickLabel(const Target: TRectF; const Labels: TArray<TMCPLabelCandidate>): string;
var
  L: TMCPLabelCandidate;
  Best, Dist, MidT, MidL: Single;
begin
  Result := '';
  Best := MaxSingle;
  MidT := (Target.Top + Target.Bottom) / 2;
  for L in Labels do
  begin
    if Trim(L.Text) = '' then
      Continue;
    MidL := (L.Rect.Top + L.Rect.Bottom) / 2;
    // same row, on the left
    if (Abs(MidL - MidT) <= Max(Target.Height, L.Rect.Height) / 2 + 2) and
       (L.Rect.Right <= Target.Left + 4) then
    begin
      Dist := Target.Left - L.Rect.Right;
      if (Dist < 250) and (Dist < Best) then
      begin
        Best := Dist;
        Result := L.Text;
      end;
    end
    // right above, overlapping horizontally
    else if (L.Rect.Bottom <= Target.Top + 4) and (Target.Top - L.Rect.Bottom < 30) and
            (L.Rect.Left < Target.Right) and (L.Rect.Right > Target.Left) then
    begin
      Dist := (Target.Top - L.Rect.Bottom) + 20; // prefer same-row labels
      if Dist < Best then
      begin
        Best := Dist;
        Result := L.Text;
      end;
    end;
  end;
  Result := MCPCleanCaption(Result);
end;

function ParamError(const Param, Msg: string): EMCPToolError;
begin
  Result := EMCPToolError.CreateFmt('Parameter "%s": %s', [Param, Msg]);
end;

function MCPArgString(const Param: string; V: TJSONValue): string;
begin
  if (V = nil) or (V is TJSONNull) then
    Exit('');
  if (V is TJSONObject) or (V is TJSONArray) then
    raise ParamError(Param, 'expected a string.');
  Result := V.Value;
end;

function MCPArgInt(const Param: string; V: TJSONValue): Int64;
var
  D: Double;
begin
  if V is TJSONNumber then
  begin
    D := TJSONNumber(V).AsDouble;
    if Frac(D) <> 0 then
      raise ParamError(Param, 'expected an integer.');
    Exit(Trunc(D));
  end;
  if (V is TJSONString) and TryStrToInt64(Trim(V.Value), Result) then
    Exit;
  raise ParamError(Param, 'expected an integer.');
end;

function MCPArgFloat(const Param: string; V: TJSONValue): Double;
begin
  if V is TJSONNumber then
    Exit(TJSONNumber(V).AsDouble);
  if (V is TJSONString) and TryStrToFloat(Trim(V.Value), Result, TFormatSettings.Invariant) then
    Exit;
  raise ParamError(Param, 'expected a number.');
end;

function MCPArgBool(const Param: string; V: TJSONValue): Boolean;
begin
  if V is TJSONBool then
    Exit(TJSONBool(V).AsBoolean);
  if V is TJSONString then
  begin
    if SameText(V.Value, 'true') then Exit(True);
    if SameText(V.Value, 'false') then Exit(False);
  end;
  raise ParamError(Param, 'expected true or false.');
end;

function MCPArgDate(const Param: string; V: TJSONValue): TDateTime;
var
  S: string;
  Y, M, D: Integer;
begin
  S := Trim(MCPArgString(Param, V));
  if (Length(S) >= 10) and (S[5] = '-') and (S[8] = '-') and
     TryStrToInt(Copy(S, 1, 4), Y) and TryStrToInt(Copy(S, 6, 2), M) and
     TryStrToInt(Copy(S, 9, 2), D) and TryEncodeDate(Y, M, D, Result) then
    Exit;
  raise ParamError(Param, 'expected a date as YYYY-MM-DD.');
end;

function MCPArgTime(const Param: string; V: TJSONValue): TDateTime;
var
  S: string;
  H, N, Sec: Integer;
begin
  S := Trim(MCPArgString(Param, V));
  Sec := 0;
  if (Length(S) >= 5) and (S[3] = ':') and TryStrToInt(Copy(S, 1, 2), H) and
     TryStrToInt(Copy(S, 4, 2), N) and
     ((Length(S) = 5) or ((Length(S) = 8) and (S[6] = ':') and TryStrToInt(Copy(S, 7, 2), Sec))) and
     TryEncodeTime(H, N, Sec, 0, Result) then
    Exit;
  raise ParamError(Param, 'expected a time as HH:MM or HH:MM:SS.');
end;

function MCPMatchItem(const Param: string; Items: TStrings; V: TJSONValue): Integer;
var
  S, Allowed: string;
  I: Integer;
begin
  S := Trim(MCPArgString(Param, V));
  for I := 0 to Items.Count - 1 do
    if SameText(Trim(Items[I]), S) then
      Exit(I);
  Allowed := '';
  for I := 0 to Min(Items.Count, 30) - 1 do
    Allowed := Allowed + IfThen(Allowed <> '', ', ') + '"' + Items[I] + '"';
  raise ParamError(Param, Format('"%s" is not allowed. Use one of: %s.', [S, Allowed]));
end;

procedure MCPAddEnum(Schema: TJSONObject; Items: TStrings);
var
  A: TJSONArray;
  I: Integer;
begin
  A := TJSONArray.Create;
  for I := 0 to Items.Count - 1 do
    if Trim(Items[I]) <> '' then
      A.Add(Items[I]);
  Schema.AddPair('enum', A);
end;

procedure MCPAddExamples(Schema: TJSONObject; Items: TStrings);
var
  A: TJSONArray;
  I: Integer;
begin
  if Items.Count = 0 then
    Exit;
  A := TJSONArray.Create;
  for I := 0 to Min(Items.Count, 20) - 1 do
    A.Add(Items[I]);
  Schema.AddPair('examples', A);
end;

function MCPListSchema(Checkable: Boolean): TJSONObject;
var
  Item, Props: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'array');
  Item := TJSONObject.Create;
  if Checkable then
  begin
    Item.AddPair('type', 'object');
    Props := TJSONObject.Create;
    Props.AddPair('text', TJSONObject.Create(TJSONPair.Create('type', 'string')));
    Props.AddPair('checked', TJSONObject.Create(TJSONPair.Create('type', 'boolean')));
    Item.AddPair('properties', Props);
  end
  else
    Item.AddPair('type', 'string');
  Result.AddPair('items', Item);
end;

function MCPTableSchema(const Keys, Titles: TArray<string>): TJSONObject;
var
  Item, Props, Col: TJSONObject;
  I: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'array');
  Item := TJSONObject.Create;
  Item.AddPair('type', 'object');
  Props := TJSONObject.Create;
  for I := 0 to High(Keys) do
  begin
    Col := TJSONObject.Create;
    Col.AddPair('type', 'string');
    if (I <= High(Titles)) and (Titles[I] <> '') and (Titles[I] <> Keys[I]) then
      Col.AddPair('title', Titles[I]);
    Props.AddPair(Keys[I], Col);
  end;
  Item.AddPair('properties', Props);
  Result.AddPair('items', Item);
end;

function MCPColumnKeys(const Captions: TArray<string>): TArray<string>;
var
  I, N: Integer;
  K, Base: string;
  Used: TList<string>;
begin
  SetLength(Result, Length(Captions));
  Used := TList<string>.Create;
  try
    for I := 0 to High(Captions) do
    begin
      Base := MCPCleanCaption(Captions[I]);
      if Base = '' then
        Base := 'column' + IntToStr(I + 1);
      K := Base;
      N := 2;
      while Used.Contains(K) do
      begin
        K := Base + '_' + IntToStr(N);
        Inc(N);
      end;
      Used.Add(K);
      Result[I] := K;
    end;
  finally
    Used.Free;
  end;
end;

function MCPListItem(const Text: string; Checkable, Checked: Boolean): TJSONValue;
var
  O: TJSONObject;
begin
  if not Checkable then
    Exit(TJSONString.Create(Text));
  O := TJSONObject.Create;
  O.AddPair('text', Text);
  O.AddPair('checked', TJSONBool.Create(Checked));
  Result := O;
end;

function MCPReadOnlyDataError(const Param: string): EMCPToolError;
begin
  Result := EMCPToolError.CreateFmt('Parameter "%s" is a list that can only be read.', [Param]);
end;

{ TMCPCustomFormTool }

constructor TMCPCustomFormTool.Create(AOwner: TComponent);
begin
  inherited;
  FActive := True;
  FSubmitTimeout := 300000;
  GAliveTools.Add(Self);
end;

destructor TMCPCustomFormTool.Destroy;
begin
  GAliveTools.Remove(Self);
  if FPending <> nil then
  begin
    FPending.Reject('The form was closed.');
    FPending := nil;
  end;
  Unregister;
  inherited;
end;

procedure TMCPCustomFormTool.Loaded;
begin
  inherited;
  UpdateRegistration;
end;

procedure TMCPCustomFormTool.SetActive(Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    UpdateRegistration;
  end;
end;

procedure TMCPCustomFormTool.SetToolName(const Value: string);
begin
  if FToolName <> Value then
  begin
    FToolName := Value;
    UpdateRegistration;
  end;
end;

procedure TMCPCustomFormTool.SetToolDescription(const Value: string);
begin
  if FToolDescription <> Value then
  begin
    FToolDescription := Value;
    UpdateRegistration;
  end;
end;

procedure TMCPCustomFormTool.SetToolTitle(const Value: string);
begin
  if FToolTitle <> Value then
  begin
    FToolTitle := Value;
    UpdateRegistration;
  end;
end;

procedure TMCPCustomFormTool.SetHint(var Field: Boolean; Value: Boolean);
begin
  if Field <> Value then
  begin
    Field := Value;
    UpdateRegistration;
  end;
end;

procedure TMCPCustomFormTool.SetReadOnlyHint(Value: Boolean);
begin
  SetHint(FReadOnlyHint, Value);
end;

procedure TMCPCustomFormTool.SetConsequentialHint(Value: Boolean);
begin
  SetHint(FConsequentialHint, Value);
end;

procedure TMCPCustomFormTool.SetUntrustedContentHint(Value: Boolean);
begin
  SetHint(FUntrustedContentHint, Value);
end;

procedure TMCPCustomFormTool.Unregister;
begin
  if FRegisteredName <> '' then
  begin
    ModelContext.UnregisterTool(FRegisteredName);
    FRegisteredName := '';
  end;
end;

procedure TMCPCustomFormTool.UpdateRegistration;
var
  Def: TMCPToolDef;
begin
  if (csLoading in ComponentState) or (csDesigning in ComponentState) or
     (csDestroying in ComponentState) then
    Exit;
  Unregister;
  if not FActive or (FToolName = '') or (Trim(FToolDescription) = '') then
    Exit;

  Def := TMCPToolDef.Create(FToolName, FToolDescription, nil, ExecuteFromAgent);
  Def.Title := FToolTitle;
  Def.SchemaFunc := BuildInputSchema;
  Def.Annotations.ReadOnlyHint := FReadOnlyHint;
  Def.Annotations.ConsequentialHint := FConsequentialHint;
  Def.Annotations.UntrustedContentHint := FUntrustedContentHint;
  // The call waits for the user's submit: it must not block the main thread.
  Def.Threading := mtCallerThread;
  ModelContext.RegisterTool(Def);
  FRegisteredName := FToolName;
end;

procedure TMCPCustomFormTool.Activate(const Args: TJSONObject; var A: IMCPAwaitable);
begin
  if not GAliveTools.Contains(Self) then
    raise EMCPToolError.Create('The form was closed.');
  if not IsUsable then
    raise EMCPToolError.CreateFmt('The form behind "%s" is not open right now. ' +
      'Ask the user to open it, then try again.', [FToolName]);
  if FPending <> nil then
  begin
    FPending.Reject('Superseded by a newer call.');
    FPending := nil;
  end;
  ApplyArguments(Args);
  A := ModelContext.NewAwaitable;
  FPending := A;
  ShowActive(True);
  if Assigned(FOnToolActivated) then
    FOnToolActivated(Self);
  if FAutoSubmit then
    ClickSubmit;
end;

function TMCPCustomFormTool.ExecuteFromAgent(const Args: TJSONObject): string;
var
  Ctx: TModelContext;
  A: IMCPAwaitable;
  Timeout: Cardinal;
begin
  Ctx := ModelContext;
  A := nil;
  Timeout := 0;
  try
    Ctx.RunOnMainThread(
      function: string
      begin
        Result := '';
        Timeout := FSubmitTimeout;
        Activate(Args, A);
      end);
  except
    // e.g. the automatic submit raised: settle and forget the pending call
    on E: Exception do
    begin
      if A = nil then
        raise;
      // The app may have settled the call already (e.g. Reject('Guest name is
      // required.') before Abort): report that first outcome, not the exception.
      A.Reject(E.Message);
      Exit(Ctx.WaitFor(A, 0));
    end;
  end;
  // Self is not touched after this point: the form may close while we wait.
  Result := Ctx.WaitFor(A, Timeout);
end;

procedure TMCPCustomFormTool.ClearPending;
begin
  FPending := nil;
  ShowActive(False);
end;

function TMCPCustomFormTool.AgentInvoked: Boolean;
begin
  Result := FPending <> nil;
end;

procedure TMCPCustomFormTool.HandleSubmit;
var
  Response: string;
  P: IMCPAwaitable;
begin
  Response := '';
  if Assigned(FOnSubmit) then
    FOnSubmit(Self, AgentInvoked, Response);
  P := FPending; // nil if OnSubmit called Reject
  if P = nil then
    Exit;
  ClearPending;
  if Response = '' then
    Response := 'The form was submitted.';
  P.Resolve(Response);
end;

procedure TMCPCustomFormTool.HandleCancel;
var
  P: IMCPAwaitable;
begin
  P := FPending;
  if P = nil then
    Exit;
  ClearPending;
  if Assigned(FOnToolCancel) then
    FOnToolCancel(Self);
  P.Reject('The user cancelled the form.');
end;

procedure TMCPCustomFormTool.Reject(const Msg: string);
var
  P: IMCPAwaitable;
begin
  P := FPending;
  if P = nil then
    Exit;
  ClearPending;
  P.Reject(Msg);
end;

initialization
  GAliveTools := TList<TObject>.Create;

finalization
  FreeAndNil(GAliveTools);

end.
