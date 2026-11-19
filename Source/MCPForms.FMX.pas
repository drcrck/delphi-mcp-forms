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

  Lists and grids are read by screen snapshots (MCPForms.Screen), not written:
    TListBox                               -> array of strings / of (text, checked)
    TStringGrid                            -> table (headers from the columns)
    TListView                              -> array of texts, or (text, detail)

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
    /// Current value as JSON (string, number, boolean, or TJSONNull for "no
    /// value"), or nil when the adapter cannot read it. Used by the screen
    /// snapshots of MCPForms.Screen; optional for third-party adapters.
    function GetValue(C: TControl): TJSONValue; virtual;
    /// Puts back a value GetValue read, when an assistant fill is rolled back
    /// (never used for an agent's arguments). TJSONNull is the empty state.
    /// False when it cannot. The default writes a non-null value with
    /// SetValue and cannot restore null.
    function RestoreValue(C: TControl; Saved: TJSONValue): Boolean; virtual;
    /// A list or a grid: read by screen snapshots (GetValue returns an
    /// array, at most MCPScreenMaxRows rows), never a form tool parameter.
    function IsDataView(C: TControl): Boolean; virtual;
    /// A list or a grid: the selected row (TJSONNumber, 0-based), the selected
    /// rows (TJSONArray), TJSONNull, or nil when unknown.
    function GetSelection(C: TControl): TJSONValue; virtual;
    /// A list or a grid: how many rows it has. -1 otherwise.
    function RowCount(C: TControl): Integer; virtual;
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
    procedure ApplyArguments(const Args: TJSONObject; Partial: Boolean); override;
    function EmptyRequired: TArray<string>; override;
    function IsUsable: Boolean; override;
    procedure ShowActive(Value: Boolean); override;
    procedure ClickSubmit; override;
    procedure BringToUser; override;
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
  FMX.DateTimeCtrls, FMX.DialogService.Sync, FMX.Text, FMX.Graphics, FMX.TabControl,
  FMX.Grid, FMX.ListView, FMX.ListView.Appearances,
  System.Messaging,
  MCPForms.Screen;

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

function TMCPControlAdapter.GetValue(C: TControl): TJSONValue;
begin
  Result := nil;
end;

function TMCPControlAdapter.RestoreValue(C: TControl; Saved: TJSONValue): Boolean;
begin
  if (Saved = nil) or (Saved is TJSONNull) then
    Exit(False);
  try
    SetValue(C, '', Saved);
    Result := True;
  except
    Result := False;
  end;
end;

function TMCPControlAdapter.IsDataView(C: TControl): Boolean;
begin
  Result := False;
end;

function TMCPControlAdapter.GetSelection(C: TControl): TJSONValue;
begin
  Result := nil;
end;

function TMCPControlAdapter.RowCount(C: TControl): Integer;
begin
  Result := -1;
end;

function NumberValue(V: Double; AsInteger: Boolean): TJSONValue;
begin
  if AsInteger then
    Result := TJSONNumber.Create(Int64(Round(V)))
  else
    Result := TJSONNumber.Create(V);
end;

{ Built-in adapters }

