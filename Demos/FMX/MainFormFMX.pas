unit MainFormFMX;

{ FMX demo: a "book a room" form built in code, exposed as the declarative
  tool "book-room", plus an imperative read-only tool. MCP endpoint:
  http://127.0.0.1:8766/mcp }

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.JSON, System.StrUtils,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.EditBox,
  FMX.SpinBox, FMX.ListBox, FMX.DateTimeCtrls, FMX.Memo, FMX.Layouts,
  FMX.Controls.Presentation, FMX.ScrollBox,
  MCPForms.Core, MCPForms.FMX, MCPForms.Transport.HTTP, MCPForms.Transport.WinMsg;

type
  TFormMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FServer: TMCPHttpServer;
    FWinMsg: TMCPWinMsgServer;
    FTool: TMCPFormTool;
    FBooking: TLayout;
    FGuest: TEdit;
    FRoom: TComboBox;
    FNights: TSpinBox;
    FArrival: TDateEdit;
    FBreakfast: TSwitch;
    FBook: TButton;
    FBookings: TListBox;
    FLog: TMemo;
    function AddLabel(const Text: string; Y: Single): TLabel;
    procedure BookClick(Sender: TObject);
    procedure Submitted(Sender: TObject; AgentInvoked: Boolean; var Response: string);
    procedure AddLog(const Msg: string);
  end;

var
  FormMain: TFormMain;

implementation

{$R *.fmx}

function TFormMain.AddLabel(const Text: string; Y: Single): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := FBooking;
  Result.SetBounds(16, Y, 110, 22);
  Result.Text := Text;
end;

procedure TFormMain.FormCreate(Sender: TObject);
var
  Room: string;
begin
  FBooking := TLayout.Create(Self);
  FBooking.Parent := Self;
  FBooking.SetBounds(12, 12, 400, 290);

  AddLabel('Guest name:', 20);
  FGuest := TEdit.Create(Self);
  FGuest.Name := 'edtGuest';
  FGuest.Parent := FBooking;
  FGuest.SetBounds(130, 18, 250, 24);
  FGuest.TextPrompt := 'Name and surname';

  AddLabel('Room:', 60);
  FRoom := TComboBox.Create(Self);
  FRoom.Name := 'cbRoom';
  FRoom.Parent := FBooking;
  FRoom.SetBounds(130, 58, 250, 24);
  for Room in ['Single', 'Double', 'Suite'] do
    FRoom.Items.Add(Room);

  AddLabel('Nights:', 100);
  FNights := TSpinBox.Create(Self);
  FNights.Name := 'spnNights';
  FNights.Parent := FBooking;
  FNights.SetBounds(130, 98, 100, 24);
  FNights.Min := 1;
  FNights.Max := 30;
  FNights.Value := 1;

  AddLabel('Arrival:', 140);
  FArrival := TDateEdit.Create(Self);
  FArrival.Name := 'dteArrival';
  FArrival.Parent := FBooking;
  FArrival.SetBounds(130, 138, 140, 24);
  FArrival.Date := Date + 1;

  AddLabel('Breakfast:', 180);
  FBreakfast := TSwitch.Create(Self);
  FBreakfast.Name := 'swBreakfast';
  FBreakfast.Parent := FBooking;
  FBreakfast.SetBounds(130, 178, 60, 26);

  FBook := TButton.Create(Self);
  FBook.Parent := FBooking;
  FBook.SetBounds(280, 240, 100, 30);
  FBook.Text := 'Book';
  FBook.OnClick := BookClick;

  FBookings := TListBox.Create(Self);
  FBookings.Parent := Self;
  FBookings.SetBounds(430, 12, 318, 290);

  FLog := TMemo.Create(Self);
  FLog.Parent := Self;
  FLog.SetBounds(12, 316, 736, 192);
  FLog.ReadOnly := True;

  ModelContext.ServerName := 'delphi-mcp-forms-fmx-demo';
  ModelContext.OnLog :=
    procedure(const Msg: string)
    begin
      TThread.Queue(nil,
        procedure
        begin
          AddLog(Msg);
        end);
    end;

  FTool := TMCPFormTool.Create(Self);
  FTool.Container := FBooking;
  FTool.SubmitControl := FBook;
  FTool.OnSubmit := Submitted;
  FTool.ToolDescription := 'Book a hotel room. Fills the booking form and submits it.';
  FTool.AutoSubmit := True; // toolautosubmit: no click needed
  FTool.ToolName := 'book-room';

  ModelContext.RegisterTool('list-bookings', 'List the bookings made so far.',
    TMCPSchema.Empty, TMCPToolAnnotations.ReadOnly,
    function(const Args: TJSONObject): string
    var
      I: Integer;
    begin
      Result := '';
      for I := 0 to FBookings.Count - 1 do
        Result := Result + FBookings.ListItems[I].Text + sLineBreak;
      if Result = '' then
        Result := 'No bookings yet.';
    end);

  FServer := TMCPHttpServer.Create(8766);
  FServer.Start;
  FWinMsg := TMCPWinMsgServer.Create;
  FWinMsg.Start;
  Caption := Caption + '  -  ' + FServer.Url;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  ModelContext.OnLog := nil;
  FWinMsg.Free;
  FServer.Free;
  ModelContext.UnregisterTool('list-bookings');
end;

procedure TFormMain.BookClick(Sender: TObject);
begin
  if Trim(FGuest.Text) = '' then
  begin
    FTool.Reject('Guest name is required.');
    Abort;
  end;
  if FRoom.ItemIndex < 0 then
  begin
    FTool.Reject('Choose a room: Single, Double or Suite.');
    Abort;
  end;
  FBookings.Items.Add(Format('%s - %s, %d night(s) from %s%s', [FGuest.Text,
    FRoom.Selected.Text, Round(FNights.Value), FormatDateTime('yyyy-mm-dd', FArrival.Date),
    IfThen(FBreakfast.IsChecked, ', breakfast', '')]));
end;

procedure TFormMain.Submitted(Sender: TObject; AgentInvoked: Boolean; var Response: string);
begin
  Response := 'Booked: ' + FBookings.ListItems[FBookings.Count - 1].Text;
  FGuest.Text := '';
  FRoom.ItemIndex := -1;
  FNights.Value := 1;
  FBreakfast.IsChecked := False;
end;

procedure TFormMain.AddLog(const Msg: string);
begin
  if FLog <> nil then
    FLog.Lines.Add(FormatDateTime('hh:nn:ss ', Now) + Msg);
end;

end.
