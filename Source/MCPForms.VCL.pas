unit MCPForms.VCL;

{ delphi-mcp-forms - declarative form tools for VCL.

  Drop (or create) a TMCPFormTool on a form, set ToolName and ToolDescription,
  and the input controls of Container become the tool's parameters:

    TEdit/TMaskEdit/TMemo/any TCustomEdit  -> string
    TComboBox (csDropDownList)             -> string enum of Items
    TComboBox (other styles)               -> string with examples
    TRadioGroup                            -> string enum of Items
    TCheckBox                              -> boolean
    TSpinEdit, TTrackBar                   -> integer with minimum/maximum
    TDateTimePicker                        -> "YYYY-MM-DD" (or "HH:MM:SS")
    any control with a published Text      -> string

  Parameter description, in order: TMCPParam.Description, the control's Hint,
  a TLabel whose FocusControl is the control (the <label for> of VCL), the
  nearest label on the left or above. Support for other controls is added with
  RegisterMCPControlAdapter.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.JSON,
  System.Generics.Collections,
  Vcl.Controls, Vcl.Graphics,
  MCPForms.Core, MCPForms.FormTool;

type
  /// Teaches TMCPFormTool a control type.
  TMCPControlAdapter = class
  public
    function Supports(C: TControl): Boolean; virtual; abstract;
    /// Type part of the property schema (no description).
    function Schema(C: TControl): TJSONObject; virtual; abstract;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); virtual; abstract;
    /// Text the control shows about itself (e.g. a check box caption), or ''.
    function OwnCaption(C: TControl): string; virtual;
  end;

  TMCPParam = class(TCollectionItem)
  private
    FControl: TControl;
    FParamName: string;
    FDescription: string;
    FRequired: Boolean;
    procedure SetControl(Value: TControl);
  protected
    function GetDisplayName: string; override;
  published
    property Control: TControl read FControl write SetControl;
    /// Defaults to the control name without its prefix (edtCustomer -> customer).
    property ParamName: string read FParamName write FParamName;
    /// toolparamdescription
    property Description: string read FDescription write FDescription;
    property Required: Boolean read FRequired write FRequired default False;
  end;

  TMCPParams = class(TOwnedCollection)
  private
    function GetItem(Index: Integer): TMCPParam;
  public
    function Add: TMCPParam; overload;
    function Add(AControl: TControl; const AParamName: string = '';
      const ADescription: string = ''; ARequired: Boolean = False): TMCPParam; overload;
    property Items[Index: Integer]: TMCPParam read GetItem; default;
  end;

  TMCPFormTool = class(TMCPCustomFormTool)
  private
    FContainer: TWinControl;
    FSubmitControl: TControl;
    FCancelControl: TControl;
    FParams: TMCPParams;
    FHighlightColor: TColor;
    FFrame: array[0..3] of TControl;
    FOrigSubmitClick: TNotifyEvent;
    FOrigCancelClick: TNotifyEvent;
    FHookedSubmit: TControl;
    FHookedCancel: TControl;
    procedure SetContainer(Value: TWinControl);
    procedure SetSubmitControl(Value: TControl);
    procedure SetCancelControl(Value: TControl);
    procedure SetParams(Value: TMCPParams);
    procedure HookControls;
    procedure UnhookControls;
    procedure SubmitClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    function EffectiveContainer: TWinControl;
    procedure FreeFrame;
  protected
    procedure Loaded; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    function BuildInputSchema: TJSONObject; override;
    procedure ApplyArguments(const Args: TJSONObject); override;
    function IsUsable: Boolean; override;
    procedure ShowActive(Value: Boolean); override;
    procedure ClickSubmit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  published
    /// The controls to expose. Defaults to the owner form.
    property Container: TWinControl read FContainer write SetContainer;
    /// The button that submits (its OnClick keeps working as before).
    property SubmitControl: TControl read FSubmitControl write SetSubmitControl;
    /// Optional button that cancels a pending agent call.
    property CancelControl: TControl read FCancelControl write SetCancelControl;
    /// Explicit parameters. When empty, every supported control is used.
    property Params: TMCPParams read FParams write SetParams;
    property HighlightColor: TColor read FHighlightColor write FHighlightColor default $00D77800;
  end;

/// Adapters registered later take precedence (put your own controls here).
procedure RegisterMCPControlAdapter(Adapter: TMCPControlAdapter);

