program mcp_winmsg_bridge;

{ delphi-mcp-forms - stdio <-> WM_COPYDATA bridge.

  Lets any MCP client that starts stdio servers (Claude Desktop, Claude Code,
  the Python MCP SDK...) talk to a running Delphi app that uses
  TMCPWinMsgServer, without opening a network port.

    mcp_winmsg_bridge.exe --list
    mcp_winmsg_bridge.exe [--server NAME] [--pid N] [--verbose]

  stdin : newline-delimited JSON-RPC messages (MCP stdio transport)
  stdout: responses, one per line
  stderr: diagnostics

  The app may start after the bridge or restart: the server window is looked
  up again whenever it is gone.

  MIT License - see LICENSE. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.SyncObjs,
  System.Generics.Collections,
  MCPForms.WinMsg in '..\..\Source\MCPForms.WinMsg.pas';

var
  ServerName: string;
  ServerPid: Cardinal;
  Verbose: Boolean;
  Client: TMCPWinMsgClient;
  OutLock: TCriticalSection;
  PendingLock: TCriticalSection;
  Pending: TDictionary<NativeUInt, string>; // transport id -> JSON-RPC id (raw JSON)
  InputDone: Integer;

procedure LogErr(const Msg: string);
var
  Bytes: TBytes;
  Written: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes('[mcp-winmsg-bridge] ' + Msg + #10);
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), Bytes[0], Length(Bytes), Written, nil);
end;

procedure WriteOut(const Line: string);
var
  Bytes: TBytes;
  Written: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(Line + #10);
  OutLock.Enter;
  try
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), Bytes[0], Length(Bytes), Written, nil);
  finally
    OutLock.Leave;
  end;
  if Verbose then
    LogErr('<- ' + Line);
end;

procedure WriteError(const RawId: string; const Msg: string);
var
  Err: TJSONObject;
begin
  Err := TJSONObject.Create;
  try
    Err.AddPair('code', TJSONNumber.Create(-32000));
    Err.AddPair('message', Msg);
    WriteOut('{"jsonrpc":"2.0","id":' + RawId + ',"error":' + Err.ToJSON + '}');
  finally
    Err.Free;
  end;
end;

/// Raw JSON of the request id, '' for notifications and responses.
function RequestId(const Line: string): string;
var
  V, Id: TJSONValue;
begin
  Result := '';
  V := TJSONObject.ParseJSONValue(Line);
  try
    if (V is TJSONObject) and (TJSONObject(V).GetValue('method') <> nil) then
    begin
      Id := TJSONObject(V).GetValue('id');
      if Id <> nil then
        Result := Id.ToJSON;
    end;
  finally
    V.Free;
  end;
end;

function TargetDescription: string;
begin
  if ServerName <> '' then
    Result := 'application "' + ServerName + '"'
  else
    Result := 'any delphi-mcp-forms application';
  if ServerPid <> 0 then
    Result := Result + Format(' (pid %d)', [ServerPid]);
end;

procedure Forward(const Line: string);
var
  RawId: string;
  Id: NativeUInt;
  Server: HWND;
begin
  if Verbose then
    LogErr('-> ' + Line);
  RawId := RequestId(Line);

  Server := Client.Server;
  if not IsWindow(Server) then
  begin
    Server := TMCPWinMsgClient.FindServer(ServerName, ServerPid);
    Client.Server := Server;
    if Server <> 0 then
      LogErr(Format('connected to window %d', [Server]));
  end;
  if Server = 0 then
  begin
    if RawId <> '' then
      WriteError(RawId, 'Cannot reach ' + TargetDescription + ': start it and try again.');
    Exit;
  end;

  Id := TMCPWinMsgClient.NewId;
  if RawId <> '' then
  begin
    PendingLock.Enter;
    try
      Pending.Add(Id, RawId);
    finally
      PendingLock.Leave;
    end;
  end;
  try
    Client.Post(Line, Id);
  except
    on E: Exception do
    begin
      PendingLock.Enter;
      try
        Pending.Remove(Id);
      finally
        PendingLock.Leave;
      end;
      if RawId <> '' then
        WriteError(RawId, E.Message);
    end;
  end;
end;

