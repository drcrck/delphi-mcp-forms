program VCLDemo;

uses
  Vcl.Forms,
  MainForm in 'MainForm.pas' {frmMain};

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
