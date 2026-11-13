unit MCPForms.FMX;

{ delphi-mcp-forms - declarative form tools for FireMonkey.

  Same idea as MCPForms.VCL: a TMCPFormTool turns the input controls of a form
  (or of a TLayout/TPanel) into the parameters of one MCP tool.

    TEdit and other TCustomEdit            -> string
    TComboEdit                             -> string with examples
    TSpinBox, TNumberBox (TCustomEditBox)  -> integer or number, with minimum/maximum
    TMemo                                  -> string
    TComboBox                              -> string enum of the item texts
    TCheckBox, TSwitch                     -> boolean
    TTrackBar                              -> number with minimum/maximum
    TDateEdit                              -> "YYYY-MM-DD"
    TTimeEdit                              -> "HH:MM" or "HH:MM:SS"

  Parameter description, in order: TMCPParam.Description, the control's Hint,
  TextPrompt of an edit, the nearest TLabel on the left or above.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.JSON,
  System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Objects,
  MCPForms.Core, MCPForms.FormTool;

type
  TMCPControlAdapter = class
  public
    function Supports(C: TControl): Boolean; virtual; abstract;
    function Schema(C: TControl): TJSONObject; virtual; abstract;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); virtual; abstract;
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
    property ParamName: string read FParamName write FParamName;
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
    FContainer: TFmxObject;
    FSubmitControl: TControl;
    FCancelControl: TControl;
    FParams: TMCPParams;
    FHighlightColor: TAlphaColor;
    FFrame: TRectangle;
    FOrigSubmitClick: TNotifyEvent;
    FOrigCancelClick: TNotifyEvent;
    FHookedSubmit: TControl;
    FHookedCancel: TControl;
    procedure SetContainer(Value: TFmxObject);
    procedure SetSubmitControl(Value: TControl);
    procedure SetCancelControl(Value: TControl);
    procedure SetParams(Value: TMCPParams);
    procedure HookControls;
    procedure UnhookControls;
    procedure SubmitClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    function EffectiveContainer: TFmxObject;
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
    /// A form, TLayout, TPanel... Defaults to the owner form.
    property Container: TFmxObject read FContainer write SetContainer;
    property SubmitControl: TControl read FSubmitControl write SetSubmitControl;
    property CancelControl: TControl read FCancelControl write SetCancelControl;
    property Params: TMCPParams read FParams write SetParams;
    property HighlightColor: TAlphaColor read FHighlightColor write FHighlightColor default $FF0078D7;
  end;

procedure RegisterMCPControlAdapter(Adapter: TMCPControlAdapter);

/// Default ConfirmHandler for FMX (synchronous message dialog).
function MCPFmxConfirm(const Tool: IMCPTool; const Args: TJSONObject): Boolean;

implementation

uses
  System.Math,
  FMX.StdCtrls, FMX.Edit, FMX.EditBox, FMX.ComboEdit, FMX.ListBox, FMX.Memo,
  FMX.DateTimeCtrls, FMX.DialogService.Sync, FMX.Text, FMX.Graphics;

type
  TControlAccess = class(TControl);

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

procedure AddRange(Schema: TJSONObject; Min, Max: Double; AsInteger: Boolean = False);
begin
  if Max > Min then
    if AsInteger then
    begin
      Schema.AddPair('minimum', TJSONNumber.Create(Int64(Round(Min))));
      Schema.AddPair('maximum', TJSONNumber.Create(Int64(Round(Max))));
    end
    else
    begin
      Schema.AddPair('minimum', TJSONNumber.Create(Min));
      Schema.AddPair('maximum', TJSONNumber.Create(Max));
    end;
end;

procedure CheckRange(const Param: string; V, Min, Max: Double);
begin
  if (Max > Min) and ((V < Min) or (V > Max)) then
    raise EMCPToolError.CreateFmt('Parameter "%s": must be between %g and %g.', [Param, Min, Max]);
end;

{ TMCPControlAdapter }

function TMCPControlAdapter.OwnCaption(C: TControl): string;
begin
  Result := '';
end;

{ Built-in adapters }

type
  TEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TComboEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TEditBoxAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TMemoAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TComboBoxAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TCheckAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function OwnCaption(C: TControl): string; override;
  end;

  TTrackAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TDateEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TTimeEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
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

{ TComboEditAdapter }

function TComboEditAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomComboEdit;
end;

function TComboEditAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  MCPAddExamples(Result, TCustomComboEdit(C).Items);
end;

procedure TComboEditAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  TCustomComboEdit(C).Text := MCPArgString(Param, Value);
end;

{ TEditBoxAdapter }

function TEditBoxAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomEditBox;
end;

function TEditBoxAdapter.Schema(C: TControl): TJSONObject;
var
  B: TCustomEditBox;
begin
  B := TCustomEditBox(C);
  if B.ValueType = TNumValueType.Integer then
    Result := TypeSchema('integer')
  else
    Result := TypeSchema('number');
  AddRange(Result, B.Min, B.Max, B.ValueType = TNumValueType.Integer);
end;

procedure TEditBoxAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  B: TCustomEditBox;
  V: Double;
begin
  B := TCustomEditBox(C);
  if B.ValueType = TNumValueType.Integer then
    V := MCPArgInt(Param, Value)
  else
    V := MCPArgFloat(Param, Value);
  CheckRange(Param, V, B.Min, B.Max);
  B.Value := V;
end;

{ TMemoAdapter }

function TMemoAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomMemo;
end;

function TMemoAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
end;

procedure TMemoAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  if TCustomMemo(C).ReadOnly then
    raise EMCPToolError.CreateFmt('Parameter "%s" is read-only.', [Param]);
  TCustomMemo(C).Text := MCPArgString(Param, Value);
end;

{ TComboBoxAdapter }

function ComboItems(C: TCustomComboBox): TStrings;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to C.Count - 1 do
    Result.Add(C.ListItems[I].Text);
end;

function TComboBoxAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomComboBox;
end;

function TComboBoxAdapter.Schema(C: TControl): TJSONObject;
var
  Items: TStrings;
begin
  Result := TypeSchema('string');
  Items := ComboItems(TCustomComboBox(C));
  try
    MCPAddEnum(Result, Items);
  finally
    Items.Free;
  end;
end;

procedure TComboBoxAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  Items: TStrings;
begin
  Items := ComboItems(TCustomComboBox(C));
  try
    TCustomComboBox(C).ItemIndex := MCPMatchItem(Param, Items, Value);
  finally
    Items.Free;
  end;
end;

{ TCheckAdapter }

function TCheckAdapter.Supports(C: TControl): Boolean;
begin
  Result := (C is TCheckBox) or (C is TCustomSwitch);
end;

function TCheckAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('boolean');
end;

procedure TCheckAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  if C is TCheckBox then
    TCheckBox(C).IsChecked := MCPArgBool(Param, Value)
  else
    TCustomSwitch(C).IsChecked := MCPArgBool(Param, Value);
end;

function TCheckAdapter.OwnCaption(C: TControl): string;
begin
  if C is TCheckBox then
    Result := MCPCleanCaption(TCheckBox(C).Text)
  else
    Result := '';
end;

{ TTrackAdapter }

function TTrackAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomTrack;
end;

function TTrackAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('number');
  AddRange(Result, TCustomTrack(C).Min, TCustomTrack(C).Max);
end;

procedure TTrackAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
var
  V: Double;
begin
  V := MCPArgFloat(Param, Value);
  CheckRange(Param, V, TCustomTrack(C).Min, TCustomTrack(C).Max);
  TCustomTrack(C).Value := V;
end;

{ TDateEditAdapter }

function TDateEditAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomDateEdit;
end;

function TDateEditAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  Result.AddPair('format', 'date');
end;

procedure TDateEditAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  TCustomDateEdit(C).Date := MCPArgDate(Param, Value);
end;

{ TTimeEditAdapter }

function TTimeEditAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomTimeEdit;
end;

function TTimeEditAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := TypeSchema('string');
  Result.AddPair('pattern', '^\d{2}:\d{2}(:\d{2})?$');
end;

procedure TTimeEditAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  TCustomTimeEdit(C).Time := MCPArgTime(Param, Value);
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

procedure CollectControls(Parent: TFmxObject; List: TList<TControl>);
var
  I: Integer;
  Child: TFmxObject;
