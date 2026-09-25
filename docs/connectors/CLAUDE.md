# Connettore Claude (MCP)

Fusion Takeoff espone il design aperto a Claude tramite il **Model Context Protocol**.
Gli strumenti (creare, modificare, leggere la geometria, esportare) sono gli stessi
usati dalla chat interna all'app: ogni modifica è un passo annullabile (⌘Z) nell'app.

```
Claude Desktop ──stdio──▶ ftk-mcp ──HTTP 127.0.0.1 + token──▶ Fusion Takeoff (server MCP)
Claude Code ────────────────HTTP 127.0.0.1 + token──────────▶ Fusion Takeoff (server MCP)
```

- Il server gira dentro l'app, ascolta **solo su 127.0.0.1** (porta 51770, o una casuale se occupata)
  e richiede un token Bearer casuale; rifiuta le richieste con `Origin` diverso da localhost.
- Stato, endpoint, token e attività: barra di stato in basso → **MCP**.
- L'app scrive endpoint e token (permessi 0600) in
  `~/Library/Containers/com.takeoff.fusiontakeoff/Data/Library/Application Support/FusionTakeoff/mcp.json`;
  il bridge legge da lì, quindi non serve copiare il token a mano.

## Claude Desktop

```bash
scripts/install-claude-connector.sh
```
Compila il bridge in `~/.local/bin/ftk-mcp` e stampa la voce da aggiungere a
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{ "mcpServers": { "fusion-takeoff": { "command": "/Users/<tu>/.local/bin/ftk-mcp" } } }
```
Oppure `scripts/install-claude-connector.sh --write-desktop-config`, che aggiunge la voce da solo
(con backup del file). Riavvia Claude Desktop. Se l'app è chiusa, il bridge la apre.

## Claude Code

Due alternative:
```bash
claude mcp add fusion-takeoff -- ~/.local/bin/ftk-mcp          # via bridge (token automatico)
claude mcp add --transport http fusion-takeoff http://127.0.0.1:51770/mcp --header "Authorization: Bearer <token>"
```
Il comando HTTP completo, con il token, si copia dal pannello MCP dell'app.

## Verifica rapida

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ~/.local/bin/ftk-mcp
```

## Problemi comuni

| Sintomo | Causa |
|---|---|
| "Fusion Takeoff non è in esecuzione o il server MCP è disattivato" | App chiusa e non avviabile, oppure interruttore MCP spento nel pannello |
| Lista strumenti vuota | Strumenti CAD non ancora disponibili (T48) |
| HTTP 401 dopo "Rigenera token" | Il bridge rilegge il token da solo; per Claude Code HTTP ricopia il comando |
