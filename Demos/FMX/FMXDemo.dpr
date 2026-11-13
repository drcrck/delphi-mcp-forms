program FMXDemo;

uses
  System.StartUpCopy,
  FMX.Forms,
  MainFormFMX in 'MainFormFMX.pas' {FormMain};

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.
