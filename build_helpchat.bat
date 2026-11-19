@echo off
setlocal
cd /d "%~dp0"
rem Builds the HelpChatAI demo (Demos\HelpChatAI). Separate from build.bat,
rem which needs nothing but Delphi.
rem   HELPCHATAI  the Delphi-HelpChatAI repository
rem               (https://github.com/EtheaDev/Delphi-HelpChatAI)
rem   MARKDOWN    the MarkdownProcessor repository or its source folder
rem               (https://github.com/EtheaDev/MarkdownProcessor); default
rem               %HELPCHATAI%\Ext\MarkdownProcessor, where the installer puts it
rem   DELPHI      default C:\Program Files (x86)\Embarcadero\Studio\37.0 (Delphi 13)
if "%DELPHI%"=="" set "DELPHI=C:\Program Files (x86)\Embarcadero\Studio\37.0"
if "%HELPCHATAI%"=="" (
  echo Set HELPCHATAI to the Delphi-HelpChatAI repository.
  exit /b 1
)
if not exist "%HELPCHATAI%\source\Vcl.HelpChatAI.pas" (
  echo HELPCHATAI=%HELPCHATAI% is not the Delphi-HelpChatAI repository.
  exit /b 1
)
if "%MARKDOWN%"=="" set "MARKDOWN=%HELPCHATAI%\Ext\MarkdownProcessor"
set "MDSRC=%MARKDOWN%"
if exist "%MARKDOWN%\source\MarkdownProcessor.pas" set "MDSRC=%MARKDOWN%\source"
if not exist "%MDSRC%\MarkdownProcessor.pas" (
  echo Set MARKDOWN to the MarkdownProcessor repository or its source folder.
  exit /b 1
)
set DCC="%DELPHI%\bin\dcc32.exe"
set "HCSRC=%HELPCHATAI%\source"
set "NS=System;Vcl;Winapi;System.Win;Data;Vcl.Imaging"
if not exist bin\Help mkdir bin\Help
if not exist dcu\helpchat mkdir dcu\helpchat

pushd Demos\HelpChatAI
"%DELPHI%\bin\brcc32.exe" -fo HelpChatDemo.res HelpChatDemo.rc >nul || goto :fail
%DCC% -B -Q -NS%NS% -U"..\..\Source;%HCSRC%;%MDSRC%" -I"..\VCL;%HCSRC%" -R"%HCSRC%" -E..\..\bin -N0..\..\dcu\helpchat HelpChatDemo.dpr || goto :fail
popd

rem The documentation index the assistant searches, built from Help\*.md
pushd "%HELPCHATAI%\Tools\HelpIndexBuilder"
%DCC% -B -Q -NS%NS% -U"%HCSRC%;%MDSRC%" -I"%HCSRC%" -E"%~dp0dcu\helpchat" -N0"%~dp0dcu\helpchat" HelpIndexBuilder.dpr || goto :fail
popd
copy /y Demos\HelpChatAI\Help\*.md bin\Help\ >nul || goto :failnopop
dcu\helpchat\HelpIndexBuilder.exe --source=bin\Help --out=bin\Help\help-index.json --toc=Index.md --url-ext= --quiet || goto :failnopop

rem The chat panel is WebView2: its loader goes next to the executable
copy /y "%HELPCHATAI%\Redist\WebView2\x86\WebView2Loader.dll" bin\ >nul || goto :failnopop

echo Done: bin\HelpChatDemo.exe, with bin\Help and bin\WebView2Loader.dll
exit /b 0

:fail
popd
:failnopop
echo Build failed.
exit /b 1
