# delphi-mcp-forms

**English** · [Italiano](README.it.md)

**WebMCP-style tools for Delphi desktop apps (VCL and FireMonkey), served over the Model Context Protocol.**

[WebMCP](https://developer.chrome.com/docs/ai/webmcp) is a proposed web standard. A web page uses it to tell an in-browser AI agent which actions it offers: a JavaScript function registered with `registerTool()`, or an HTML `<form>` annotated with `toolname` and `tooldescription`. delphi-mcp-forms brings the same model to Delphi forms:

- **Imperative:** register a function as a tool, with a JSON Schema and hints.
- **Declarative:** drop a `TMCPFormTool` on a form. Its input controls become the tool's parameters. When an agent calls the tool, the form is filled and highlighted, and the agent waits for the user to click *Save*. With `AutoSubmit` the click happens automatically.

WebMCP is a browser API, not a wire protocol, and a desktop app has no browser around it. The tools are therefore published with standard **MCP** (JSON-RPC over Streamable HTTP on `127.0.0.1`). Claude Code, Claude Desktop, and any other MCP client can use them without a custom adapter.

> Status: 0.1, early. Developed and tested with Delphi 13 (Win32). No language features newer than generics and anonymous methods are used, so older versions may work, but they are untested.

## Quick start

```pascal
uses MCPForms.Core, MCPForms.VCL, MCPForms.Transport.HTTP;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  // Imperative tool (like document.modelContext.registerTool)
  ModelContext.RegisterTool('list-orders',
    'List the saved orders, one per line, with their numbers.',
    TMCPSchema.Empty,
    TMCPToolAnnotations.ReadOnly,
    function(const Args: TJSONObject): string
    begin
      Result := lstOrders.Items.Text;
    end);

  // Declarative tool (like <form toolname tooldescription>)
  FOrderTool := TMCPFormTool.Create(Self);
  FOrderTool.Container := grpOrder;        // the controls to expose
  FOrderTool.SubmitControl := btnSave;     // its OnClick keeps working
  FOrderTool.CancelControl := btnClear;
  FOrderTool.OnSubmit := OrderSubmitted;   // like SubmitEvent.respondWith()
  FOrderTool.ToolDescription := 'Create a sales order. The user reviews it and clicks Save.';
  FOrderTool.ToolName := 'create-order';

  FServer := TMCPHttpServer.Create(8765);  // http://127.0.0.1:8765/mcp
  FServer.Start;
end;
```

For the order form in `Demos/VCL`, `tools/list` returns:

```json
{ "name": "create-order",
  "inputSchema": { "type": "object", "properties": {
    "customer":  { "type": "string",  "description": "Customer company name" },
    "product":   { "type": "string",  "enum": ["Espresso machine", "Coffee grinder", "Milk frother", "Descaling kit"] },
    "quantity":  { "type": "integer", "minimum": 1, "maximum": 100 },
    "delivery":  { "type": "string",  "format": "date" },
    "giftWrap":  { "type": "boolean", "description": "Gift wrap" },
    "notes":     { "type": "string",  "description": "Notes" } } } }
```

## Connect a client

Claude Code:

```bash
claude mcp add --transport http my-app http://127.0.0.1:8765/mcp
```

Claude Desktop and other clients that only start stdio servers can use a bridge such as `mcp-remote`:

```json
{ "mcpServers": { "my-app": { "command": "npx", "args": ["mcp-remote", "http://127.0.0.1:8765/mcp"] } } }
```

The application must be running. It is the server, so the client connects to it and does not launch it.

### Without a network port: WM_COPYDATA

Add a second transport and nothing listens on TCP:

```pascal
uses MCPForms.Transport.WinMsg;

FWinMsg := TMCPWinMsgServer.Create;   // window "MCPForms:" + ModelContext.ServerName
FWinMsg.Start;
```

MCP clients start `mcp_winmsg_bridge.exe` as an ordinary stdio server. The bridge forwards each message to the running app with `WM_COPYDATA`:

```json
{ "mcpServers": { "my-app": {
    "command": "C:\\Tools\\mcp_winmsg_bridge.exe",
    "args": ["--server", "my-app"] } } }
```

`mcp_winmsg_bridge --list` shows the running apps. Select one with `--server NAME` or `--pid N`; `--verbose` logs the traffic to stderr. If the app starts after the bridge, or restarts, the bridge finds it again.

Delphi programs can skip the bridge and use the client in `MCPForms.WinMsg` directly. That single unit has no other dependencies:

```pascal
uses MCPForms.WinMsg;

var Client := TMCPWinMsgClient.Create(TMCPWinMsgClient.FindServer('my-app'));
try
  Reply := Client.Send('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
finally
  Client.Free;
end;
```

The exchange works like this:

- The request is a `WM_COPYDATA` with `wParam` set to the client's reply window, `dwData` set to a request id, and `lpData` holding the UTF-8 JSON-RPC message. The server accepts it at once and runs it on a worker thread.
- The response comes back as another `WM_COPYDATA` to the reply window, with the same `dwData`. Empty data means the request was a notification.
- Several calls can be in flight at once. A form waiting for the user's click does not hold up the others.

## WebMCP and delphi-mcp-forms

| WebMCP | delphi-mcp-forms |
|---|---|
| `document.modelContext` | `ModelContext` (unit `MCPForms.Core`) |
| `registerTool({name, description, inputSchema, annotations, execute})` | `ModelContext.RegisterTool(...)`; `execute` runs on the main thread by default |
| unregister via `AbortSignal` | `ModelContext.UnregisterTool(Name)`; running calls are not cancelled |
| `getTools()`, `executeTool()` | `ModelContext.GetTools`, `ModelContext.ExecuteTool` |
| `<form toolname tooldescription>` | `TMCPFormTool.ToolName`, `ToolDescription` |
| `toolparamdescription`, then `<label>` | `Params[i].Description`, then `Hint`, then `TLabel.FocusControl` (VCL), then the nearest label, then `TextPrompt` (FMX) |
| field `name` | `Params[i].ParamName`, or the control name without its prefix (`edtCustomer` becomes `customer`) |
| `<select>` becomes `enum` | `TComboBox` (drop-down list), `TRadioGroup` |
| `required` | `Params[i].Required` |
| `toolautosubmit` | `AutoSubmit` |
| `SubmitEvent.agentInvoked` | `OnSubmit(Sender, AgentInvoked, var Response)` |
| `SubmitEvent.respondWith(promise)` | the `Response` of `OnSubmit`; `Reject('why')` returns an error |
| `toolactivated`, `toolcancel` | `OnToolActivated`, `OnToolCancel` (CancelControl, or the form closing) |
| `:tool-form-active` | a coloured frame around `Container` (`HighlightColor`) |
| `readOnlyHint` | MCP `readOnlyHint` |
| `consequentialHint` | MCP `destructiveHint`. The app also asks the user before running the tool (`ConfirmHandler`) |
| `untrustedContentHint` | MCP `openWorldHint` |

## Supported controls

| VCL | FMX | JSON Schema |
|---|---|---|
| `TEdit`, `TMaskEdit`, `TMemo`, any `TCustomEdit` | `TEdit`, `TMemo` | `string` |
| `TComboBox` (`csDropDownList`), `TRadioGroup` | `TComboBox` | `string` + `enum` |
| `TComboBox` (other styles) | `TComboEdit` | `string` + `examples` |
| `TCheckBox` | `TCheckBox`, `TSwitch` | `boolean` |
| `TSpinEdit`, `TTrackBar` | `TSpinBox`, `TNumberBox`, `TTrackBar` | `integer`/`number` + `minimum`/`maximum` |
| `TDateTimePicker` | `TDateEdit`, `TTimeEdit` | `string`, `YYYY-MM-DD` or `HH:MM[:SS]` |
| any control with a published `Text` | | `string` |

Third-party or custom controls are added with `RegisterMCPControlAdapter`: subclass `TMCPControlAdapter` and implement `Supports`, `Schema` and `SetValue`.

## How a declarative call runs

1. The client calls `tools/call create-order {...}`. Indy handles it on a worker thread.
2. On the main thread, the arguments are validated against the controls. Unknown parameters, values outside the list and out-of-range numbers are rejected with a message the model can act on.
3. The controls are filled through their normal setters, so `OnChange` and `OnClick` fire. The container gets a coloured frame.
4. The worker thread waits until the user clicks the submit control (or `AutoSubmit` clicks it), the user cancels, the form closes, or `SubmitTimeout` expires.
5. The original `OnClick` runs. If it raises an exception, or calls `Reject('Customer is required.')`, the agent gets that error. Otherwise the `Response` from `OnSubmit` is returned.

## Security

- WM_COPYDATA opens no port, and browsers cannot reach it. Any process of the same user on the same desktop can send to the window. Windows blocks messages from a lower integrity level, so a non-elevated bridge cannot reach an app running as administrator.
- The HTTP server listens on `127.0.0.1` only.
- Requests with a browser `Origin` other than `localhost`, `127.0.0.1` or `[::1]` are refused (DNS rebinding).
- Set `TMCPHttpServer.Token` to require `Authorization: Bearer <token>`.
- Tools marked `ConsequentialHint` ask the user first. The defaults are `MCPVclConfirm` and `MCPFmxConfirm`; replace them with `ModelContext.ConfirmHandler`.
- Treat what an agent sends as untrusted input. Validate in your submit handler as you would for a user.

## Limitations

- `listChanged` is `false`: the server does not push `notifications/tools/list_changed` yet, so tools registered after the client connected appear only after it reconnects. Calling a declarative tool whose form is hidden returns a clear error.
- Grids (`TDBGrid`, `TStringGrid`) are not mapped.
- A submit button that uses an `Action` instead of `OnClick` is not hooked.
- Fields the agent does not send keep their current value, as in WebMCP.
- The MCP session header and the 2026 stateless protocol revision are not implemented.

## Units

| Unit | Contents |
|---|---|
| `MCPForms.Core` | tool registry, JSON Schema builder, MCP JSON-RPC dispatcher (`HandleMessage`). Uses neither VCL nor FMX. |
| `MCPForms.Transport.HTTP` | Streamable HTTP transport on localhost (Indy) |
| `MCPForms.Transport.WinMsg` | WM_COPYDATA transport, server side (Windows) |
| `MCPForms.WinMsg` | WM_COPYDATA client and wire format. Standalone, with no dependency on the other units. |
| `MCPForms.FormTool` | framework-neutral base of `TMCPFormTool` |
| `MCPForms.VCL` | `TMCPFormTool` for VCL, control adapters |
| `MCPForms.FMX` | `TMCPFormTool` for FireMonkey, control adapters |

`TModelContext.HandleMessage(Request): Response` is the whole endpoint as a function, so another transport (named pipes, for example) takes only a few lines.

`Tools/WinMsgBridge`: `mcp_winmsg_bridge.exe`, which connects stdio and WM_COPYDATA.

## Demos

- `Demos/VCL`: order entry, port 8765 and WM_COPYDATA. Declarative `create-order`, plus `list-orders` (read-only) and `delete-order` (consequential, asks for confirmation).
- `Demos/FMX`: room booking, port 8766 and WM_COPYDATA. Declarative `book-room` with `AutoSubmit`, plus `list-bookings`.

Build them with `build.bat`, or open the `.dpr` files in the IDE.

## Related projects

- [GDKsoftware/Delphi-MCP-Server](https://github.com/GDKsoftware/Delphi-MCP-Server): a complete MCP server framework for Delphi, with STDIO and HTTP transports, resources and OAuth.
- [JavierusTk/DelphiMCP](https://github.com/JavierusTk/DelphiMCP): generic UI automation of VCL apps (click, type, screenshot).

delphi-mcp-forms takes a different approach. Instead of letting an agent drive the UI control by control, the application **declares** the actions it offers, the way a web page does with WebMCP.

## License

MIT, see [LICENSE](LICENSE).
