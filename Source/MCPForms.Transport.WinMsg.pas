unit MCPForms.Transport.WinMsg;

{ delphi-mcp-forms - WM_COPYDATA transport, server side (Windows only).

  Creates a message-only window 'MCPForms:<ModelContext.ServerName>' that
  receives JSON-RPC requests (see MCPForms.WinMsg for the wire format).
  Each request runs on its own worker thread, so tools that wait for the user
  never block the main thread; the response goes back as WM_COPYDATA.

  No network port is opened. Standard MCP clients reach it through
  mcp-winmsg-bridge.exe (stdio <-> WM_COPYDATA).

  Create, Start and Stop it on the main thread.

  MIT License - see LICENSE. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.SyncObjs,
  MCPForms.Core, MCPForms.WinMsg;

type
  TMCPWinMsgServer = class
  private
    FContext: TModelContext;
    FWnd: HWND;
    FName: string;
    FWorkers: IInterface; // shared counter, outlives the server if needed
    FStopping: Boolean;
    function HandleCopyData(Sender: HWND; Data: PCopyDataStruct): Boolean;
  public
    constructor Create(AContext: TModelContext = nil);
    destructor Destroy; override;
    procedure Start;
    /// Cancels pending calls and waits (pumping the main thread) for running ones.
    procedure Stop;
    function Active: Boolean;
    property Handle: HWND read FWnd;
    /// Window name; defaults to ModelContext.ServerName at Start.
    property Name: string read FName write FName;
  end;

implementation

type
  IWorkerCount = interface
    ['{0E2D8C34-7B1A-4F5E-A9C6-3D4B5E6F7081}']
    procedure Enter;
    procedure Leave;
    function Value: Integer;
  end;

  TWorkerCount = class(TInterfacedObject, IWorkerCount)
  private
    FCount: Integer;
  public
    procedure Enter;
    procedure Leave;
    function Value: Integer;
  end;

procedure TWorkerCount.Enter;
begin
  TInterlocked.Increment(FCount);
end;

procedure TWorkerCount.Leave;
begin
  TInterlocked.Decrement(FCount);
end;

function TWorkerCount.Value: Integer;
begin
  Result := TInterlocked.CompareExchange(FCount, 0, 0);
end;

function ServerWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Server: TMCPWinMsgServer;
begin
  if Msg = WM_COPYDATA then
  begin
    Server := TMCPWinMsgServer(GetWindowLongPtr(Wnd, GWLP_USERDATA));
    try
      if (Server <> nil) and Server.HandleCopyData(HWND(wParam), PCopyDataStruct(lParam)) then
        Exit(1);
    except
      // never let an exception escape a window procedure called by another process
    end;
    Exit(0);
  end;
  Result := DefWindowProc(Wnd, Msg, wParam, lParam);
end;

{ TMCPWinMsgServer }

constructor TMCPWinMsgServer.Create(AContext: TModelContext);
begin
  inherited Create;
  FContext := AContext;
  if FContext = nil then
    FContext := ModelContext;
  FWorkers := TWorkerCount.Create;
end;

destructor TMCPWinMsgServer.Destroy;
begin
  Stop;
  inherited;
end;

function TMCPWinMsgServer.Active: Boolean;
begin
  Result := FWnd <> 0;
end;

procedure TMCPWinMsgServer.Start;
begin
  if FWnd <> 0 then
    Exit;
  if FName = '' then
    FName := FContext.ServerName;
  FStopping := False;
  FWnd := MCPCreateMessageWindow(MCPWinMsgServerClass, MCPWinMsgTitlePrefix + FName,
    @ServerWndProc, Self);
  FContext.Log(Format('MCP WM_COPYDATA server "%s" ready (window %d)', [FName, FWnd]));
end;

procedure TMCPWinMsgServer.Stop;
var
  Deadline: UInt64;
begin
  if FWnd = 0 then
    Exit;
  FStopping := True;
  SetWindowLongPtr(FWnd, GWLP_USERDATA, 0);
  DestroyWindow(FWnd);
  FWnd := 0;
  // Running calls may wait on the main thread or on the user: release them,
  // and keep the main-thread queue moving until they are done.
  Deadline := GetTickCount64 + 15000;
  while ((FWorkers as IWorkerCount).Value > 0) and (GetTickCount64 < Deadline) do
  begin
    FContext.CancelPending('The MCP server is stopping.');
    CheckSynchronize(10);
  end;
end;

function TMCPWinMsgServer.HandleCopyData(Sender: HWND; Data: PCopyDataStruct): Boolean;
var
  Request: string;
  Id: NativeUInt;
  ReplyFrom: HWND;
  Ctx: TModelContext;
  Workers: IWorkerCount;
begin
  Result := False;
  if FStopping or (Data = nil) or (Data.dwData = 0) or (Data.cbData = 0) or
     (Data.cbData > MCPWinMsgMaxSize) or not IsWindow(Sender) then
    Exit;
  Request := MCPReadCopyData(Data);
  Id := Data.dwData;
  ReplyFrom := FWnd;
  Ctx := FContext;
  Workers := FWorkers as IWorkerCount;
  Workers.Enter;
  // The worker never touches Self: the server may be freed while it runs.
  TThread.CreateAnonymousThread(
    procedure
    var
      Reply: string;
    begin
      try
        try
          Reply := Ctx.HandleMessage(Request);
        except
          on E: Exception do
            Reply := '';
        end;
        // always answer, even with '' (notification), so the client can forget the id
        MCPSendCopyData(Sender, ReplyFrom, Id, Reply, 10000);
      finally
        Workers.Leave;
      end;
    end).Start;
  Result := True;
end;

end.
