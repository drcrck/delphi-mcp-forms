program AssistantDemo;

{ The VCL order demo with the in-app assistant: a TMCPChatPanel on the right.
  The assistant is Claude, and it uses the same MCP tools and form resources
  an external client gets - it reads the order box and fills it, and the user
  saves it. Set ANTHROPIC_API_KEY before starting it.

  Copy WebView2Loader.dll (Microsoft.Web.WebView2 package, x86) next to the
  executable for the rendered conversation; without it the panel shows plain
  text. }

uses
  Vcl.Forms,
  Vcl.Controls,
  MainForm in '..\VCL\MainForm.pas' {frmMain},
  MCPForms.ChatPanel;

{$R *.res}

var
  Panel: TMCPChatPanel;

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  frmMain.Caption := 'delphi-mcp-forms - assistant demo';
  frmMain.Width := frmMain.Width + 400;
  Panel := TMCPChatPanel.Create(frmMain);
  Panel.Width := 400;
  Panel.Align := alRight;
  Panel.Parent := frmMain;
  Panel.Chat.SystemPrompt :=
    'The application takes sales orders. Saving needs a customer and a product.';
  Application.Run;
end.