procedure OnReply(Id: NativeUInt; const Reply: string);
begin
  PendingLock.Enter;
  try
    Pending.Remove(Id);
  finally
    PendingLock.Leave;
  end;
  if Reply <> '' then
    WriteOut(Reply);
end;

procedure FailPending(const Msg: string);
var
  Items: TArray<TPair<NativeUInt, string>>;
  P: TPair<NativeUInt, string>;
begin
  PendingLock.Enter;
  try
    Items := Pending.ToArray;
    Pending.Clear;
  finally
    PendingLock.Leave;
  end;
  for P in Items do
    WriteError(P.Value, Msg);
end;

/// Reads stdin on a worker thread; each complete line is forwarded.
procedure ReadInput;
var
  Input: THandle;
  Buf: array[0..65535] of Byte;
  Got: DWORD;
  Acc: TBytes;
  I, Start, Len: Integer;
  Line: string;
begin
  Input := GetStdHandle(STD_INPUT_HANDLE);
  Acc := nil;
  while ReadFile(Input, Buf, SizeOf(Buf), Got, nil) and (Got > 0) do
  begin
    Len := Length(Acc);
    SetLength(Acc, Len + Integer(Got));
    Move(Buf[0], Acc[Len], Got);
    Start := 0;
    for I := 0 to High(Acc) do
      if Acc[I] = 10 then
      begin
        Line := Trim(TEncoding.UTF8.GetString(Acc, Start, I - Start));
        if Line <> '' then
          Forward(Line);
        Start := I + 1;
      end;
    Acc := Copy(Acc, Start, MaxInt);
  end;
  Line := Trim(TEncoding.UTF8.GetString(Acc));
  if Line <> '' then
    Forward(Line);
  TInterlocked.Exchange(InputDone, 1);
end;

procedure ListServers;
var
  S: TMCPServerInfo;
  Any: Boolean;
begin
  Any := False;
  for S in TMCPWinMsgClient.ListServers do
  begin
    Writeln(Format('%-40s pid %-8d window %d', [S.Name, S.ProcessId, S.Handle]));
    Any := True;
  end;
  if not Any then
    Writeln('No delphi-mcp-forms application is running.');
end;

procedure ParseArgs;
var
  I: Integer;
  A: string;
begin
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if SameText(A, '--list') then
    begin
      ListServers;
      Halt(0);
    end
    else if SameText(A, '--server') and (I < ParamCount) then
    begin
      Inc(I);
      ServerName := ParamStr(I);
    end
    else if SameText(A, '--pid') and (I < ParamCount) then
    begin
      Inc(I);
      ServerPid := StrToIntDef(ParamStr(I), 0);
    end
    else if SameText(A, '--verbose') then
      Verbose := True
    else
    begin
      Writeln(ErrOutput, 'Usage: mcp_winmsg_bridge [--list] [--server NAME] [--pid N] [--verbose]');
      Halt(2);
    end;
    Inc(I);
  end;
end;

var
  Reader: TThread;
  WasConnected: Boolean;

begin
  ParseArgs;
  OutLock := TCriticalSection.Create;
  PendingLock := TCriticalSection.Create;
  Pending := TDictionary<NativeUInt, string>.Create;
  // The reply window lives on the main thread, which only dispatches replies.
  Client := TMCPWinMsgClient.Create(TMCPWinMsgClient.FindServer(ServerName, ServerPid));
  Client.OnReply := OnReply;
  if Client.Server = 0 then
    LogErr('waiting for ' + TargetDescription)
  else
    LogErr(Format('connected to window %d', [Client.Server]));

  Reader := TThread.CreateAnonymousThread(ReadInput);
  Reader.FreeOnTerminate := False;
  Reader.Start;

  WasConnected := Client.Server <> 0;
  while TInterlocked.CompareExchange(InputDone, 0, 0) = 0 do
  begin
    Client.ProcessReplies(250);
    if IsWindow(Client.Server) then
      WasConnected := True
    else if WasConnected then
    begin
      WasConnected := False;
      LogErr('the application closed');
      FailPending('The application closed before replying.');
    end;
  end;

  // stdin closed: the client is shutting us down
  Reader.WaitFor;
  Reader.Free;
  Client.Free;
  Pending.Free;
  PendingLock.Free;
  OutLock.Free;
end.