type
  TEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
  end;

  TComboEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
  end;

  TEditBoxAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
  end;

  TMemoAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
  end;

  TComboBoxAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function RestoreValue(C: TControl; Saved: TJSONValue): Boolean; override;
  end;

  TCheckAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function OwnCaption(C: TControl): string; override;
  end;

  TTrackAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
  end;

  TDateEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function RestoreValue(C: TControl; Saved: TJSONValue): Boolean; override;
  end;

  TTimeEditAdapter = class(TMCPControlAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function RestoreValue(C: TControl; Saved: TJSONValue): Boolean; override;
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

function TEditAdapter.GetValue(C: TControl): TJSONValue;
begin
  Result := TJSONString.Create(TCustomEdit(C).Text);
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

function TComboEditAdapter.GetValue(C: TControl): TJSONValue;
begin
  Result := TJSONString.Create(TCustomComboEdit(C).Text);
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

function TEditBoxAdapter.GetValue(C: TControl): TJSONValue;
var
  B: TCustomEditBox;
begin
  B := TCustomEditBox(C);
  Result := NumberValue(B.Value, B.ValueType = TNumValueType.Integer);
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

function TMemoAdapter.GetValue(C: TControl): TJSONValue;
begin
  Result := TJSONString.Create(TCustomMemo(C).Text);
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

function TComboBoxAdapter.GetValue(C: TControl): TJSONValue;
var
  Cb: TCustomComboBox;
begin
  Cb := TCustomComboBox(C);
  if (Cb.ItemIndex >= 0) and (Cb.ItemIndex < Cb.Count) then
    Result := TJSONString.Create(Cb.ListItems[Cb.ItemIndex].Text)
  else
    Result := TJSONNull.Create;
end;

function TComboBoxAdapter.RestoreValue(C: TControl; Saved: TJSONValue): Boolean;
begin
  if not (Saved is TJSONNull) then
    Exit(inherited);
  TCustomComboBox(C).ItemIndex := -1;
  Result := True;
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

function TCheckAdapter.GetValue(C: TControl): TJSONValue;
begin
  if C is TCheckBox then
    Result := TJSONBool.Create(TCheckBox(C).IsChecked)
  else
    Result := TJSONBool.Create(TCustomSwitch(C).IsChecked);
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

function TTrackAdapter.GetValue(C: TControl): TJSONValue;
begin
  Result := NumberValue(TCustomTrack(C).Value, False);
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

function TDateEditAdapter.GetValue(C: TControl): TJSONValue;
var
  D: TCustomDateEdit;
begin
  D := TCustomDateEdit(C);
  if D.IsEmpty or (D.ShowCheckBox and not D.IsChecked) then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(FormatDateTime('yyyy"-"mm"-"dd', D.Date));
end;

function TDateEditAdapter.RestoreValue(C: TControl; Saved: TJSONValue): Boolean;
begin
  if not (Saved is TJSONNull) then
    Exit(inherited);
  if TCustomDateEdit(C).ShowCheckBox then
    TCustomDateEdit(C).IsChecked := False
  else
    TCustomDateEdit(C).IsEmpty := True;
  Result := True;
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

function TTimeEditAdapter.GetValue(C: TControl): TJSONValue;
var
  T: TCustomTimeEdit;
begin
  T := TCustomTimeEdit(C);
  if T.IsEmpty or (T.ShowCheckBox and not T.IsChecked) then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(FormatDateTime('hh":"nn":"ss', T.Time));
end;

function TTimeEditAdapter.RestoreValue(C: TControl; Saved: TJSONValue): Boolean;
begin
  if not (Saved is TJSONNull) then
    Exit(inherited);
  if TCustomTimeEdit(C).ShowCheckBox then
    TCustomTimeEdit(C).IsChecked := False
  else
    TCustomTimeEdit(C).IsEmpty := True;
  Result := True;
end;

{ Lists and grids }

type
  /// Base of the read-only adapters: lists and grids.
  TDataViewAdapter = class(TMCPControlAdapter)
  public
    function IsDataView(C: TControl): Boolean; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
  end;

  TListBoxAdapter = class(TDataViewAdapter)
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    function GetValue(C: TControl): TJSONValue; override;
    function GetSelection(C: TControl): TJSONValue; override;
    function RowCount(C: TControl): Integer; override;
  end;

  TStringGridAdapter = class(TDataViewAdapter)
  private
    function VisibleCols(G: TStringGrid): TArray<Integer>;
    function Keys(G: TStringGrid; out Titles: TArray<string>): TArray<string>;
  public
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    function GetValue(C: TControl): TJSONValue; override;
    function GetSelection(C: TControl): TJSONValue; override;
    function RowCount(C: TControl): Integer; override;
  end;

  /// TListView: Text, and Detail when an item has one.
  TListViewAdapter = class(TDataViewAdapter)
  private
    function HasDetail(L: TAppearanceListView): Boolean;
  public
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    function GetValue(C: TControl): TJSONValue; override;
    function GetSelection(C: TControl): TJSONValue; override;
    function RowCount(C: TControl): Integer; override;
  end;

type
  TCustomListBoxAccess = class(TCustomListBox);

{ TDataViewAdapter }

function TDataViewAdapter.IsDataView(C: TControl): Boolean;
begin
  Result := True;
end;

procedure TDataViewAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  raise MCPReadOnlyDataError(Param);
end;

{ TListBoxAdapter }

function TListBoxAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomListBox;
end;

function TListBoxAdapter.Schema(C: TControl): TJSONObject;
begin
  Result := MCPListSchema(TCustomListBoxAccess(C).ShowCheckboxes);
end;

function TListBoxAdapter.GetValue(C: TControl): TJSONValue;
var
  L: TCustomListBox;
  A: TJSONArray;
  I: Integer;
begin
  L := TCustomListBox(C);
  A := TJSONArray.Create;
  for I := 0 to Min(L.Count, MCPScreenMaxRows) - 1 do
    A.AddElement(MCPListItem(L.ListItems[I].Text, TCustomListBoxAccess(L).ShowCheckboxes,
      L.ListItems[I].IsChecked));
  Result := A;
end;

function TListBoxAdapter.GetSelection(C: TControl): TJSONValue;
var
  L: TCustomListBox;
  A: TJSONArray;
  I: Integer;
begin
  L := TCustomListBox(C);
  if TCustomListBoxAccess(L).MultiSelectStyle <> TMultiSelectStyle.None then
  begin
    A := TJSONArray.Create;
    for I := 0 to L.Count - 1 do
      if L.ListItems[I].IsSelected then
        A.Add(I);
    Result := A;
  end
  else if L.ItemIndex >= 0 then
    Result := TJSONNumber.Create(L.ItemIndex)
  else
    Result := TJSONNull.Create;
end;

function TListBoxAdapter.RowCount(C: TControl): Integer;
begin
  Result := TCustomListBox(C).Count;
end;

{ TStringGridAdapter }

function TStringGridAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TStringGrid;
end;

function TStringGridAdapter.VisibleCols(G: TStringGrid): TArray<Integer>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to G.ColumnCount - 1 do
    if G.Columns[I].Visible then
      Result := Result + [I];
end;

function TStringGridAdapter.Keys(G: TStringGrid; out Titles: TArray<string>): TArray<string>;
var
  Cols: TArray<Integer>;
  I: Integer;
begin
  Cols := VisibleCols(G);
  SetLength(Titles, Length(Cols));
  for I := 0 to High(Cols) do
    Titles[I] := MCPCleanCaption(G.Columns[Cols[I]].Header);
  Result := MCPColumnKeys(Titles);
end;

function TStringGridAdapter.Schema(C: TControl): TJSONObject;
var
  Titles: TArray<string>;
begin
  Result := MCPTableSchema(Keys(TStringGrid(C), Titles), Titles);
end;

function TStringGridAdapter.GetValue(C: TControl): TJSONValue;
var
  G: TStringGrid;
  A: TJSONArray;
  Row: TJSONObject;
  Cols: TArray<Integer>;
  K, Titles: TArray<string>;
  R, I: Integer;
begin
  G := TStringGrid(C);
  Cols := VisibleCols(G);
  K := Keys(G, Titles);
  A := TJSONArray.Create;
  for R := 0 to Min(G.RowCount, MCPScreenMaxRows) - 1 do
  begin
    Row := TJSONObject.Create;
    for I := 0 to High(Cols) do
      Row.AddPair(K[I], G.Cells[Cols[I], R]);
    A.AddElement(Row);
  end;
  Result := A;
end;

function TStringGridAdapter.GetSelection(C: TControl): TJSONValue;
begin
  if TStringGrid(C).Selected >= 0 then
    Result := TJSONNumber.Create(TStringGrid(C).Selected)
  else
    Result := TJSONNull.Create;
end;

function TStringGridAdapter.RowCount(C: TControl): Integer;
begin
  Result := TStringGrid(C).RowCount;
end;

{ TListViewAdapter }

function TListViewAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TAppearanceListView;
end;

function TListViewAdapter.HasDetail(L: TAppearanceListView): Boolean;
var
  I: Integer;
begin
  for I := 0 to Min(L.Items.Count, MCPScreenMaxRows) - 1 do
    if L.Items[I].Detail <> '' then
      Exit(True);
  Result := False;
end;

function TListViewAdapter.Schema(C: TControl): TJSONObject;
begin
  if HasDetail(TAppearanceListView(C)) then
    Result := MCPTableSchema(['text', 'detail'], ['Text', 'Detail'])
  else
    Result := MCPListSchema;
end;

function TListViewAdapter.GetValue(C: TControl): TJSONValue;
var
  L: TAppearanceListView;
  A: TJSONArray;
  Row: TJSONObject;
  Detail: Boolean;
  I: Integer;
begin
  L := TAppearanceListView(C);
  Detail := HasDetail(L);
  A := TJSONArray.Create;
  for I := 0 to Min(L.Items.Count, MCPScreenMaxRows) - 1 do
    if Detail then
    begin
      Row := TJSONObject.Create;
      Row.AddPair('text', L.Items[I].Text);
      Row.AddPair('detail', L.Items[I].Detail);
      A.AddElement(Row);
    end
    else
      A.Add(L.Items[I].Text);
  Result := A;
end;

function TListViewAdapter.GetSelection(C: TControl): TJSONValue;
begin
  if TAppearanceListView(C).ItemIndex >= 0 then
    Result := TJSONNumber.Create(TAppearanceListView(C).ItemIndex)
  else
    Result := TJSONNull.Create;
end;

function TListViewAdapter.RowCount(C: TControl): Integer;
begin
  Result := TAppearanceListView(C).Items.Count;
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
        if P.Adapter.IsDataView(C) then
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

procedure TMCPFormTool.ApplyArguments(const Args: TJSONObject; Partial: Boolean);
type
  TUndo = TPair<TParamInfo, TJSONValue>;
var
  Params: TArray<TParamInfo>;
  P: TParamInfo;
  Pair: TJSONPair;
  Known: Boolean;
  Missing: string;
  Undo: TList<TUndo>;
  I: Integer;
  Saved: TJSONValue;
  Restored: Boolean;
  NotRestored: string;
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
  if not Partial then
  begin
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
    Exit;
  end;

  // Partial (Fill): what can be checked without writing is checked first...
  for P in Params do
    if (Args.GetValue(P.Name) <> nil) and not P.Control.Enabled then
      raise EMCPToolError.CreateFmt('Parameter "%s" cannot be changed right now.', [P.Name]);
  // ...and the conversion of each value happens in SetValue: when one is
  // refused, the controls written before it get their previous value back.
  Undo := TList<TUndo>.Create;
  try
    try
      for P in Params do
        if Args.GetValue(P.Name) <> nil then
        begin
          Saved := P.Adapter.GetValue(P.Control);
          try
            P.Adapter.SetValue(P.Control, P.Name, Args.GetValue(P.Name));
          except
            Saved.Free; // refused: this control was not written
            raise;
          end;
          Undo.Add(TUndo.Create(P, Saved));
        end;
    except
      on E: Exception do
      begin
        NotRestored := '';
        for I := Undo.Count - 1 downto 0 do
        begin
          Restored := False;
          try
            Restored := Undo[I].Key.Adapter.RestoreValue(Undo[I].Key.Control, Undo[I].Value);
          except
            // reported below
          end;
          if not Restored then
          begin
            if NotRestored <> '' then
              NotRestored := ', ' + NotRestored;
            NotRestored := '"' + Undo[I].Key.Name + '"' + NotRestored;
          end;
        end;
        if NotRestored = '' then
          raise;
        raise EMCPToolError.Create(E.Message + ' Nothing else was changed, but these ' +
          'fields keep the new value and could not be put back: ' + NotRestored + '.');
      end;
    end;
  finally
    for I := 0 to Undo.Count - 1 do
      Undo[I].Value.Free;
    Undo.Free;
  end;
end;

function TMCPFormTool.EmptyRequired: TArray<string>;
var
  P: TParamInfo;
  V: TJSONValue;
begin
  Result := nil;
  if EffectiveContainer = nil then
    Exit;
  for P in ResolveParams(Self, EffectiveContainer) do
    if P.Required then
    begin
      V := P.Adapter.GetValue(P.Control);
      try
        // nil: the adapter cannot tell, so it is not reported
        if (V is TJSONNull) or ((V is TJSONString) and (Trim(V.Value) = '')) then
          Result := Result + [P.Name];
      finally
        V.Free;
      end;
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

procedure TMCPFormTool.BringToUser;
var
  C: TFmxObject;
  F: TCommonCustomForm;
begin
  C := EffectiveContainer;
  F := nil;
  if C is TCommonCustomForm then
    F := TCommonCustomForm(C)
  else if (C is TControl) and (TControl(C).Root <> nil) and
          (TControl(C).Root.GetObject is TCommonCustomForm) then
    F := TCommonCustomForm(TControl(C).Root.GetObject);
  if F = nil then
    Exit;
  if F.WindowState = TWindowState.wsMinimized then
    F.WindowState := TWindowState.wsNormal;
  F.BringToFront;
end;

procedure TMCPFormTool.ClickSubmit;
begin
  if FSubmitControl = nil then
    raise EMCPToolError.Create('This form has no submit button configured.');
  if not FSubmitControl.Enabled then
    raise EMCPToolError.Create('The submit button is disabled: check the values and try again.');
  TControlAccess(FSubmitControl).Click;
end;

{ Screen snapshot }

type
  TKnownParam = record
    Name: string;
    Description: string;
    Required: Boolean;
    Tool: string;
  end;

var
  // The form activated last that is not ignored (FMX keeps no z-order list).
  GLastForm: TCommonCustomForm;
  GActivateSub: TMessageSubscriptionId;

procedure CollectFormTools(Owner: TComponent; List: TList<TMCPFormTool>);
var
  I: Integer;
  C: TComponent;
begin
  for I := 0 to Owner.ComponentCount - 1 do
  begin
    C := Owner.Components[I];
    if C is TMCPFormTool then
      List.Add(TMCPFormTool(C))
    else if C is TFrame then
      CollectFormTools(C, List);
  end;
end;

/// Visible as far as the user is concerned; an inactive tab counts as visible
/// (it is one click away). Tab is the caption of the innermost tab item,
/// TabHidden whether a tab on the way is not the active one.
function VisibleOnForm(C: TControl; out Tab: string; out TabHidden: Boolean): Boolean;
var
  X: TFmxObject;
  Item: TTabItem;
begin
  Tab := '';
  TabHidden := False;
  X := C;
  while X is TControl do
  begin
    if X is TTabItem then
    begin
      Item := TTabItem(X);
      if not Item.Visible then
        Exit(False);
      if Tab = '' then
        Tab := MCPCleanCaption(Item.Text);
      if (Item.TabControl <> nil) and (Item.TabControl.ActiveTab <> Item) then
        TabHidden := True;
    end
    else if not TControl(X).Visible then
      Exit(False);
    X := X.Parent;
  end;
  Result := True;
end;

/// C or one of its parents was excluded with MCPIgnoreScreenControl.
function InIgnored(C: TControl): Boolean;
var
  X: TFmxObject;
begin
  X := C;
  while X is TControl do
  begin
    if MCPIsIgnoredScreenControl(X) then
      Exit(True);
    X := X.Parent;
  end;
  Result := False;
end;

function ReadFmxScreen(Root: TComponent): TMCPScreen;
var
  Form: TCommonCustomForm;
  Tools: TList<TMCPFormTool>;
  Tool: TMCPFormTool;
  Known: TDictionary<TControl, TKnownParam>;
  KP: TKnownParam;
  P: TParamInfo;
  All: TList<TControl>;
  Names: TList<string>;
  C: TControl;
  Adapter: TMCPControlAdapter;
  F: TMCPScreenField;
  Name, Tab, Caption: string;
  TabHidden: Boolean;
  Focused: TFmxObject;
begin
  if not (Root is TCommonCustomForm) then
    Exit(nil);
  Form := TCommonCustomForm(Root);
  Result := TMCPScreen.Create;
  Tools := TList<TMCPFormTool>.Create;
  Known := TDictionary<TControl, TKnownParam>.Create;
  All := TList<TControl>.Create;
  Names := TList<string>.Create;
  try
   try
    Result.Form := Form.Name;
    Result.Title := MCPCleanCaption(Form.Caption);

    // What the form tools of this form say about their controls wins: the same
    // names, descriptions and required flags a client gets in tools/list.
    CollectFormTools(Form, Tools);
    for Tool in Tools do
    begin
      if Tool.RegisteredName <> '' then
        Result.Tools := Result.Tools + [Tool.RegisteredName];
      if Tool.EffectiveContainer = nil then
        Continue;
      try
        for P in ResolveParams(Tool, Tool.EffectiveContainer) do
          if not Known.ContainsKey(P.Control) then
          begin
            KP.Name := P.Name;
            KP.Description := P.Description;
            KP.Required := P.Required;
            KP.Tool := Tool.RegisteredName;
            Known.Add(P.Control, KP);
          end;
      except
        // a misconfigured tool must not hide the screen
      end;
    end;

    CollectControls(Form, All);
    for C in All do
    begin
      if (C.Name = '') or (C is TLabel) or not VisibleOnForm(C, Tab, TabHidden) or
         InIgnored(C) then
        Continue;
      if C is TCustomButton then
      begin
        Caption := MCPCleanCaption(TCustomButton(C).Text);
        if (Caption = '') and (C.Hint <> '') then
          Caption := Trim(C.Hint);
        Result.AddButton(C.Name, Caption, C.AbsoluteEnabled);
        Continue;
      end;
      Adapter := FindAdapter(C);
      if Adapter = nil then
        Continue;
      if not Known.TryGetValue(C, KP) then
      begin
        KP.Name := MCPParamNameFromComponent(C.Name);
        KP.Description := DescribeControl(C, Adapter, All);
        KP.Required := False;
        KP.Tool := '';
      end;
      Name := KP.Name;
      if Names.Contains(Name) then
        Name := C.Name;
      Names.Add(Name);

      F := Result.AddField(Name, Adapter.Schema(C));
      F.Title := KP.Description;
      F.Required := KP.Required;
      F.Tool := KP.Tool;
      F.Tab := Tab;
      F.TabHidden := TabHidden;
      F.Disabled := not C.AbsoluteEnabled;
      F.ReadOnly := ((C is TCustomEdit) and TCustomEdit(C).ReadOnly) or
        ((C is TCustomMemo) and TCustomMemo(C).ReadOnly);
      F.Secret := (C is TCustomEdit) and TCustomEdit(C).Password;
      if Adapter.IsDataView(C) then
      begin
        F.ReadOnly := True;
        F.TotalRows := Adapter.RowCount(C);
        try
          F.Selection := Adapter.GetSelection(C);
        except
          F.Selection := nil;
        end;
      end;
      if not F.Secret then
        try
          F.Value := Adapter.GetValue(C);
        except
          F.Value := nil; // an unreadable control is reported as unknown
        end;
    end;

    if Form.Focused <> nil then
    begin
      Focused := Form.Focused.GetObject;
      while Focused is TControl do
      begin
        if Known.TryGetValue(TControl(Focused), KP) then
        begin
          Result.Focused := KP.Name;
          Break;
        end;
        if FindAdapter(TControl(Focused)) <> nil then
        begin
          Result.Focused := MCPParamNameFromComponent(Focused.Name);
          Break;
        end;
        Focused := Focused.Parent;
      end;
    end;
   except
    FreeAndNil(Result);
    raise;
   end;
  finally
    Names.Free;
    All.Free;
    Known.Free;
    Tools.Free;
  end;
end;

function IsLiveForm(F: TCommonCustomForm): Boolean;
var
  I: Integer;
begin
  for I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I] = F then
      Exit(True);
  Result := False;
