unit MCPForms.ChatPanel;

{ delphi-mcp-forms - the in-app assistant panel for VCL.

  Drop a TMCPChatPanel on a form (or create it and set Parent/Align): the user
  types a question, Claude answers, and it acts through the application's MCP
  tools - reading the screen, filling a form the user then saves. The
  conversation is shown in WebView2 (TEdgeBrowser), with the replies rendered
  from Markdown; when WebView2 is not available it falls back to plain text.

  The engine is the Chat property, a TMCPClaudeChat: set its Model, Effort,
  SystemPrompt there, and the API key in Chat.ApiKey or ANTHROPIC_API_KEY.

  WebView2 needs WebView2Loader.dll next to the executable (from the
  Microsoft.Web.WebView2 package) and the WebView2 runtime, which Windows 10
  and 11 include.

  MIT License - see LICENSE. }

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.Messages,
  Winapi.WebView2, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Edge,
  MCPForms.Claude;

type
  TMCPChatPanel = class(TCustomPanel)
  private
    FChat: TMCPClaudeChat;
    FBrowser: TEdgeBrowser;
    FPlain: TMemo;
    FBottom: TPanel;
    FInput: TMemo;
    FButton: TButton;
    FStarted: Boolean;
    FReady: Boolean;
    FFailed: Boolean;
    FQueue: TStringList;
    FToolSeq: Integer;
    FWelcome: string;
    procedure Run(const Fn: string; const Args: array of string);
    procedure Plain(const S: string);
    procedure PlainAppend(const S: string);
    procedure StartBrowser;
    procedure BrowserCreated(Sender: TCustomEdgeBrowser; AResult: HResult);
    procedure BrowserNavigated(Sender: TCustomEdgeBrowser; IsSuccess: Boolean;
      WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
    procedure UseFallback;
    procedure InputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ButtonClick(Sender: TObject);
    procedure ChatText(Sender: TObject; const Text: string);
    procedure ChatProgress(Sender: TObject; const Text: string);
    procedure ChatToolCall(Sender: TObject; const ToolName, ArgumentsJSON: string);
    procedure ChatToolResult(Sender: TObject; const ToolName, Result: string; IsError: Boolean);
    procedure ChatDone(Sender: TObject; const StopReason: string);
    procedure ChatError(Sender: TObject; const Text: string);
    procedure ChatBusy(Sender: TObject);
    procedure SetWelcome(const Value: string);
  protected
    procedure CreateWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// Sends a question as if the user typed it.
    procedure Ask(const Question: string);
    /// Clears the conversation and the panel.
    procedure Clear;
    property InputMemo: TMemo read FInput;
  published
    property Chat: TMCPClaudeChat read FChat;
    /// Shown before the first question.
    property WelcomeText: string read FWelcome write SetWelcome;
    property Align;
    property Anchors;
    property Constraints;
    property Visible;
    property Width;
    property Height;
  end;

implementation

uses
  System.JSON, System.IOUtils, Vcl.Forms, Vcl.Graphics,
  MCPForms.Screen;

const
  ChatPage = '''
    <!doctype html><html><head><meta charset="utf-8">
    <style>
    :root{--bg:#f6f7f9;--user:#dbeafe;--bot:#ffffff;--muted:#6b7280;--err:#b91c1c;--line:#e5e7eb}
    html,body{margin:0;background:var(--bg);font:13px/1.45 "Segoe UI",system-ui,sans-serif;color:#111827}
    #log{padding:10px 10px 16px}
    .msg{max-width:92%;margin:6px 0;padding:7px 10px;border-radius:10px;overflow-wrap:anywhere}
    .user{margin-left:auto;background:var(--user);white-space:pre-wrap;width:fit-content}
    .bot{background:var(--bot);border:1px solid var(--line)}
    .note{color:var(--muted);font-style:italic;font-size:12px;margin:2px 0 4px}
    .tool{display:inline-block;font-size:12px;margin:2px 4px 4px 0;padding:1px 8px;border-radius:999px;
      border:1px solid var(--line);background:#f3f4f6;color:#374151}
    .tool.ok{border-color:#86efac;background:#f0fdf4}
    .tool.err{border-color:#fca5a5;background:#fef2f2}
    .tool.wait::after{content:" \2026"}
    .error{color:var(--err);font-size:12px;margin:6px 2px}
    .welcome{color:var(--muted);text-align:center;margin:28px 14px;white-space:pre-wrap}
    pre{background:#f3f4f6;padding:6px 8px;border-radius:6px;overflow-x:auto}
    code{font-family:Consolas,monospace;font-size:12px;background:#f3f4f6;padding:0 3px;border-radius:3px}
    pre code{background:none;padding:0}
    p{margin:0 0 6px} p:last-child{margin-bottom:0}
    ul,ol{margin:2px 0 6px 18px;padding:0}
    h1,h2,h3,h4{font-size:13px;margin:6px 0 4px}
    table{border-collapse:collapse;margin:4px 0} td,th{border:1px solid var(--line);padding:2px 6px;text-align:left}
    </style></head><body><div id="log"></div><script>
    var log=document.getElementById('log'),bot=null,botText=null,lastNote=null,raw='',tools={};
    function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
    function inline(s){s=esc(s);
      s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
      s=s.replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>');
      s=s.replace(/(^|[^*\w])\*([^*\s][^*]*)\*/g,'$1<i>$2</i>');
      s=s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,'$1 ($2)');
      return s;}
    function md(src){var out=[],lines=src.replace(/\r/g,'').split('\n'),i=0,list=null,para=[],m;
      function flush(){if(para.length){out.push('<p>'+para.map(inline).join('<br>')+'</p>');para=[];}}
      function close(){if(list){out.push('</'+list+'>');list=null;}}
      while(i<lines.length){var l=lines[i];
        if(/^```/.test(l)){flush();close();var code=[];i++;
          while(i<lines.length&&!/^```/.test(lines[i])){code.push(lines[i]);i++;}
          i++;out.push('<pre><code>'+esc(code.join('\n'))+'</code></pre>');continue;}
        if(m=/^(#{1,4})\s+(.*)$/.exec(l)){flush();close();var n=m[1].length;
          out.push('<h'+n+'>'+inline(m[2])+'</h'+n+'>');i++;continue;}
        if(/^\|.*\|\s*$/.test(l)){flush();close();var html='<table>',first=true;
          while(i<lines.length&&/^\|.*\|\s*$/.test(lines[i])){var r=lines[i].trim();i++;
            if(/^\|[\s:|-]+\|$/.test(r))continue;var t=first?'th':'td';first=false;
            html+='<tr>'+r.slice(1,-1).split('|').map(function(c){return '<'+t+'>'+inline(c.trim())+'</'+t+'>';}).join('')+'</tr>';}
          out.push(html+'</table>');continue;}
        if(m=/^\s*([-*]|\d+\.)\s+(.*)$/.exec(l)){flush();var k=/\d/.test(m[1])?'ol':'ul';
          if(list!==k){close();out.push('<'+k+'>');list=k;}
          out.push('<li>'+inline(m[2])+'</li>');i++;continue;}
        if(/^\s*$/.test(l)){flush();close();i++;continue;}
        close();para.push(l);i++;}
      flush();close();return out.join('');}
    function bottom(){window.scrollTo(0,document.body.scrollHeight);}
    function add(cls,html){var d=document.createElement('div');d.className=cls;d.innerHTML=html;log.appendChild(d);bottom();return d;}
    function welcome(t){log.innerHTML='';bot=null;add('welcome',esc(t));}
    function user(t){var w=log.querySelector('.welcome');if(w)w.remove();add('msg user',esc(t));}
    function ensureBot(){if(!bot){bot=add('msg bot','');botText=null;lastNote=null;raw='';}}
    function text(t){ensureBot();lastNote=null;
      if(!botText){botText=document.createElement('div');bot.appendChild(botText);raw='';}
      raw+=t;botText.innerHTML=md(raw);bottom();}
    function note(t){ensureBot();botText=null;
      if(!lastNote){lastNote=document.createElement('div');lastNote.className='note';bot.appendChild(lastNote);}
      lastNote.textContent+=t;bottom();}
    function tool(id,label,detail){ensureBot();botText=null;lastNote=null;
      var d=document.createElement('span');d.className='tool wait';d.textContent=label;d.title=detail;
      bot.appendChild(d);tools[id]=d;bottom();}
    function toolDone(id,ok,detail){var d=tools[id];if(!d)return;d.className='tool '+(ok?'ok':'err');d.title=detail;}
    function error(t){done();add('error',esc(t));}
    function done(){if(bot&&!bot.childNodes.length)bot.remove();bot=null;botText=null;lastNote=null;}
    </script></body></html>
    ''';

function JsString(const S: string): string;
var
  J: TJSONString;
begin
  J := TJSONString.Create(S);
  try
    Result := J.ToJSON;
  finally
    J.Free;
  end;
end;

{ TMCPChatPanel }

constructor TMCPChatPanel.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  Caption := '';
  ShowCaption := False;
  Width := 380;
  Height := 400;
  FQueue := TStringList.Create;
  FWelcome := 'Ask about the window you are working on.' + sLineBreak +
    'I can read it, explain it and fill it in for you.';

  FChat := TMCPClaudeChat.Create(Self);
  FChat.SetSubComponent(True);
  FChat.Name := 'Chat';
  FChat.OnText := ChatText;
  FChat.OnProgress := ChatProgress;
  FChat.OnToolCall := ChatToolCall;
  FChat.OnToolResult := ChatToolResult;
  FChat.OnDone := ChatDone;
  FChat.OnError := ChatError;
  FChat.OnBusyChange := ChatBusy;

  FBottom := TPanel.Create(Self);
  FBottom.Parent := Self;
  FBottom.Align := alBottom;
  FBottom.Height := 64;
  FBottom.BevelOuter := bvNone;
  FBottom.ShowCaption := False;
  FBottom.Padding.SetBounds(6, 6, 6, 6);

  FButton := TButton.Create(Self);
  FButton.Parent := FBottom;
  FButton.Align := alRight;
  FButton.Width := 72;
  FButton.Caption := 'Send';
  FButton.OnClick := ButtonClick;
  FButton.AlignWithMargins := True;
  FButton.Margins.SetBounds(6, 0, 0, 0);

  FInput := TMemo.Create(Self);
  FInput.Parent := FBottom;
  FInput.Align := alClient;
  FInput.ScrollBars := ssVertical;
  FInput.WantReturns := False; // Enter sends, Shift+Enter is a new line
  FInput.OnKeyDown := InputKeyDown;
  FInput.TextHint := 'Ask the assistant... (Enter to send)';

  FPlain := TMemo.Create(Self);
  FPlain.Parent := Self;
  FPlain.Align := alClient;
  FPlain.ReadOnly := True;
  FPlain.ScrollBars := ssVertical;
  FPlain.Visible := False;

  FBrowser := TEdgeBrowser.Create(Self);
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
  FBrowser.OnCreateWebViewCompleted := BrowserCreated;
  FBrowser.OnNavigationCompleted := BrowserNavigated;
  // keep the profile out of the program folder
  FBrowser.UserDataFolder := TPath.Combine(TPath.GetCachePath,
    TPath.Combine('delphi-mcp-forms', ChangeFileExt(ExtractFileName(ParamStr(0)), '')));

  // the panel is not part of the screen the assistant reads
  MCPIgnoreScreenControl(Self);
end;

destructor TMCPChatPanel.Destroy;
begin
  FQueue.Free;
  inherited;
end;

procedure TMCPChatPanel.CreateWnd;
begin
  inherited;
  if not FStarted and not (csDesigning in ComponentState) then
  begin
    FStarted := True;
    // after the window exists, so the browser has a parent handle
    TThread.ForceQueue(nil, StartBrowser);
  end;
end;

procedure TMCPChatPanel.StartBrowser;
begin
  try
    FBrowser.CreateWebView;
  except
    UseFallback;
  end;
end;

procedure TMCPChatPanel.BrowserCreated(Sender: TCustomEdgeBrowser; AResult: HResult);
begin
  if Succeeded(AResult) then
  begin
    FBrowser.DefaultContextMenusEnabled := False;
    FBrowser.StatusBarEnabled := False;
    FBrowser.NavigateToString(ChatPage);
  end
  else
    UseFallback;
end;

procedure TMCPChatPanel.BrowserNavigated(Sender: TCustomEdgeBrowser; IsSuccess: Boolean;
  WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
var
  S: string;
begin
  if FReady then
    Exit;
  if not IsSuccess then
  begin
    UseFallback;
    Exit;
  end;
  FReady := True;
  FBrowser.ExecuteScript('welcome(' + JsString(FWelcome) + ');');
  for S in FQueue do
    FBrowser.ExecuteScript(S);
  FQueue.Clear;
end;

procedure TMCPChatPanel.UseFallback;
begin
  // no WebView2 (loader or runtime missing): plain text, same conversation
  if FFailed then
    Exit;
  FFailed := True;
  FQueue.Clear;
  FBrowser.Visible := False;
  FPlain.Visible := True;
  FPlain.Lines.Text := FWelcome;
end;

procedure TMCPChatPanel.Run(const Fn: string; const Args: array of string);
var
  Script: string;
  I: Integer;
begin
  if FFailed then
    Exit;
  Script := Fn + '(';
  for I := 0 to High(Args) do
  begin
    if I > 0 then
      Script := Script + ',';
    Script := Script + Args[I];
  end;
  Script := Script + ');';
  if FReady then
    FBrowser.ExecuteScript(Script)
  else
    FQueue.Add(Script);
end;

procedure TMCPChatPanel.Plain(const S: string);
var
  T: string;
begin
  // the fallback transcript: one line per event
  if not FFailed then
    Exit;
  T := FPlain.Text;
  if (T <> '') and not T.EndsWith(sLineBreak) then
    T := sLineBreak
  else
    T := '';
  FPlain.SelStart := Length(FPlain.Text);
  FPlain.SelText := T + AdjustLineBreaks(S) + sLineBreak;
end;

procedure TMCPChatPanel.PlainAppend(const S: string);
begin
  if FFailed then
  begin
    FPlain.SelStart := Length(FPlain.Text);
    FPlain.SelText := AdjustLineBreaks(S);
  end;
end;

procedure TMCPChatPanel.SetWelcome(const Value: string);
begin
  FWelcome := Value;
  if FReady then
    Run('welcome', [JsString(Value)]);
end;

procedure TMCPChatPanel.Ask(const Question: string);
begin
  if Trim(Question) = '' then
    Exit;
  Run('user', [JsString(Question)]);
  Plain('> ' + Question);
  try
    FChat.Send(Question);
  except
    on E: Exception do
      ChatError(FChat, E.Message);
  end;
end;

procedure TMCPChatPanel.Clear;
begin
  FChat.ClearConversation;
  Run('welcome', [JsString(FWelcome)]);
  if FFailed then
    FPlain.Lines.Text := FWelcome;
end;

procedure TMCPChatPanel.InputKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    if ssShift in Shift then
    begin
      FInput.SelText := sLineBreak;
      Key := 0;
    end
    else if not FChat.Busy then
    begin
      Key := 0;
      ButtonClick(FButton);
    end;
  end;
end;

procedure TMCPChatPanel.ButtonClick(Sender: TObject);
var
  Q: string;
begin
  if FChat.Busy then
  begin
    FChat.Cancel;
    Exit;
  end;
  Q := Trim(FInput.Text);
  if Q = '' then
    Exit;
  FInput.Clear;
  Ask(Q);
end;

procedure TMCPChatPanel.ChatText(Sender: TObject; const Text: string);
begin
  Run('text', [JsString(Text)]);
  PlainAppend(Text);
end;

procedure TMCPChatPanel.ChatProgress(Sender: TObject; const Text: string);
begin
  Run('note', [JsString(Text)]);
  Plain('(' + Trim(Text) + ')');
end;

procedure TMCPChatPanel.ChatToolCall(Sender: TObject; const ToolName, ArgumentsJSON: string);
begin
  Inc(FToolSeq);
  Run('tool', [IntToStr(FToolSeq), JsString(ToolName), JsString(ArgumentsJSON)]);
  Plain('[' + ToolName + ']');
end;

procedure TMCPChatPanel.ChatToolResult(Sender: TObject; const ToolName, Result: string;
  IsError: Boolean);
begin
  // tools run one at a time: the result belongs to the last call
  Run('toolDone', [IntToStr(FToolSeq), BoolToStr(not IsError, True).ToLower,
    JsString(Copy(Result, 1, 2000))]);
  if IsError then
    Plain('[' + ToolName + ' failed: ' + Result + ']');
end;

procedure TMCPChatPanel.ChatDone(Sender: TObject; const StopReason: string);
begin
  Run('done', []);
  if StopReason = 'cancelled' then
    Run('error', [JsString('Stopped.')]);
  Plain('');
end;

procedure TMCPChatPanel.ChatError(Sender: TObject; const Text: string);
begin
  Run('error', [JsString(Text)]);
  Plain('! ' + Text);
end;

procedure TMCPChatPanel.ChatBusy(Sender: TObject);
begin
  if FChat.Busy then
    FButton.Caption := 'Stop'
  else
  begin
    FButton.Caption := 'Send';
    if FInput.CanFocus and (GetParentForm(Self) <> nil) and GetParentForm(Self).Active then
      FInput.SetFocus;
  end;
end;

end.
