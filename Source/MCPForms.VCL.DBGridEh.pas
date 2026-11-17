unit MCPForms.VCL.DBGridEh;

{ delphi-mcp-forms - TDBGridEh (EhLib) in screen snapshots (VCL).

  Add this unit to the uses clause and the screen snapshots of MCPForms.Screen
  read a TDBGridEh as a table: one property per visible column, titled with
  its caption (a multi-level title "Order|Date" reads "Order / Date"), one
  object per row with the text the grid shows (DisplayText: display formats,
  lookups and pick lists included), the current record as the selection.

  The rows are the ones the grid shows, read from its buffer: the dataset
  cursor does not move and no dataset event fires. totalRows is the dataset's
  RecordCount when it knows it.

  Separate from MCPForms.VCL.DB because it needs EhLib in the search path.

  MIT License - see LICENSE. }

interface

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.JSON,
  Data.DB, Vcl.Controls, DBGridEh,
  MCPForms.FormTool, MCPForms.VCL, MCPForms.Screen;

type
  TDBGridEhAdapter = class(TMCPControlAdapter)
  private
    function Cols(G: TCustomDBGridEh): TArray<TColumnEh>;
    function Keys(G: TCustomDBGridEh; out Titles: TArray<string>): TArray<string>;
  public
    function Supports(C: TControl): Boolean; override;
    function Schema(C: TControl): TJSONObject; override;
    procedure SetValue(C: TControl; const Param: string; Value: TJSONValue); override;
    function GetValue(C: TControl): TJSONValue; override;
    function IsDataView(C: TControl): Boolean; override;
    function GetSelection(C: TControl): TJSONValue; override;
    function RowCount(C: TControl): Integer; override;
  end;

function TDBGridEhAdapter.Supports(C: TControl): Boolean;
begin
  Result := C is TCustomDBGridEh;
end;

function TDBGridEhAdapter.IsDataView(C: TControl): Boolean;
begin
  Result := True;
end;

procedure TDBGridEhAdapter.SetValue(C: TControl; const Param: string; Value: TJSONValue);
begin
  raise MCPReadOnlyDataError(Param);
end;

function TDBGridEhAdapter.Cols(G: TCustomDBGridEh): TArray<TColumnEh>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to G.Columns.Count - 1 do
    if G.Columns[I].Visible then
      Result := Result + [G.Columns[I]];
end;

function TDBGridEhAdapter.Keys(G: TCustomDBGridEh; out Titles: TArray<string>): TArray<string>;
var
  C: TArray<TColumnEh>;
  I: Integer;
begin
  C := Cols(G);
  SetLength(Titles, Length(C));
  for I := 0 to High(C) do
  begin
    // "Order|Date" is a two-level title
    Titles[I] := MCPCleanCaption(StringReplace(C[I].Title.Caption, '|', ' / ', [rfReplaceAll]));
    if (Titles[I] = '') and (C[I].Field <> nil) then
      Titles[I] := C[I].Field.DisplayName;
    if Titles[I] = '' then
      Titles[I] := C[I].FieldName;
  end;
  Result := MCPColumnKeys(Titles);
end;

function TDBGridEhAdapter.Schema(C: TControl): TJSONObject;
var
  Titles: TArray<string>;
begin
  Result := MCPTableSchema(Keys(TCustomDBGridEh(C), Titles), Titles);
end;

function TDBGridEhAdapter.GetValue(C: TControl): TJSONValue;
var
  G: TCustomDBGridEh;
  Link: TGridDataLinkEh;
  Columns: TArray<TColumnEh>;
  K, Titles: TArray<string>;
  A: TJSONArray;
  Row: TJSONObject;
  Old, R, I: Integer;
  S: string;
begin
  G := TCustomDBGridEh(C);
  A := TJSONArray.Create;
  Result := A;
  Link := G.DataLink;
  if (Link = nil) or not Link.Active then
    Exit;
  Columns := Cols(G);
  K := Keys(G, Titles);
  // the records in the grid's buffer: no scrolling, no dataset events
  Old := Link.ActiveRecord;
  try
    for R := 0 to Min(Link.RecordCount, MCPScreenMaxRows) - 1 do
    begin
      Link.ActiveRecord := R;
      Row := TJSONObject.Create;
      for I := 0 to High(Columns) do
      begin
        try
          S := Columns[I].DisplayText;
        except
          S := ''; // a calculated or lookup column that cannot answer now
        end;
        Row.AddPair(K[I], S);
      end;
      A.AddElement(Row);
    end;
  finally
    Link.ActiveRecord := Old;
  end;
end;

function TDBGridEhAdapter.GetSelection(C: TControl): TJSONValue;
var
  Link: TGridDataLinkEh;
begin
  Link := TCustomDBGridEh(C).DataLink;
  if (Link <> nil) and Link.Active and (Link.RecordCount > 0) then
    Result := TJSONNumber.Create(Link.ActiveRecord)
  else
    Result := TJSONNull.Create;
end;

function TDBGridEhAdapter.RowCount(C: TControl): Integer;
var
  Link: TGridDataLinkEh;
begin
  Result := 0;
  Link := TCustomDBGridEh(C).DataLink;
  if (Link = nil) or not Link.Active then
    Exit;
  Result := Max(Link.DataSet.RecordCount, Link.RecordCount);
end;

initialization
  RegisterMCPControlAdapter(TDBGridEhAdapter.Create);

end.
