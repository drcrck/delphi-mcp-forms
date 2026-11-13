unit MCPForms.Transport.HTTP;

{ delphi-mcp-forms - MCP "Streamable HTTP" transport on localhost (Indy).

  POST /mcp with one JSON-RPC message -> application/json response,
  or 202 Accepted for notifications. GET (server-initiated SSE stream) is not
  offered in this version, so the client is told listChanged = false.

  Binds to 127.0.0.1 only, rejects browser requests from foreign origins
  (DNS rebinding) and can require a bearer token.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes,
  IdContext, IdCustomHTTPServer, IdHTTPServer,
  MCPForms.Core;

type
  TMCPHttpServer = class
  private
    FServer: TIdHTTPServer;
    FContext: TModelContext;
    FPort: Word;
    FPath: string;
    FToken: string;
    FStopping: Boolean;
    procedure HandleRequest(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    function OriginAllowed(const Origin: string): Boolean;
    function GetActive: Boolean;
    procedure SendText(AResponseInfo: TIdHTTPResponseInfo; Code: Integer;
      const ContentType, Text: string);
  public
    constructor Create(APort: Word = 8765; AContext: TModelContext = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function Url: string;
    property Active: Boolean read GetActive;
    property Port: Word read FPort write FPort;
    /// Endpoint path, default '/mcp'.
    property Path: string read FPath write FPath;
    /// When set, clients must send "Authorization: Bearer <Token>".
    property Token: string read FToken write FToken;
  end;

implementation

uses
  IdGlobal;

constructor TMCPHttpServer.Create(APort: Word; AContext: TModelContext);
begin
  inherited Create;
  FPort := APort;
  FPath := '/mcp';
  FContext := AContext;
  if FContext = nil then
    FContext := ModelContext;
  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := HandleRequest;
  FServer.OnCommandOther := HandleRequest;
  FServer.KeepAlive := True;
  FServer.ParseParams := False;
end;

destructor TMCPHttpServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited;
end;

procedure TMCPHttpServer.Start;
begin
  if FServer.Active then
    Exit;
  FStopping := False;
  FServer.Bindings.Clear;
  with FServer.Bindings.Add do
  begin
    IP := '127.0.0.1';
    Port := FPort;
  end;
  FServer.DefaultPort := FPort;
  FServer.Active := True;
  FContext.Log('MCP server listening on ' + Url);
end;

procedure TMCPHttpServer.Stop;
begin
  if not FServer.Active then
    Exit;
  FStopping := True;
  // Release worker threads waiting on the main thread before Indy joins them.
  FContext.CancelPending('The MCP server is stopping.');
  FServer.Active := False;
end;

function TMCPHttpServer.GetActive: Boolean;
begin
  Result := FServer.Active;
end;

function TMCPHttpServer.Url: string;
begin
  Result := Format('http://127.0.0.1:%d%s', [FPort, FPath]);
end;

function TMCPHttpServer.OriginAllowed(const Origin: string): Boolean;
var
  Host: string;
  P: Integer;
begin
  // Origin looks like "http://localhost:3000"
  Host := LowerCase(Origin);
  P := Pos('://', Host);
  if P = 0 then
    Exit(False);
  Delete(Host, 1, P + 2);
  if (Host <> '') and (Host[1] = '[') then
  begin
    P := Pos(']', Host);
    Host := Copy(Host, 1, P);
  end
  else
  begin
    P := Pos(':', Host);
    if P > 0 then
      Host := Copy(Host, 1, P - 1);
    P := Pos('/', Host);
    if P > 0 then
      Host := Copy(Host, 1, P - 1);
  end;
  Result := (Host = 'localhost') or (Host = '127.0.0.1') or (Host = '[::1]');
end;

procedure TMCPHttpServer.SendText(AResponseInfo: TIdHTTPResponseInfo; Code: Integer;
  const ContentType, Text: string);
begin
  AResponseInfo.ResponseNo := Code;
  AResponseInfo.ContentType := ContentType;
  AResponseInfo.CharSet := 'utf-8';
  AResponseInfo.ContentStream := TStringStream.Create(Text, TEncoding.UTF8);
  AResponseInfo.FreeContentStream := True;
end;

procedure TMCPHttpServer.HandleRequest(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Doc, Origin, Body, Reply: string;
  Bytes: TBytes;
begin
  Doc := ARequestInfo.Document;
  if (Doc <> FPath) and (Doc <> FPath + '/') then
  begin
    SendText(AResponseInfo, 404, 'text/plain', 'Not found');
    Exit;
  end;

  Origin := ARequestInfo.RawHeaders.Values['Origin'];
  if (Origin <> '') and not OriginAllowed(Origin) then
  begin
    SendText(AResponseInfo, 403, 'text/plain', 'Origin not allowed');
    Exit;
  end;

  if (FToken <> '') and
     (ARequestInfo.RawHeaders.Values['Authorization'] <> 'Bearer ' + FToken) then
  begin
    AResponseInfo.CustomHeaders.Values['WWW-Authenticate'] := 'Bearer';
    SendText(AResponseInfo, 401, 'text/plain', 'Unauthorized');
    Exit;
  end;

  if FStopping then
  begin
    SendText(AResponseInfo, 503, 'text/plain', 'Server stopping');
    Exit;
  end;

  if ARequestInfo.CommandType <> hcPOST then
  begin
    AResponseInfo.CustomHeaders.Values['Allow'] := 'POST';
    SendText(AResponseInfo, 405, 'text/plain', 'Method not allowed');
    Exit;
  end;

  Body := '';
  if (ARequestInfo.PostStream <> nil) and (ARequestInfo.PostStream.Size > 0) then
  begin
    SetLength(Bytes, ARequestInfo.PostStream.Size);
    ARequestInfo.PostStream.Position := 0;
    ARequestInfo.PostStream.ReadBuffer(Bytes[0], Length(Bytes));
    Body := TEncoding.UTF8.GetString(Bytes);
  end;

  Reply := FContext.HandleMessage(Body);
  if Reply = '' then
  begin
    AResponseInfo.ResponseNo := 202;
    AResponseInfo.ContentText := '';
  end
  else
    SendText(AResponseInfo, 200, 'application/json', Reply);
end;

end.
