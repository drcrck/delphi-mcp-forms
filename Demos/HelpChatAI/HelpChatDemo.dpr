program HelpChatDemo;

{ The VCL order demo with HelpChatAI, the in-app assistant by Carlo Barazzetta
  (https://github.com/EtheaDev/Delphi-HelpChatAI, Apache 2.0). The bubble in
  the bottom right corner (or F1) opens it.

  It answers from the pages in Help\ and works through three skills:
  - forms, commands (HelpChatAI): read and fill the window on screen, press
    its buttons;
  - mcpforms (MCPForms.HelpChatAI): every form tool declared with
    delphi-mcp-forms - here create-order - with its whole JSON Schema, even
    when its window is not the one in front.
  Either way the assistant asks first and never saves: the user reviews the
  order and clicks Save.

  Set ANTHROPIC_API_KEY before starting it. Build it with build_helpchat.bat,
  which also copies WebView2Loader.dll and the Help folder next to it.

  HelpChatDemo.res must carry the manifest (HelpChatDemo.rc): the bubble is a
  layered child window, which Windows creates only for an application that
  declares Windows 8 or later. Without it the startup fails with EOSError
  1411 ("class does not exist") from TVclHelpChatAIBubble.CreateWnd. }

uses
  Vcl.Forms,
  MainForm in '..\VCL\MainForm.pas' {frmMain},
  HelpChatAI.Messages,        // hclEnglish
  HelpChatAI.Provider.Claude, // links the "claude" provider
  Vcl.HelpChatAI,
  MCPForms.HelpChatAI;        // registers the "mcpforms" skill

{$R *.res}

var
  HelpChat: TVclHelpChatAI;

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  frmMain.Caption := 'delphi-mcp-forms - HelpChatAI demo';

  HelpChat := TVclHelpChatAI.Create(frmMain);
  HelpChat.AssistantName := 'Order assistant';
  HelpChat.Settings.Provider := 'claude'; // key: the ANTHROPIC_API_KEY environment variable
  HelpChat.Settings.Language := hclEnglish;
  HelpChat.Settings.DocLanguage := hclEnglish;
  HelpChat.Settings.DocFolder := 'Help';  // relative to the executable
  HelpChat.Settings.DocIndexFile := 'Help\help-index.json';
  HelpChat.Settings.Expertise := 'order entry for a small shop selling coffee machines and accessories';
  HelpChat.Settings.Skills := 'forms, commands, ' + MCPFORMS_SKILL_NAME;
  HelpChat.Active := True;

  Application.Run;
end.