begin
  for I := 0 to Parent.ChildrenCount - 1 do
  begin
    Child := Parent.Children[I];
    if Child is TControl then
    begin
      List.Add(TControl(Child));
      if FindAdapter(TControl(Child)) <> nil then
        Continue; // do not descend into the style of an input control
    end;
    CollectControls(Child, List);
  end;
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
  Result := Adapter.OwnCaption(C);
  if Result <> '' then
    Exit;
  Labels := TList<TMCPLabelCandidate>.Create;
  try
    for X in All do
      if (X is TLabel) and X.ParentedVisible then
      begin
        L.Rect := X.AbsoluteRect;
        L.Text := TLabel(X).Text;
        Labels.Add(L);
      end;
    Result := MCPPickLabel(C.AbsoluteRect, Labels.ToArray);
  finally
    Labels.Free;
  end;
  if (Result = '') and (C is TCustomEdit) then
    Result := Trim(TCustomEdit(C).TextPrompt);
end;

function ResolveParams(Tool: TMCPFormTool; Container: TFmxObject): TArray<TParamInfo>;
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
           (C = Tool.SubmitControl) or (C = Tool.CancelControl) then
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
  FHighlightColor := $FF0078D7;
end;

destructor TMCPFormTool.Destroy;
begin
  UnhookControls;
  FreeAndNil(FFrame);
  inherited;
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
  if AComponent = FFrame then
    FFrame := nil;
  if FParams <> nil then
    for I := 0 to FParams.Count - 1 do
      if FParams[I].Control = AComponent then
        FParams[I].FControl := nil;
end;

procedure TMCPFormTool.SetContainer(Value: TFmxObject);
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

function TMCPFormTool.EffectiveContainer: TFmxObject;
begin
  Result := FContainer;
  if (Result = nil) and (Owner is TFmxObject) then
    Result := TFmxObject(Owner);
end;

function TMCPFormTool.BuildInputSchema: TJSONObject;
var
  Container: TFmxObject;
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
  C: TFmxObject;
begin
  C := EffectiveContainer;
  if C is TCommonCustomForm then
    Result := TCommonCustomForm(C).Visible
  else if C is TControl then
    Result := TControl(C).ParentedVisible and TControl(C).Enabled and
      (TControl(C).Root <> nil) and (TControl(C).Root.GetObject is TCommonCustomForm) and
      TCommonCustomForm(TControl(C).Root.GetObject).Visible
  else
    Result := False;
end;

procedure TMCPFormTool.ShowActive(Value: Boolean);
var
  C: TFmxObject;
begin
  FreeAndNil(FFrame);
  if not Value then
    Exit;
  C := EffectiveContainer;
  if C = nil then
    Exit;
  FFrame := TRectangle.Create(nil);
  FFrame.FreeNotification(Self);
  FFrame.Parent := C;
  FFrame.Align := TAlignLayout.Contents;
  FFrame.HitTest := False;
  FFrame.Fill.Kind := TBrushKind.None;
  FFrame.Stroke.Color := FHighlightColor;
  FFrame.Stroke.Thickness := 3;
  FFrame.BringToFront;
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

function MCPFmxConfirm(const Tool: IMCPTool; const Args: TJSONObject): Boolean;
var
  Text: string;
begin
  Text := Args.ToJSON;
  if Length(Text) > 600 then
    Text := Copy(Text, 1, 600) + '...';
  Result := TDialogServiceSync.MessageDialog(
    Format('An AI agent wants to run "%s":'#13#10'%s'#13#10#13#10'%s'#13#10#13#10'Allow it?',
      [Tool.Name, Tool.Description, Text]),
    TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0) = mrYes;
end;

initialization
  GAdapters := TObjectList<TMCPControlAdapter>.Create(True);
  // Insert(0): later registrations are checked first
  RegisterMCPControlAdapter(TEditAdapter.Create);
  RegisterMCPControlAdapter(TComboEditAdapter.Create);
  RegisterMCPControlAdapter(TEditBoxAdapter.Create);
  RegisterMCPControlAdapter(TMemoAdapter.Create);
  RegisterMCPControlAdapter(TComboBoxAdapter.Create);
  RegisterMCPControlAdapter(TCheckAdapter.Create);
  RegisterMCPControlAdapter(TTrackAdapter.Create);
  RegisterMCPControlAdapter(TDateEditAdapter.Create);
  RegisterMCPControlAdapter(TTimeEditAdapter.Create);
  if not Assigned(ModelContext.ConfirmHandler) then
    ModelContext.ConfirmHandler := MCPFmxConfirm;

finalization
  FreeAndNil(GAdapters);

end.