/// Default ConfirmHandler: a VCL message box. Installed automatically when
/// no handler is set.
function MCPVclConfirm(const Tool: IMCPTool; const Args: TJSONObject): Boolean;

implementation

uses
  System.TypInfo, System.UITypes, System.Math,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Samples.Spin, Vcl.Forms, Vcl.Dialogs,
  Vcl.Menus;

type
  TControlAccess = class(TControl);
  TCustomComboBoxAccess = class(TCustomComboBox);

var
  GAdapters: TObjectList<TMCPControlAdapter>;

procedure RegisterMCPControlAdapter(Adapter: TMCPControlAdapter);
begin
  GAdapters.Insert(0, Adapter);
end;

function FindAdapter(C: TControl): TMCPControlAdapter;
var
  A: TMCPControlAdapter;
begin
  for A in GAdapters do
    if A.Supports(C) then
      Exit(A);
  Result := nil;
end;

function TypeSchema(const JsonType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', JsonType);
end;

{ TMCPControlAdapter }

function TMCPControlAdapter.OwnCaption(C: TControl): string;
begin
  Result := '';
end;

{ Built-in adapters }

type
  TTextPropAdapter = class(TMCPControlAdapter)
    // any control with a published string "Text" (also third-party edits)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TComboAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TRadioGroupAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function OwnCaption(C: TControl): string; override;
  end;

  TCheckBoxAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function OwnCaption(C: TControl): string; override;
  end;

  TSpinEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TTrackBarAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TDateTimePickerAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

function RangeError(const Param: string; Min, Max: Int64): EMCPToolError;
begin
  Result := EMCPToolError.CreateFmt('Parameter "%s": must be between %d and %d.', [Param, Min, Max]);
end;

{ TTextPropAdapter }

function TTextPropAdapter.Supports(C: TControl): Boolean;
var
  P: PPropInfo;
begin
  P := GetPropInfo(C, 'Text');
  Result := (P <> nil) and (P^.SetProc <> nil) and
    (P^.PropType^.Kind in [tkUString, tkString, tkLString, tkWString]);
end;

function TTextPropAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
end;

procedure TTextPropAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  SetStrProp(C, 'Text', MCPArgString(Param, Value));
end;

{ TEditAdapter }

function TEditAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomEdit;
end;

function TEditAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
end;

procedure TEditAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  if TCustomEdit(C).ReadOnly then
    raise EMCPToolError.CreateFmt('Parameter "%s" is read-only.', [Param]);
  TCustomEdit(C).Text := MCPArgString(Param, Value);
end;

{ TComboAdapter }

function TComboAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomComboBox;
end;

function IsListOnly(C: TControl): Boolean;
begin
  Result := (C is TComboBox) and (TComboBox(C).Style in [csDropDownList, csOwnerDrawFixed, csOwnerDrawVariable]);
end;

function TComboAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  if IsListOnly(C) then
    MCPAddEnum(Result, TCustomComboBox(C).Items)
  else
    MCPAddExamples(Result, TCustomComboBox(C).Items);
end;

procedure TComboAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  Cb: TCustomComboBoxAccess;
begin
  Cb := TCustomComboBoxAccess(C);
  if IsListOnly(C) then
    Cb.ItemIndex := MCPMatchItem(Param, Cb.Items, Value)
  else
    Cb.Text := MCPArgString(Param, Value);
  // what the VCL does when the user picks an item
  Cb.Click;
  Cb.Select;
end;

{ TRadioGroupAdapter }

function TRadioGroupAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TRadioGroup;
end;

function TRadioGroupAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  MCPAddEnum(Result, TRadioGroup(C).Items);
end;

procedure TRadioGroupAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  TRadioGroup(C).ItemIndex := MCPMatchItem(Param, TRadioGroup(C).Items, Value);
end;

function TRadioGroupAdapter.OwnCaption(C: TControl): string;
begin
  Result := MCPCleanCaption(TRadioGroup(C).Caption);
end;

{ TCheckBoxAdapter }

function TCheckBoxAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCheckBox;
end;

function TCheckBoxAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('boolean');
end;

procedure TCheckBoxAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  TCheckBox(C).Checked := MCPArgBool(Param, Value);
end;

function TCheckBoxAdapter.OwnCaption(C: TControl): string;
begin
  Result := MCPCleanCaption(TCheckBox(C).Caption);
end;

{ TSpinEditAdapter }

function TSpinEditAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TSpinEdit;
end;

function TSpinEditAdapter.Schema(C: TControl): TJSONObject;
var
  S: TSpinEdit;
begin
  S := TSpinEdit(C);
  Result := TypeSchema('integer');
  if S.MaxValue > S.MinValue then
  begin
    Result.AddPair('minimum', TJSONNumber.Create(S.MinValue));
    Result.AddPair('maximum', TJSONNumber.Create(S.MaxValue));
  end;
end;

procedure TSpinEditAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  S: TSpinEdit;
  V: Int64;
begin
  S := TSpinEdit(C);
  V := MCPArgInt(Param, Value);
  if (S.MaxValue > S.MinValue) and ((V < S.MinValue) or (V > S.MaxValue)) then
    raise RangeError(Param, S.MinValue, S.MaxValue);
  S.Value := V;
end;

{ TTrackBarAdapter }

function TTrackBarAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TTrackBar;
end;

function TTrackBarAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('integer');
  Result.AddPair('minimum', TJSONNumber.Create(TTrackBar(C).Min));
  Result.AddPair('maximum', TJSONNumber.Create(TTrackBar(C).Max));
end;

procedure TTrackBarAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  T: TTrackBar;
  V: Int64;
begin
  T := TTrackBar(C);
  V := MCPArgInt(Param, Value);
  if (V < T.Min) or (V > T.Max) then
    raise RangeError(Param, T.Min, T.Max);
  T.Position := V;
end;

{ TDateTimePickerAdapter }

function TDateTimePickerAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TDateTimePicker;
end;

function TDateTimePickerAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  if TDateTimePicker(C).Kind = dtkTime then
    Result.AddPair('pattern', '^\d{2}:\d{2}(:\d{2})?$')
  else
    Result.AddPair('format', 'date');
end;

procedure TDateTimePickerAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  P: TDateTimePicker;
begin
  P := TDateTimePicker(C);
  if P.Kind = dtkTime then
    P.Time := MCPArgTime(Param, Value)
  else
    P.Date := MCPArgDate(Param, Value);
end;

{ Parameter discovery }

type
  TParamInfo = record
    Control: TControl;
    Adapter: TMCPControlAdapter;
    Name: string;
    Description: string;
    Required: Boolean;
  end;

procedure CollectControls(Parent: TWinControl; List: TList<TControl>);
var
  I: Integer;
  C: TControl;
begin
  for I := 0 to Parent.ControlCount - 1 do
  begin
    C := Parent.Controls[I];
    List.Add(C);
    if (C is TWinControl) and (FindAdapter(C) = nil) then
      CollectControls(TWinControl(C), List);
  end;
end;

function IsShowing(C: TControl): Boolean;
begin
  if C is TWinControl then
    Result := TWinControl(C).Showing
  else
    Result := C.Visible and (C.Parent <> nil) and C.Parent.Showing;
end;

function ScreenRect(C: TControl): TRectF;
var
  P: TPoint;
begin
  P := C.ClientToScreen(Point(0, 0));
  Result := TRectF.Create(P.X, P.Y, P.X + C.Width, P.Y + C.Height);
end;

function DescribeControl(C: TControl; Adapter: TMCPControlAdapter; All: TList<TControl>): string;
var
  X: TControl;
  Labels: TList<TMCPLabelCandidate>;
  L: TMCPLabelCandidate;
begin
  Result := Trim(C.Hint);
  if Result <> '' then
    Exit;
  for X in All do
    if (X is TLabel) and (TLabel(X).FocusControl = C) then
      Exit(MCPCleanCaption(TLabel(X).Caption));
  Result := Adapter.OwnCaption(C);
  if Result <> '' then
    Exit;
  if not IsShowing(C) then
    Exit;
  Labels := TList<TMCPLabelCandidate>.Create;
  try
    for X in All do
      if (X is TCustomLabel) and IsShowing(X) and
         not ((X is TLabel) and (TLabel(X).FocusControl <> nil)) then
      begin
        L.Rect := ScreenRect(X);
        L.Text := TLabel(X).Caption;
        Labels.Add(L);
      end;
    Result := MCPPickLabel(ScreenRect(C), Labels.ToArray);
  finally
    Labels.Free;
  end;
end;

function ResolveParams(Tool: TMCPFormTool; Container: TWinControl): TArray<TParamInfo>;
var
  All: TList<TControl>;
  List: TList<TParamInfo>;
  Names: TList<string>;
  I: Integer;
  C: TControl;
  P: TParamInfo;
  Item: TMCPParam;
begin
  All := TList<TControl>.Create;
  List := TList<TParamInfo>.Create;
  Names := TList<string>.Create;
  try
    CollectControls(Container, All);
    if Tool.Params.Count > 0 then
    begin
      for I := 0 to Tool.Params.Count - 1 do
      begin
        Item := Tool.Params[I];
        if Item.Control = nil then
          Continue;
        P.Control := Item.Control;
        P.Adapter := FindAdapter(P.Control);
        if P.Adapter = nil then
          raise EMCPToolError.CreateFmt('No MCP adapter for %s (%s)',
            [P.Control.Name, P.Control.ClassName]);
        P.Name := Item.ParamName;
        if P.Name = '' then
          P.Name := MCPParamNameFromComponent(P.Control.Name);
        P.Description := Item.Description;
        if P.Description = '' then
          P.Description := DescribeControl(P.Control, P.Adapter, All);
        P.Required := Item.Required;
        if not Names.Contains(P.Name) then
        begin
          Names.Add(P.Name);
          List.Add(P);
        end;
      end;
    end
    else
      for C in All do
      begin
        if (C.Name = '') or not C.Visible or not C.Enabled or
           (C = Tool.SubmitControl) or (C = Tool.CancelControl) or (C is TCustomLabel) or
           (C is TButtonControl) and not (C is TCheckBox) then
          Continue;
        P.Adapter := FindAdapter(C);
        if P.Adapter = nil then
          Continue;
        if (C is TCustomEdit) and TCustomEdit(C).ReadOnly then
          Continue;
        P.Control := C;
        P.Name := MCPParamNameFromComponent(C.Name);
        P.Description := DescribeControl(C, P.Adapter, All);
        P.Required := False;
        if not Names.Contains(P.Name) then
        begin
          Names.Add(P.Name);
          List.Add(P);
        end;
      end;
    Result := List.ToArray;
  finally
    Names.Free;
    List.Free;
    All.Free;
  end;
end;

{ TMCPParam }

procedure TMCPParam.SetControl(Value: TControl);
var
  Tool: TPersistent;
begin
  FControl := Value;
  Tool := Collection.Owner;
  if (Value <> nil) and (Tool is TComponent) then
    Value.FreeNotification(TComponent(Tool));
end;

function TMCPParam.GetDisplayName: string;
begin
  if FParamName <> '' then
    Result := FParamName
  else if FControl <> nil then
    Result := FControl.Name
  else
    Result := inherited GetDisplayName;
end;

{ TMCPParams }

function TMCPParams.GetItem(Index: Integer): TMCPParam;
begin
  Result := TMCPParam(inherited Items[Index]);
end;

function TMCPParams.Add: TMCPParam;
begin
  Result := TMCPParam(inherited Add);
end;

function TMCPParams.Add(AControl: TControl; const AParamName, ADescription: string;
  ARequired: Boolean): TMCPParam;
begin
  Result := Add;
  Result.Control := AControl;
  Result.ParamName := AParamName;
  Result.Description := ADescription;
  Result.Required := ARequired;
end;

{ TMCPFormTool }

constructor TMCPFormTool.Create(AOwner: TComponent);
begin
  inherited;
  FParams := TMCPParams.Create(Self, TMCPParam);
  FHighlightColor := $00D77800;
end;

destructor TMCPFormTool.Destroy;
begin
  UnhookControls;
  FreeFrame;
  inherited; // rejects a pending call and unregisters the tool
  FParams.Free;
end;

procedure TMCPFormTool.Loaded;
begin
  inherited;
  HookControls;
end;

procedure TMCPFormTool.Notification(AComponent: TComponent; Operation: TOperation);
var
  I: Integer;
begin
  inherited;
  if Operation <> opRemove then
    Exit;
  if AComponent = FContainer then
    FContainer := nil;
  if AComponent = FSubmitControl then
  begin
    FSubmitControl := nil;
    FHookedSubmit := nil;
  end;
  if AComponent = FCancelControl then
  begin
    FCancelControl := nil;
    FHookedCancel := nil;
  end;
  for I := 0 to 3 do
    if AComponent = FFrame[I] then
      FFrame[I] := nil;
  if FParams <> nil then
    for I := 0 to FParams.Count - 1 do
      if FParams[I].Control = AComponent then
        FParams[I].FControl := nil;
end;

procedure TMCPFormTool.SetContainer(Value: TWinControl);
begin
  if FContainer <> Value then
  begin
    FContainer := Value;
    if Value <> nil then
      Value.FreeNotification(Self);
  end;
end;

procedure TMCPFormTool.SetSubmitControl(Value: TControl);
begin
  if FSubmitControl <> Value then
  begin
    UnhookControls;
    FSubmitControl := Value;
    if Value <> nil then
      Value.FreeNotification(Self);
    HookControls;
  end;
end;

procedure TMCPFormTool.SetCancelControl(Value: TControl);
begin
  if FCancelControl <> Value then
  begin
    UnhookControls;
    FCancelControl := Value;
    if Value <> nil then
      Value.FreeNotification(Self);
    HookControls;
  end;
end;

procedure TMCPFormTool.SetParams(Value: TMCPParams);
begin
  FParams.Assign(Value);
end;

procedure TMCPFormTool.HookControls;
begin
  if (csLoading in ComponentState) or (csDesigning in ComponentState) then
    Exit;
  if (FSubmitControl <> nil) and (FHookedSubmit = nil) then
  begin
    FOrigSubmitClick := TControlAccess(FSubmitControl).OnClick;
    TControlAccess(FSubmitControl).OnClick := SubmitClick;
    FHookedSubmit := FSubmitControl;
  end;
  if (FCancelControl <> nil) and (FHookedCancel = nil) then
  begin
    FOrigCancelClick := TControlAccess(FCancelControl).OnClick;
    TControlAccess(FCancelControl).OnClick := CancelClick;
    FHookedCancel := FCancelControl;
  end;
end;

procedure TMCPFormTool.UnhookControls;
begin
  if FHookedSubmit <> nil then
  begin
    TControlAccess(FHookedSubmit).OnClick := FOrigSubmitClick;
    FHookedSubmit := nil;
  end;
  if FHookedCancel <> nil then
  begin
    TControlAccess(FHookedCancel).OnClick := FOrigCancelClick;
    FHookedCancel := nil;
  end;
end;

procedure TMCPFormTool.SubmitClick(Sender: TObject);
begin
  try
    if Assigned(FOrigSubmitClick) then
      FOrigSubmitClick(Sender);
  except
    on E: Exception do
    begin
      if E is EAbort then
        Reject('The application rejected the submit.')
      else
        Reject(E.Message);
      raise;
    end;
  end;
  HandleSubmit;
end;

procedure TMCPFormTool.CancelClick(Sender: TObject);
begin
  try
    if Assigned(FOrigCancelClick) then
      FOrigCancelClick(Sender);
  finally
    HandleCancel;
  end;
end;

function TMCPFormTool.EffectiveContainer: TWinControl;
begin
  Result := FContainer;
  if (Result = nil) and (Owner is TWinControl) then
    Result := TWinControl(Owner);
end;

function TMCPFormTool.BuildInputSchema: TJSONObject;
var
  Container: TWinControl;
  Props, S: TJSONObject;
  Req: TJSONArray;
  P: TParamInfo;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Props := TJSONObject.Create;
  Result.AddPair('properties', Props);
  Container := EffectiveContainer;
  if Container = nil then
    Exit;
  Req := TJSONArray.Create;
  try
    for P in ResolveParams(Self, Container) do
    begin
      S := P.Adapter.Schema(P.Control);
      if P.Description <> '' then
        S.AddPair('description', P.Description);
      Props.AddPair(P.Name, S);
      if P.Required then
        Req.Add(P.Name);
    end;
  except
    Req.Free;
    raise;
  end;
  if Req.Count > 0 then
    Result.AddPair('required', Req)
  else
    Req.Free;
end;

procedure TMCPFormTool.ApplyArguments(const Args: TJSONObject);
var
  Params: TArray<TParamInfo>;
  P: TParamInfo;
  Pair: TJSONPair;
  Known: Boolean;
  Missing: string;
begin
  Params := ResolveParams(Self, EffectiveContainer);
  // strict validation in code, with messages the model can act on
  for Pair in Args do
  begin
    Known := False;
    for P in Params do
      if P.Name = Pair.JsonString.Value then
        Known := True;
    if not Known then
      raise EMCPToolError.CreateFmt('Unknown parameter "%s".', [Pair.JsonString.Value]);
  end;
  Missing := '';
  for P in Params do
    if P.Required and (Args.GetValue(P.Name) = nil) then
      Missing := Missing + ' "' + P.Name + '"';
  if Missing <> '' then
    raise EMCPToolError.Create('Missing required parameter(s):' + Missing + '.');

  for P in Params do
    if Args.GetValue(P.Name) <> nil then
    begin
      if not P.Control.Enabled then
        raise EMCPToolError.CreateFmt('Parameter "%s" cannot be changed right now.', [P.Name]);
      P.Adapter.SetValue(P.Control, P.Name, Args.GetValue(P.Name));
    end;
end;

function TMCPFormTool.IsUsable: Boolean;
var
  C: TWinControl;
begin
  C := EffectiveContainer;
  Result := (C <> nil) and C.Showing and C.Enabled;
end;

procedure TMCPFormTool.FreeFrame;
var
  I: Integer;
begin
  for I := 0 to 3 do
    FreeAndNil(FFrame[I]);
end;

procedure TMCPFormTool.ShowActive(Value: Boolean);
const
  W = 3;
var
  C: TWinControl;
  R: TRect;
  I: Integer;
  P: TPanel;
begin
  FreeFrame;
  if not Value then
    Exit;
  C := EffectiveContainer;
  if (C = nil) or not C.Showing then
    Exit;
  R := C.ClientRect;
  for I := 0 to 3 do
  begin
    P := TPanel.Create(nil);
    P.BevelOuter := bvNone;
    P.Caption := '';
    P.ParentBackground := False;
    P.ParentColor := False;
    P.Color := FHighlightColor;
    P.StyleElements := [];
    case I of
      0: begin P.SetBounds(0, 0, R.Width, W); P.Anchors := [akLeft, akTop, akRight]; end;
      1: begin P.SetBounds(0, R.Height - W, R.Width, W); P.Anchors := [akLeft, akBottom, akRight]; end;
      2: begin P.SetBounds(0, 0, W, R.Height); P.Anchors := [akLeft, akTop, akBottom]; end;
      3: begin P.SetBounds(R.Width - W, 0, W, R.Height); P.Anchors := [akTop, akRight, akBottom]; end;
    end;
    P.Parent := C;
    P.BringToFront;
    P.FreeNotification(Self);
    FFrame[I] := P;
  end;
end;

procedure TMCPFormTool.ClickSubmit;
begin
  if FSubmitControl = nil then
    raise EMCPToolError.Create('This form has no submit button configured.');
  if not FSubmitControl.Enabled then
    raise EMCPToolError.Create('The submit button is disabled: check the values and try again.');
  TControlAccess(FSubmitControl).Click;
end;

{ Default confirmation }

function MCPVclConfirm(const Tool: IMCPTool; const Args: TJSONObject): Boolean;
var
  Text: string;
begin
  Text := Args.ToJSON;
  if Length(Text) > 600 then
    Text := Copy(Text, 1, 600) + '...';
  Result := MessageDlg(Format('An AI agent wants to run "%s":'#13#10'%s'#13#10#13#10'%s'#13#10#13#10'Allow it?',
    [Tool.Name, Tool.Description, Text]), mtConfirmation, [mbYes, mbNo], 0, mbNo) = mrYes;
end;

initialization
  GAdapters := TObjectList<TMCPControlAdapter>.Create(True);
  // most generic first: Insert(0) puts later ones in front
  RegisterMCPControlAdapter(TTextPropAdapter.Create);
  RegisterMCPControlAdapter(TEditAdapter.Create);
  RegisterMCPControlAdapter(TComboAdapter.Create);
  RegisterMCPControlAdapter(TRadioGroupAdapter.Create);
  RegisterMCPControlAdapter(TCheckBoxAdapter.Create);
  RegisterMCPControlAdapter(TTrackBarAdapter.Create);
  RegisterMCPControlAdapter(TDateTimePickerAdapter.Create);
  RegisterMCPControlAdapter(TSpinEditAdapter.Create); // before TEditAdapter
  if not Assigned(ModelContext.ConfirmHandler) then
    ModelContext.ConfirmHandler := MCPVclConfirm;

finalization
  FreeAndNil(GAdapters);

end.