end;

function ActiveFmxForm: TComponent;
var
  F: TCommonCustomForm;
  I: Integer;
begin
  F := Screen.ActiveForm;
  if (F <> nil) and F.Visible and not MCPIsIgnoredScreen(F) then
    Exit(F);
  if (GLastForm <> nil) and IsLiveForm(GLastForm) and GLastForm.Visible then
    Exit(GLastForm);
  for I := 0 to Screen.FormCount - 1 do
  begin
    F := Screen.Forms[I];
    if F.Visible and not MCPIsIgnoredScreen(F) then
      Exit(F);
  end;
  Result := Application.MainForm;
end;

function ListFmxForms: TArray<TComponent>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I].Visible then
      Result := Result + [Screen.Forms[I]];
end;

procedure FormActivated(const Sender: TObject; const M: TMessage);
var
  F: TCommonCustomForm;
begin
  F := TFormActivateMessage(M).Value;
  if (F <> nil) and not MCPIsIgnoredScreen(F) then
    GLastForm := F;
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
  RegisterMCPControlAdapter(TListBoxAdapter.Create);
  RegisterMCPControlAdapter(TStringGridAdapter.Create);
  RegisterMCPControlAdapter(TListViewAdapter.Create);
  if not Assigned(ModelContext.ConfirmHandler) then
    ModelContext.ConfirmHandler := MCPFmxConfirm;
  MCPRegisterScreenReader(ReadFmxScreen, ActiveFmxForm, ListFmxForms);
  GActivateSub := TMessageManager.DefaultManager.SubscribeToMessage(
    TFormActivateMessage, FormActivated);

finalization
  TMessageManager.DefaultManager.Unsubscribe(TFormActivateMessage, GActivateSub);
  FreeAndNil(GAdapters);

end.
