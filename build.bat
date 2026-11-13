@echo off
cd /d "%~dp0"
rem Builds both demos with the command-line compiler.
rem Set DELPHI to your installation if it is not Delphi 13 (Studio\37.0).
if "%DELPHI%"=="" set DELPHI=C:\Program Files (x86)\Embarcadero\Studio\37.0
set DCC="%DELPHI%\bin\dcc32.exe"
if not exist bin mkdir bin
if not exist dcu\vcl mkdir dcu\vcl
if not exist dcu\fmx mkdir dcu\fmx

pushd Demos\VCL
%DCC% -B -Q -NSSystem;Vcl;Winapi;System.Win -U..\..\Source -E..\..\bin -N0..\..\dcu\vcl VCLDemo.dpr || goto :fail
popd
pushd Demos\FMX
%DCC% -B -Q -NSSystem;FMX;Winapi;System.Win -U..\..\Source -E..\..\bin -N0..\..\dcu\fmx FMXDemo.dpr || goto :fail
popd
pushd Tools\WinMsgBridge
%DCC% -B -Q -NSSystem;Winapi -U..\..\Source -E..\..\bin -N0..\..\dcu\vcl mcp_winmsg_bridge.dpr || goto :fail
popd
echo Done: bin\VCLDemo.exe, bin\FMXDemo.exe, bin\mcp_winmsg_bridge.exe
exit /b 0

:fail
popd
echo Build failed.
exit /b 1
