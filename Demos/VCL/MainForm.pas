unit MainForm;

{ VCL demo: one declarative tool (the "New order" group box) and two
  imperative tools (list-orders, delete-order). Connect an MCP client to
  http://127.0.0.1:8765/mcp and ask it to place an order. }

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Samples.Spin, Vcl.Dialogs,
  MCPForms.Core, MCPForms.VCL, MCPForms.Transport.HTTP, MCPForms.Transport.WinMsg;

type
  TfrmMain = class(TForm)
    lblServer: TLabel;
    grpOrder: TGroupBox;
    lblCustomer: TLabel;
    lblProduct: TLabel;
    lblQuantity: TLabel;
    lblDelivery: TLabel;
    lblNotes: TLabel;
    edtCustomer: TEdit;
    cbProduct: TComboBox;
    spnQuantity: TSpinEdit;
    dtpDelivery: TDateTimePicker;
    chkGiftWrap: TCheckBox;
    memNotes: TMemo;
    btnSave: TButton;
    btnClear: TButton;
    lstOrders: TListBox;
    memLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
  private
    FServer: TMCPHttpServer;
    FWinMsg: TMCPWinMsgServer;
    FOrderTool: TMCPFormTool;
    FNextOrder: Integer;
    procedure OrderSubmitted(Sender: TObject; AgentInvoked: Boolean; var Response: string);
    procedure ClearOrder;
    procedure AddLog(const Msg: string);
    procedure RegisterImperativeTools;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FNextOrder := 1;
  dtpDelivery.Date := Date + 7;

  ModelContext.ServerName := 'delphi-mcp-forms-vcl-demo';
  ModelContext.Instructions :=
    'Tools of a small order-entry desktop app. The user sees the form being filled.';
  ModelContext.OnLog :=
    procedure(const Msg: string)
    begin
      TThread.Queue(nil,
        procedure
        begin
          AddLog(Msg);
        end);
    end;

  // Declarative tool: the group box becomes "create-order". Parameters come
  // from the controls; descriptions from Hint and the labels' FocusControl.
  FOrderTool := TMCPFormTool.Create(Self);
  FOrderTool.Container := grpOrder;
  FOrderTool.SubmitControl := btnSave;
  FOrderTool.CancelControl := btnClear;
  FOrderTool.OnSubmit := OrderSubmitted;
  FOrderTool.ToolDescription :=
    'Create a sales order. Fills the "New order" form; the user reviews it and clicks Save.';
  FOrderTool.ToolName := 'create-order';

  RegisterImperativeTools;

  FServer := TMCPHttpServer.Create(8765);
  FServer.Start;
  // Same tools without a network port, through mcp_winmsg_bridge.exe
  FWinMsg := TMCPWinMsgServer.Create;
  FWinMsg.Start;
  lblServer.Caption := 'MCP server: ' + FServer.Url + '   WM_COPYDATA: ' + FWinMsg.Name;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  ModelContext.OnLog := nil;
  FWinMsg.Free;
  FServer.Free;
  ModelContext.UnregisterTool('list-orders');
  ModelContext.UnregisterTool('delete-order');
end;

procedure TfrmMain.RegisterImperativeTools;
begin
  ModelContext.RegisterTool('list-orders',
    'List the saved orders, one per line, with their numbers.',
    TMCPSchema.Empty,
    TMCPToolAnnotations.ReadOnly,
    function(const Args: TJSONObject): string
    begin
      if lstOrders.Count = 0 then
        Result := 'No orders yet.'
      else
        Result := lstOrders.Items.Text;
    end);

  ModelContext.RegisterTool('delete-order',
    'Delete a saved order by its number. The user is asked to confirm.',
    TMCPSchema.Create.Int('number', 'Order number, as shown by list-orders', True).Build,
    TMCPToolAnnotations.Consequential,
    function(const Args: TJSONObject): string
    var
      Number, I: Integer;
      Prefix: string;
    begin
      Number := Args.GetValue<Integer>('number');
      Prefix := Format('#%d ', [Number]);
      for I := 0 to lstOrders.Count - 1 do
        if lstOrders.Items[I].StartsWith(Prefix) then
        begin
          lstOrders.Items.Delete(I);
          Exit(Format('Order #%d deleted.', [Number]));
        end;
      raise EMCPToolError.CreateFmt('There is no order #%d. Call list-orders to see the numbers.', [Number]);
    end);
end;

procedure TfrmMain.btnSaveClick(Sender: TObject);
var
  Line: string;
begin
  if Trim(edtCustomer.Text) = '' then
  begin
    // Tell the agent what is wrong, then stop like a normal validation.
    FOrderTool.Reject('Customer is required.');
    ShowMessage('Customer is required.');
    Abort;
  end;
  if cbProduct.ItemIndex < 0 then
  begin
    FOrderTool.Reject('Product is required.');
    ShowMessage('Product is required.');
    Abort;
  end;
  Line := Format('#%d %s - %d x %s, delivery %s', [FNextOrder, edtCustomer.Text,
    spnQuantity.Value, cbProduct.Text, FormatDateTime('yyyy-mm-dd', dtpDelivery.Date)]);
  if chkGiftWrap.Checked then
    Line := Line + ', gift wrap';
  if Trim(memNotes.Text) <> '' then
    Line := Line + ', notes: ' + Trim(memNotes.Text);
  lstOrders.Items.Add(Line);
  Inc(FNextOrder);
end;

procedure TfrmMain.OrderSubmitted(Sender: TObject; AgentInvoked: Boolean; var Response: string);
begin
  // Like SubmitEvent.respondWith(): this text goes back to the agent.
  Response := 'Saved: ' + lstOrders.Items[lstOrders.Count - 1];
  ClearOrder;
end;

procedure TfrmMain.btnClearClick(Sender: TObject);
begin
  ClearOrder;
end;

procedure TfrmMain.ClearOrder;
begin
  edtCustomer.Clear;
  cbProduct.ItemIndex := -1;
  spnQuantity.Value := 1;
  dtpDelivery.Date := Date + 7;
  chkGiftWrap.Checked := False;
  memNotes.Clear;
end;

procedure TfrmMain.AddLog(const Msg: string);
begin
  if memLog <> nil then
    memLog.Lines.Add(FormatDateTime('hh:nn:ss ', Now) + Msg);
end;

end.
