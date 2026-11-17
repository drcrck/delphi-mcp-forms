unit MCPForms.WinMsg;

{ delphi-mcp-forms - WM_COPYDATA transport: shared definitions and the client.

  Wire format
    Request  client -> server: WM_COPYDATA, wParam = client reply window,
             dwData = request id (non-zero), lpData = one JSON-RPC message (UTF-8).
             The server answers 1 (accepted) or 0 (rejected) at once.
    Reply    server -> client: WM_COPYDATA to the reply window, wParam = server
             window, same dwData, lpData = the JSON-RPC response (UTF-8).
             Empty data means "no response" (the request was a notification).
    Notify   server -> client: WM_COPYDATA to a reply window that has sent
             requests, dwData = 0 (MCPWinMsgNotifyId), lpData = a JSON-RPC
             notification (tools/list_changed, resources/updated...).

  Replies are asynchronous because a tool call can wait minutes for the user;
  several requests can be in flight at once.

  Servers are message-only windows of class MCPWinMsgServerClass titled
  'MCPForms:<server name>'. This unit has no dependency on MCPForms.Core, so a
  client application only needs this file.

  MIT License - see LICENSE. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes;

const
  MCPWinMsgServerClass = 'MCPFormsServerWindow';
  MCPWinMsgClientClass = 'MCPFormsClientWindow';
  MCPWinMsgTitlePrefix = 'MCPForms:';
  MCPWinMsgMaxSize = 16 * 1024 * 1024;
  /// dwData of a message the server sends on its own (a notification).
  MCPWinMsgNotifyId = 0;

type
  EMCPWinMsgError = class(Exception);

  TMCPServerInfo = record
    Handle: HWND;
    ProcessId: Cardinal;
    Name: string;
  end;

  /// Called on the client's thread while it processes messages.
  TMCPReplyProc = reference to procedure(Id: NativeUInt; const Reply: string);
  /// A notification from the server. Same thread as TMCPReplyProc.
  TMCPNotificationProc = reference to procedure(const Notification: string);

  TMCPWinMsgClient = class
  private
    FWnd: HWND;
    FServer: HWND;
    FOnReply: TMCPReplyProc;
    FOnNotification: TMCPNotificationProc;
    FWaitId: NativeUInt;
    FWaitReply: string;
    FWaitDone: Boolean;
    procedure HandleReply(Sender: HWND; Id: NativeUInt; const Text: string);
  public
    /// Creates the reply window on the calling thread: replies are delivered
    /// only while that thread runs a message loop, Send or ProcessReplies.
    constructor Create(AServer: HWND = 0);
    destructor Destroy; override;

    class function NewId: NativeUInt;
    /// Sends a request and returns at once with its id; the reply comes via
    /// OnReply. Thread-safe. Raises EMCPWinMsgError if the server is gone.
    function Post(const RequestJSON: string; Id: NativeUInt = 0): NativeUInt;
    /// Sends a request and waits for the reply ('' for notifications).
    /// Call it from the thread that created the client.
    function Send(const RequestJSON: string; TimeoutMs: Cardinal = 600000): string;
    /// Waits up to TimeoutMs for incoming replies and dispatches them.
    procedure ProcessReplies(TimeoutMs: Cardinal);

    /// Running servers, in window Z-order.
    class function ListServers: TArray<TMCPServerInfo>;
    /// First server matching Name (case-insensitive) and/or ProcessId; 0 if none.
    class function FindServer(const Name: string = ''; ProcessId: Cardinal = 0): HWND;

    property Server: HWND read FServer write FServer;
    property Handle: HWND read FWnd;
    property OnReply: TMCPReplyProc read FOnReply write FOnReply;
    /// Server notifications. When not assigned they go to OnReply with Id 0.
    property OnNotification: TMCPNotificationProc read FOnNotification write FOnNotification;
  end;

{ Helpers shared with MCPForms.Transport.WinMsg }

/// Creates a message-only window whose GWLP_USERDATA is Instance.
function MCPCreateMessageWindow(const ClassName, Title: string; WndProc: TFNWndProc;
  Instance: Pointer): HWND;
/// Sends Text as UTF-8 WM_COPYDATA. False if the target is gone, hung or refused.
function MCPSendCopyData(Target, Sender: HWND; Id: NativeUInt; const Text: string;
  TimeoutMs: Cardinal = 10000): Boolean;
function MCPReadCopyData(Data: PCopyDataStruct): string;

implementation

uses
  System.SyncObjs;

const
  PM_QS_SENDMESSAGE = QS_SENDMESSAGE shl 16;

var
  GNextId: Int64 = 0;

function MCPCreateMessageWindow(const ClassName, Title: string; WndProc: TFNWndProc;
  Instance: Pointer): HWND;
var
  WC: TWndClassEx;
begin
  if not GetClassInfoEx(HInstance, PChar(ClassName), WC) then
  begin
    FillChar(WC, SizeOf(WC), 0);
    WC.cbSize := SizeOf(WC);
    WC.lpfnWndProc := WndProc;
    WC.hInstance := HInstance;
    WC.lpszClassName := PChar(ClassName);
    if RegisterClassEx(WC) = 0 then
      RaiseLastOSError;
  end;
  Result := CreateWindowEx(0, PChar(ClassName), PChar(Title), 0, 0, 0, 0, 0,
    HWND_MESSAGE, 0, HInstance, nil);
  if Result = 0 then
    RaiseLastOSError;
  SetWindowLongPtr(Result, GWLP_USERDATA, LONG_PTR(Instance));
end;

function MCPSendCopyData(Target, Sender: HWND; Id: NativeUInt; const Text: string;
  TimeoutMs: Cardinal): Boolean;
var
  Bytes: TBytes;
  CDS: TCopyDataStruct;
  Answer: DWORD_PTR;
begin
  if not IsWindow(Target) then
    Exit(False);
  Bytes := TEncoding.UTF8.GetBytes(Text);
  CDS.dwData := Id;
  CDS.cbData := Length(Bytes);
  if Length(Bytes) > 0 then
    CDS.lpData := @Bytes[0]
  else
    CDS.lpData := nil;
  Answer := 0;
  Result := (SendMessageTimeout(Target, WM_COPYDATA, WPARAM(Sender), LPARAM(@CDS),
    SMTO_ABORTIFHUNG or SMTO_BLOCK, TimeoutMs, @Answer) <> 0) and (Answer = 1);
end;

function MCPReadCopyData(Data: PCopyDataStruct): string;
var
  Bytes: TBytes;
begin
  if (Data = nil) or (Data.cbData = 0) or (Data.lpData = nil) then
    Exit('');
  // lpData is raw memory, not a dynamic array: copy it first
  SetLength(Bytes, Data.cbData);
  Move(Data.lpData^, Bytes[0], Data.cbData);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

{ Client window }

function ClientWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Client: TMCPWinMsgClient;
  Data: PCopyDataStruct;
begin
  if Msg = WM_COPYDATA then
  begin
    Client := TMCPWinMsgClient(GetWindowLongPtr(Wnd, GWLP_USERDATA));
    Data := PCopyDataStruct(lParam);
    if (Client = nil) or (Data = nil) or (Data.cbData > MCPWinMsgMaxSize) then
      Exit(0);
    try
      Client.HandleReply(HWND(wParam), Data.dwData, MCPReadCopyData(Data));
    except
      // never let an exception escape a window procedure
      Exit(0);
    end;
    Exit(1);
  end;
  Result := DefWindowProc(Wnd, Msg, wParam, lParam);
end;

{ TMCPWinMsgClient }

constructor TMCPWinMsgClient.Create(AServer: HWND);
begin
  inherited Create;
  FServer := AServer;
  FWnd := MCPCreateMessageWindow(MCPWinMsgClientClass, '', @ClientWndProc, Self);
end;

destructor TMCPWinMsgClient.Destroy;
begin
  if FWnd <> 0 then
  begin
    SetWindowLongPtr(FWnd, GWLP_USERDATA, 0);
    DestroyWindow(FWnd);
  end;
  inherited;
end;

class function TMCPWinMsgClient.NewId: NativeUInt;
begin
  Result := NativeUInt(TInterlocked.Increment(GNextId));
end;

procedure TMCPWinMsgClient.HandleReply(Sender: HWND; Id: NativeUInt; const Text: string);
begin
  // only our server may answer
  if (FServer <> 0) and (Sender <> FServer) then
    Exit;
  if (Id = MCPWinMsgNotifyId) and Assigned(FOnNotification) then
    FOnNotification(Text)
  else if (FWaitId <> 0) and (Id = FWaitId) then
  begin
    FWaitReply := Text;
    FWaitDone := True;
  end
  else if Assigned(FOnReply) then
    FOnReply(Id, Text);
end;

function TMCPWinMsgClient.Post(const RequestJSON: string; Id: NativeUInt): NativeUInt;
begin
  if Id = 0 then
    Id := NewId;
  if not IsWindow(FServer) then
    raise EMCPWinMsgError.Create('The application is not running.');
  if not MCPSendCopyData(FServer, FWnd, Id, RequestJSON) then
    raise EMCPWinMsgError.Create('The application did not accept the request.');
  Result := Id;
end;

procedure TMCPWinMsgClient.ProcessReplies(TimeoutMs: Cardinal);
var
  Dummy: THandle;
  Msg: TMsg;
begin
  Dummy := 0;
  // Sent messages (WM_COPYDATA from another process) are dispatched by
  // PeekMessage; posted messages of the application stay in the queue.
  MsgWaitForMultipleObjects(0, Dummy, False, TimeoutMs, QS_SENDMESSAGE);
  PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE);
