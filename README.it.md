# delphi-mcp-forms

[English](README.md) · **Italiano**

**Tool in stile WebMCP per app desktop Delphi (VCL e FireMonkey), esposte tramite Model Context Protocol.**

[WebMCP](https://developer.chrome.com/docs/ai/webmcp) è uno standard web proposto. Con WebMCP una pagina dichiara a un agente AI nel browser quali azioni offre: una funzione JavaScript registrata con `registerTool()`, oppure un `<form>` HTML con gli attributi `toolname` e `tooldescription`. delphi-mcp-forms porta lo stesso modello nelle form Delphi:

- **Imperativo:** registri una funzione come tool, con uno JSON Schema e degli hint.
- **Dichiarativo:** metti un `TMCPFormTool` su una form e i suoi controlli di input diventano i parametri della tool. Quando un agente la chiama, la form viene compilata ed evidenziata, e l'agente aspetta che l'utente clicchi *Salva*. Con `AutoSubmit` il clic avviene da solo.

WebMCP è un'API del browser, non un protocollo di rete, e un'app desktop non ha un browser intorno. Per questo le tool vengono pubblicate con **MCP** standard: JSON-RPC su Streamable HTTP in `127.0.0.1`, oppure via WM_COPYDATA. Claude Code, Claude Desktop e qualunque altro client MCP le usano senza adattatori.

> Stato: 0.1, versione iniziale. Sviluppato e provato con Delphi 13 (Win32 e Win64). Il codice non usa funzionalità del linguaggio più recenti di generics e metodi anonimi, quindi potrebbe funzionare anche con versioni precedenti, ma non è stato provato.

## Avvio rapido

```pascal
uses MCPForms.Core, MCPForms.VCL, MCPForms.Transport.HTTP;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  // Tool imperativa (come document.modelContext.registerTool)
  ModelContext.RegisterTool('list-orders',
    'List the saved orders, one per line, with their numbers.',
    TMCPSchema.Empty,
    TMCPToolAnnotations.ReadOnly,
    function(const Args: TJSONObject): string
    begin
      Result := lstOrders.Items.Text;
    end);

  // Tool dichiarativa (come <form toolname tooldescription>)
  FOrderTool := TMCPFormTool.Create(Self);
  FOrderTool.Container := grpOrder;        // i controlli da esporre
  FOrderTool.SubmitControl := btnSave;     // il suo OnClick continua a funzionare
  FOrderTool.CancelControl := btnClear;
  FOrderTool.OnSubmit := OrderSubmitted;   // come SubmitEvent.respondWith()
  FOrderTool.ToolDescription := 'Create a sales order. The user reviews it and clicks Save.';
  FOrderTool.ToolName := 'create-order';

  FServer := TMCPHttpServer.Create(8765);  // http://127.0.0.1:8765/mcp
  FServer.Start;
end;
```

Per la form ordini di `Demos/VCL`, `tools/list` restituisce:

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

Le descrizioni che l'agente legge (nome e descrizione della tool, testi dei parametri) è meglio scriverle in inglese: i modelli le seguono in modo più affidabile.

## Collegare un client

Claude Code:

```bash
claude mcp add --transport http my-app http://127.0.0.1:8765/mcp
```

Claude Desktop e gli altri client che avviano solo server stdio possono passare da un bridge come `mcp-remote`:

```json
{ "mcpServers": { "my-app": { "command": "npx", "args": ["mcp-remote", "http://127.0.0.1:8765/mcp"] } } }
```

L'applicazione deve essere già in esecuzione. È lei il server: il client si collega, non la avvia.

### Senza porte di rete: WM_COPYDATA

Con il secondo trasporto non c'è niente in ascolto su TCP:

```pascal
uses MCPForms.Transport.WinMsg;

FWinMsg := TMCPWinMsgServer.Create;   // finestra "MCPForms:" + ModelContext.ServerName
FWinMsg.Start;
```

Il client MCP avvia `mcp_winmsg_bridge.exe` come un normale server stdio. Il bridge inoltra ogni messaggio all'app in esecuzione con `WM_COPYDATA`:

```json
{ "mcpServers": { "my-app": {
    "command": "C:\\Tools\\mcp_winmsg_bridge.exe",
    "args": ["--server", "my-app"] } } }
```

`mcp_winmsg_bridge --list` mostra le app in esecuzione. Ne scegli una con `--server NOME` o `--pid N`; `--verbose` scrive il traffico su stderr. Se l'app parte dopo il bridge, o si riavvia, il bridge la ritrova da solo.

Un programma Delphi può fare a meno del bridge e usare direttamente il client di `MCPForms.WinMsg`. È una sola unit, senza altre dipendenze:

```pascal
uses MCPForms.WinMsg;

var Client := TMCPWinMsgClient.Create(TMCPWinMsgClient.FindServer('my-app'));
try
  Reply := Client.Send('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
finally
  Client.Free;
end;
```

Lo scambio funziona così:

- La richiesta è un `WM_COPYDATA` con `wParam` uguale alla finestra di risposta del client, `dwData` uguale all'id della richiesta e `lpData` che contiene il messaggio JSON-RPC in UTF-8. Il server la accetta subito e la esegue in un thread separato.
- La risposta torna con un altro `WM_COPYDATA` alla finestra di risposta, con lo stesso `dwData`. Dati vuoti significano che la richiesta era una notifica.
- Più chiamate possono essere in corso insieme: una form che aspetta il clic dell'utente non blocca le altre.

## WebMCP e delphi-mcp-forms

| WebMCP | delphi-mcp-forms |
|---|---|
| `document.modelContext` | `ModelContext` (unit `MCPForms.Core`) |
| `registerTool({name, description, inputSchema, annotations, execute})` | `ModelContext.RegisterTool(...)`; per default `execute` gira sul thread principale |
| unregister tramite `AbortSignal` | `ModelContext.UnregisterTool(Name)`; le chiamate in corso non vengono annullate |
| `getTools()`, `executeTool()` | `ModelContext.GetTools`, `ModelContext.ExecuteTool` |
| `<form toolname tooldescription>` | `TMCPFormTool.ToolName`, `ToolDescription` |
| `toolparamdescription`, poi `<label>` | `Params[i].Description`, poi `Hint`, poi `TLabel.FocusControl` (VCL), poi l'etichetta più vicina, poi `TextPrompt` (FMX) |
| attributo `name` del campo | `Params[i].ParamName`, oppure il nome del controllo senza prefisso (`edtCustomer` diventa `customer`) |
| `<select>` diventa `enum` | `TComboBox` (lista a discesa), `TRadioGroup` |
| `required` | `Params[i].Required` |
| `toolautosubmit` | `AutoSubmit` |
| `SubmitEvent.agentInvoked` | `OnSubmit(Sender, AgentInvoked, var Response)` |
| `SubmitEvent.respondWith(promise)` | il `Response` di `OnSubmit`; `Reject('motivo')` restituisce un errore |
| `toolactivated`, `toolcancel` | `OnToolActivated`, `OnToolCancel` (CancelControl, oppure chiusura della form) |
| `:tool-form-active` | una cornice colorata intorno a `Container` (`HighlightColor`) |
| `readOnlyHint` | `readOnlyHint` di MCP |
| `consequentialHint` | `destructiveHint` di MCP. In più l'app chiede conferma all'utente prima di eseguire (`ConfirmHandler`) |
| `untrustedContentHint` | `openWorldHint` di MCP |

## Controlli supportati

| VCL | FMX | JSON Schema |
|---|---|---|
| `TEdit`, `TMaskEdit`, `TMemo`, qualunque `TCustomEdit` | `TEdit`, `TMemo` | `string` |
| `TComboBox` (`csDropDownList`), `TRadioGroup` | `TComboBox` | `string` + `enum` |
| `TComboBox` (altri stili) | `TComboEdit` | `string` + `examples` |
| `TCheckBox` | `TCheckBox`, `TSwitch` | `boolean` |
| `TSpinEdit`, `TTrackBar` | `TSpinBox`, `TNumberBox`, `TTrackBar` | `integer`/`number` + `minimum`/`maximum` |
| `TDateTimePicker` | `TDateEdit`, `TTimeEdit` | `string`, `YYYY-MM-DD` oppure `HH:MM[:SS]` |
| qualunque controllo con una proprietà `Text` published | | `string` |

I controlli di terze parti o personalizzati si aggiungono con `RegisterMCPControlAdapter`: si deriva da `TMCPControlAdapter` e si implementano `Supports`, `Schema` e `SetValue`.

## Come si svolge una chiamata dichiarativa

1. Il client chiama `tools/call create-order {...}`. La richiesta viene gestita su un thread secondario.
2. Sul thread principale gli argomenti vengono verificati rispetto ai controlli. Parametri sconosciuti, valori fuori lista e numeri fuori intervallo vengono rifiutati con un messaggio che il modello può usare per correggersi.
3. I controlli vengono valorizzati con i loro setter normali, quindi `OnChange` e `OnClick` scattano. Il contenitore riceve una cornice colorata.
4. Il thread secondario aspetta finché l'utente clicca il controllo di invio (o lo fa `AutoSubmit`), l'utente annulla, la form si chiude o scade `SubmitTimeout`.
5. Viene eseguito l'`OnClick` originale. Se solleva un'eccezione, o chiama `Reject('Customer is required.')`, l'agente riceve quell'errore. Altrimenti riceve il `Response` di `OnSubmit`.

## Sicurezza

- WM_COPYDATA non apre porte e i browser non possono raggiungerlo. Qualunque processo dello stesso utente sullo stesso desktop può però inviare messaggi alla finestra. Windows blocca i messaggi da un livello di integrità inferiore: un bridge non elevato non raggiunge un'app avviata come amministratore.
- Il server HTTP ascolta solo su `127.0.0.1`.
- Le richieste con un `Origin` del browser diverso da `localhost`, `127.0.0.1` o `[::1]` vengono rifiutate (protezione da DNS rebinding).
- Con `TMCPHttpServer.Token` il server richiede `Authorization: Bearer <token>`.
- Le tool con `ConsequentialHint` chiedono prima conferma all'utente. Le funzioni predefinite sono `MCPVclConfirm` e `MCPFmxConfirm`; si sostituiscono con `ModelContext.ConfirmHandler`.
- Quello che arriva da un agente va trattato come input non fidato: nel gestore di invio va validato come quello inserito da un utente.

## Limiti

- `listChanged` è `false`: il server non invia ancora `notifications/tools/list_changed`, quindi le tool registrate dopo il collegamento del client compaiono solo quando il client si ricollega. Chiamare una tool dichiarativa la cui form è nascosta restituisce un errore chiaro.
- Le griglie (`TDBGrid`, `TStringGrid`) non sono gestite.
- Un pulsante di invio che usa una `Action` al posto di `OnClick` non viene intercettato.
- I campi che l'agente non invia mantengono il valore attuale, come in WebMCP.
- L'header di sessione MCP e la revisione stateless del protocollo del 2026 non sono implementati.

## Unit

| Unit | Contenuto |
|---|---|
| `MCPForms.Core` | registro delle tool, costruttore di JSON Schema, dispatcher JSON-RPC di MCP (`HandleMessage`). Non usa né VCL né FMX. |
| `MCPForms.Transport.HTTP` | trasporto Streamable HTTP su localhost (Indy) |
| `MCPForms.Transport.WinMsg` | trasporto WM_COPYDATA, lato server (Windows) |
| `MCPForms.WinMsg` | client WM_COPYDATA e formato dei messaggi. Autonoma, non dipende dalle altre unit. |
| `MCPForms.FormTool` | base di `TMCPFormTool` indipendente dal framework |
| `MCPForms.VCL` | `TMCPFormTool` per VCL e adattatori dei controlli |
| `MCPForms.FMX` | `TMCPFormTool` per FireMonkey e adattatori dei controlli |

`TModelContext.HandleMessage(Request): Response` è l'intero endpoint sotto forma di funzione, quindi un altro trasporto (per esempio le named pipe) richiede poche righe.

`Tools/WinMsgBridge`: `mcp_winmsg_bridge.exe`, il ponte tra stdio e WM_COPYDATA.

## Demo

- `Demos/VCL`: inserimento ordini, porta 8765 e WM_COPYDATA. Tool dichiarativa `create-order`, più `list-orders` (sola lettura) e `delete-order` (con conferma dell'utente).
- `Demos/FMX`: prenotazione camere, porta 8766 e WM_COPYDATA. Tool dichiarativa `book-room` con `AutoSubmit`, più `list-bookings`.

Si compilano con `build.bat`, oppure aprendo i file `.dpr` nell'IDE.

## Licenza

MIT, vedi [LICENSE](LICENSE).
