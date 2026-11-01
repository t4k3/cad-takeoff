# Prova end-to-end dei provider assistente (T55)

Registro di ciò che è stato verificato davvero, di ciò che richiede una chiave che non abbiamo
e dei passi che Ross deve fare nell'app. Aggiornato il 2026-11-01.

## Cosa copre

Due famiglie di accesso, gli stessi strumenti in entrambe:

| Famiglia | Endpoint | Provider registrati |
|---|---|---|
| Anthropic Messages | `<base>/v1/messages` | Claude (`api.anthropic.com`), Anthropic compatibile (es. `api.deepseek.com/anthropic`) |
| OpenAI Chat Completions | `<base>/chat/completions` | ChatGPT (`api.openai.com/v1`), DeepSeek (`api.deepseek.com`), OpenAI compatibile |

Una chiave e un modello si possono cambiare in **Impostazioni → Assistente**; le chiavi stanno nel
Portachiavi di macOS, non nei file del progetto.

## Ambiente

- macOS, app **CAD Takeoff** compilata da `scripts/build.sh`.
- Modello reale usato per la prova: **DeepSeek** `deepseek-flash` (compatibile OpenAI e Anthropic).
- La chiave è stata passata solo come variabile d'ambiente `DEEPSEEK_API_KEY` al comando di test:
  non è scritta in nessun file del repository (`grep` sul prefisso della chiave: nessun risultato).

## Comandi eseguiti e risultati

| Comando | Risultato |
|---|---|
| `bash scripts/test-assistant-deepseek.sh` (offline, trasporto simulato) | `PASS 67/67` |
| `DEEPSEEK_API_KEY=… bash scripts/test-assistant-deepseek.sh --live` | `PASS 63/63` (le asserzioni dei fixture offline non girano in modalità live) |

La modalità `--live` fa **3 richieste in totale**, senza retry e con risposte di una parola:

1. `OpenAIChatProvider(.deepSeek)`, Chat Completions, prompt «Rispondi solo: OK» → stop `.done`,
   testo ricevuto in streaming (2 caratteri).
2. Stessa interfaccia con lo strumento `probe_tool` → stop `.toolCalls ["probe_tool"]`,
   quindi il giro completo `tools` → `tool_calls` → argomenti JSON funziona.
3. `ClaudeProvider(config: .compatible)` su `https://api.deepseek.com/anthropic`,
   Messages API → stop `.done`.

## Cosa non è stato eseguito

- **Claude con chiave reale** (`api.anthropic.com`): non abbiamo una chiave Anthropic.
- **ChatGPT con chiave reale** (`api.openai.com`): non abbiamo una chiave OpenAI.
- **CLI Claude / ChatGPT che pilotano l'app via MCP**: la parte MCP è coperta da
  `scripts/test-mcp-integration.sh` (41 strumenti via HTTP) e dalle guide
  [CLAUDE.md](CLAUDE.md) e [CHATGPT.md](CHATGPT.md); la prova con un account reale richiede
  le chiavi e l'app aperta.

Le due interfacce però sono le stesse già usate dalla prova DeepSeek, e in offline i corpi di
richiesta di `.claude`, `.chatGPT`, `.deepSeek` e dei due compatibili sono verificati dai fixture:
cambia solo l'endpoint e qualche campo proprietario (thinking, cache, fallback).

## Passi per Ross nell'app

1. **Impostazioni → Assistente**, sezione **Claude (Anthropic)**: incollare la chiave
   (`sk-ant-…`), scegliere il modello, premere **Salva**. La riga deve diventare
   «Salvata nel Portachiavi» e sparire l'avviso rosso.
2. Sezione **ChatGPT (OpenAI)**: chiave da `platform.openai.com` (l'abbonamento ChatGPT non basta),
   modello, **Salva**.
3. Sezione **DeepSeek**: chiave, `deepseek-flash` o `deepseek-v4-pro`, **Salva**.
4. **Anthropic compatibile** e **OpenAI compatibile**: scrivere `Base URL` e `Modello` del servizio
   che si vuole usare (es. `https://api.deepseek.com/anthropic` + `deepseek-flash`;
   `https://api.deepseek.com` + `deepseek-flash`), poi la chiave e **Salva**.
   Il modello si può cambiare senza rifare la chiave.
5. Chiudere e riaprire l'app: modello e Base URL devono restare; la chiave non deve essere
   richiesta di nuovo.
6. Aprire la chat (pannello assistente) e provare, ad esempio, «Crea un box 40×30×20 e poi
   uno schizzo con un rettangolo su XY»: devono comparire le schede degli strumenti con esito,
   e ⌘Z deve annullare l'ultimo passo.
7. Per i connettori esterni: barra di stato → **MCP**, poi seguire la guida del client
   (Claude o ChatGPT).

## Ordine di controllo se qualcosa non va

1. La sezione mostra ancora «non configurato»? Manca chiave, modello o Base URL (i due campi
   compatibili partono vuoti).
2. La richiesta parte ma torna un errore: leggere il messaggio con lo **status HTTP**.
   401 → chiave errata o rimossa dal Portachiavi; 404 → Base URL o modello sbagliati;
   400 → il servizio non accetta un campo inviato (per i compatibili non vengono inviati
   `thinking`, `reasoning_effort`, cache, fallback, `stream_options`).
3. Lo stream si interrompe: l'errore dice quale parte manca («stream interrotto», «ID di
   chiamata duplicati», «tool_calls senza chiamate»); la conversazione non viene alterata.
4. Se il problema è nell'app e non nel provider: `scripts/test-assistant-deepseek.sh` offline
   deve dare `PASS 67/67`; se fallisce, il difetto è nel codice, non nella chiave.
5. Solo per MCP: `scripts/test-mcp-integration.sh` e, con il client esterno, la verifica rapida
   in [CLAUDE.md](CLAUDE.md).