end;

function TMCPWinMsgClient.Send(const RequestJSON: string; TimeoutMs: Cardinal): string;
var
  Start, Elapsed: UInt64;
begin
  FWaitId := NewId;
  FWaitDone := False;
  FWaitReply := '';
  try
    Post(RequestJSON, FWaitId);
    Start := GetTickCount64;
    while not FWaitDone do
    begin
      Elapsed := GetTickCount64 - Start;
      if Elapsed >= TimeoutMs then
        raise EMCPWinMsgError.Create('Timed out waiting for the application.');
      if not IsWindow(FServer) then
        raise EMCPWinMsgError.Create('The application closed before replying.');
      ProcessReplies(250);
    end;
    Result := FWaitReply;
  finally
    FWaitId := 0;
  end;
end;

class function TMCPWinMsgClient.ListServers: TArray<TMCPServerInfo>;
var
  Wnd: HWND;
  Info: TMCPServerInfo;
  Buf: array[0..255] of Char;
  Title: string;
begin
  Result := nil;
  Wnd := 0;
  repeat
    Wnd := FindWindowEx(HWND_MESSAGE, Wnd, MCPWinMsgServerClass, nil);
    if Wnd = 0 then
      Break;
    SetString(Title, Buf, GetWindowText(Wnd, Buf, Length(Buf)));
    Info.Handle := Wnd;
    Info.Name := Title;
    if Title.StartsWith(MCPWinMsgTitlePrefix) then
      Info.Name := Copy(Title, Length(MCPWinMsgTitlePrefix) + 1, MaxInt);
    GetWindowThreadProcessId(Wnd, @Info.ProcessId);
    Result := Result + [Info];
  until False;
end;

class function TMCPWinMsgClient.FindServer(const Name: string; ProcessId: Cardinal): HWND;
var
  S: TMCPServerInfo;
begin
  for S in ListServers do
    if ((Name = '') or SameText(S.Name, Name)) and
       ((ProcessId = 0) or (S.ProcessId = ProcessId)) then
      Exit(S.Handle);
  Result := 0;
end;

end.
