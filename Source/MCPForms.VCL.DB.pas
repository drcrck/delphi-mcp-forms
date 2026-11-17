unit MCPForms.VCL.DB;

{ delphi-mcp-forms - TDBGrid in screen snapshots (VCL).

  Add this unit to the uses clause and the screen snapshots of MCPForms.Screen
  read a TDBGrid as a table: one property per visible column (titled with the
  column caption), one object per row, the current record as the selection.

  The rows are the ones the grid shows, read from its buffer: the dataset
  cursor does not move and no dataset event fires. totalRows says how many
  records the dataset has when it knows (RecordCount).

  DB-aware edits (TDBEdit, TDBMemo...) need nothing: MCPForms.VCL already reads
  them as edits. This unit is separate only so that applications without
  databases do not link Data.DB.

  MIT License - see LICENSE. }

interface

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.JSON,
  Data.DB, Vcl.Controls, Vcl.DBGrids,
  MCPForms.FormTool, MCPForms.VCL, MCPForms.Screen;

type
  TDBGridAccess = class(TCustomDBGrid);

  TDBGridAdapter = class(TMCPControlAdapter)
  private
    function VisibleColumns(G: TDBGridAccess): TArray<TColumn>;
    function Keys(G: TDBGridAccess; out Titles: TArray<string>): TArray<string>;
  public
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function IsDataView(C: TControl): Boolean; override;
    function GetSelection(C: TControl): TJSONValue; override;
    function RowCount(C: TControl): Integer; override;
  end;

function TDBGridAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomDBGrid;
end;

function TDBGridAdapter.IsDataView(C: TControl): Boolean;
begin
  Result := True;
end;

procedure TDBGridAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  raise MCPReadOnlyDataError(Param);
end;

function TDBGridAdapter.VisibleColumns(G: TDBGridAccess): TArray<TColumn>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to G.Columns.Count - 1 do
    if G.Columns[I].Visible and (G.Columns[I].Field <> nil) then
      Result := Result + [G.Columns[I]];
end;

function TDBGridAdapter.Keys(G: TDBGridAccess; out Titles: TArray<string>): TArray<string>;
var
  Cols: TArray<TColumn>;
  I: Integer;
begin
  Cols := VisibleColumns(G);
  SetLength(Titles, Length(Cols));
  for I := 0 to High(Cols) do
  begin
    Titles[I] := MCPCleanCaption(Cols[I].Title.Caption);
    if Titles[I] = '' then
      Titles[I] := Cols[I].Field.DisplayName;
  end;
  Result := MCPColumnKeys(Titles);
end;

function TDBGridAdapter.Schema(C: TControl): TJSONObject;
var
  Titles: TArray<string>;
begin
  Result := MCPTableSchema(Keys(TDBGridAccess(C), Titles), Titles);
end;

function TDBGridAdapter.GetValue(C: TControl): TJSONValue;
var
  G: TDBGridAccess;
  Link: TGridDataLink;
  Cols: TArray<TColumn>;
  K, Titles: TArray<string>;
  A: TJSONArray;
  Row: TJSONObject;
  Old, R, I: Integer;
begin
  G := TDBGridAccess(C);
  A := TJSONArray.Create;
  Result := A;
  Link := G.DataLink;
  if (Link = nil) or not Link.Active then
    Exit;
  Cols := VisibleColumns(G);
  K := Keys(G, Titles);
  // the records in the grid's buffer: no scrolling, no dataset events
  Old := Link.ActiveRecord;
  try
    for R := 0 to Min(Link.RecordCount, MCPScreenMaxRows) - 1 do
    begin
      Link.ActiveRecord := R;
      Row := TJSONObject.Create;
      for I := 0 to High(Cols) do
        Row.AddPair(K[I], Cols[I].Field.DisplayText);
      A.AddElement(Row);
    end;
  finally
    Link.ActiveRecord := Old;
  end;
end;

function TDBGridAdapter.GetSelection(C: TControl): TJSONValue;
var
  Link: TGridDataLink;
begin
  Link := TDBGridAccess(C).DataLink;
  if (Link <> nil) and Link.Active and (Link.RecordCount > 0) then
    Result := TJSONNumber.Create(Link.ActiveRecord)
  else
    Result := TJSONNull.Create;
end;

function TDBGridAdapter.RowCount(C: TControl): Integer;
var
  Link: TGridDataLink;
begin
  Result := 0;
  Link := TDBGridAccess(C).DataLink;
  if (Link = nil) or not Link.Active then
    Exit;
  // RecordCount of the dataset when it knows it, else the rows shown
  Result := Link.DataSet.RecordCount;
  if Result < Link.RecordCount then
    Result := Link.RecordCount;
end;

initialization
  RegisterMCPControlAdapter(TDBGridAdapter.Create);

end.
