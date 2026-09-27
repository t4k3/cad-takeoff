# Circuiti — collaudo dei provider remoti e dei connettori

T105 separa tre livelli: protocollo del provider nell'app, trasporto MCP locale,
client esterno autenticato. Un PASS di uno non vale come PASS degli altri.

## Regressione offline dei provider reali

```sh
bash Tests/Electronics/RemoteProviders/run.sh
```

Il runner compila gli stessi `ClaudeProvider` e `OpenAIProvider` dell'app,
intercetta tutte le richieste con `URLProtocol` e sostituisce il Portachiavi con
un valore fittizio nel solo eseguibile di test. Nessuna richiesta raggiunge Internet,
nessuna chiave reale viene letta e nessun documento viene aperto o modificato.
Non introduce una libreria esterna né un provider alternativo nel prodotto.

Il comando deve terminare con exit 0. Copre:

- risposta completa che consegna esattamente `circuit_apply` e gli argomenti attesi;
- EOF dopo argomenti JSON validi ma prima della conferma finale;
- blocco Claude non chiuso, messaggio iniziale/finale o stop reason assente;
- chiusura del blocco o motivo di fine arrivati dopo `message_stop`;
- ID di chiamata duplicato e motivo di fine incoerente;
- limite di token, rifiuto del modello, errore del server e stream vuoto;
- reset della conversazione durante lo stream: il vecchio turno non può consegnare comandi;
- risposta testuale ordinaria, senza chiamate.

Sono prove deterministiche del protocollo HTTP/SSE effettivamente consumato dal
provider, non prove dell'affidabilità del modello remoto né dell'esecuzione di
un circuito. L'esecuzione e l'annullamento sono verificati separatamente in
[APP_ACCEPTANCE.md](APP_ACCEPTANCE.md) e [VALIDATION.md](VALIDATION.md).

Esito sul sorgente `b0f01bb`: **23/23 PASS, exit 0**. Le prove hanno prima
riprodotto l'esecuzione prematura e poi verificato le correzioni di Claude
`dede339` e `b0f01bb`. Il runner resta una regressione da eseguire insieme alla CI.

## Prerequisiti verificati il 27 settembre 2026

| Percorso | Riscontro locale | Prova ancora necessaria |
|---|---|---|
| Claude nell'app | UI 1.0.58: chiave Anthropic non salvata | Configurazione personale e richiesta reale |
| OpenAI nell'app | UI 1.0.58: chiave OpenAI non salvata | Configurazione personale e richiesta reale |
| Claude Desktop MCP | Voce `fusion-takeoff` presente, eseguibile configurato esistente | Client effettivamente caricato, discovery e chiamata naturale |
| ChatGPT esterno MCP | Bridge firmato presente; `tunnel-client` e chiave runtime assenti nell'ambiente controllato | Client ufficiale, tunnel/account/workspace e prova reale |

Controllo locale ripetibile per ChatGPT:

```sh
python3 scripts/connect-chatgpt.py check --bridge \
  build/DerivedData/Build/Products/Debug/FusionTakeoff.app/Contents/MacOS/ftk-mcp
```

`check` legge soltanto i prerequisiti locali e non verifica autenticazione o permessi.
Le chiavi personali vanno inserite nei campi protetti di Impostazioni → Assistente,
mai nel registro, nelle fixture o nella chat di sviluppo. Il connettore esterno usa
la propria configurazione, distinta dalla chiave API della chat interna.

## Accettazione dal vivo, quando configurato

Per ciascun provider/client annotare versione/commit dell'app, modello effettivo,
trasporto, data ed esito; non registrare segreti. Usare esclusivamente una copia
fresca di `01-produzione.ftkc` preparata come descritto in APP_ACCEPTANCE.

1. Leggere `circuit_info` e controllare design ID `fab00000-0000-0000-0000-000000001104`,
   nome «QA Produzione» e revisione documento zero. La prova si ferma su un altro documento.
2. Richiesta naturale: «Verifica se il circuito è pronto per la produzione,
   senza modificarlo». Attesi nove strati, tre fori e revisione invariata.
3. «Rinomina la rete SUPPLY in QA_REMOTE. Esegui anteprima e applicazione,
   senza altre modifiche». Verificare `circuit_preview` → `circuit_apply` con lo
   stesso preview ID, revisione +1, una sola rete rinominata e geometria intatta.
4. «Annulla l'ultima modifica al circuito». Verificare `circuit_undo`, ritorno
   a SUPPLY, geometria iniziale e revisione +1. Non basta la risposta testuale.
5. Leggere lo stato tramite il bridge locale indipendentemente dalla chat.
   Conservare le risposte ripulite da credenziali e riaprire la fixture scartando
   esclusivamente le modifiche QA, senza salvare sopra un progetto reale.

La prova T104 del bridge locale e della chat Apple è già conclusa. Il collaudo
remoto autenticato resta distinto e aperto finché queste operazioni non sono
osservate attraverso il provider/client effettivo.

## Riferimenti del protocollo

- [Anthropic: streaming Messages](https://platform.claude.com/docs/en/build-with-claude/streaming):
  sequenza `message_start`, blocchi chiusi, `message_delta`, `message_stop`.
- [OpenAI: function calling](https://developers.openai.com/api/docs/guides/function-calling):
  le richieste di funzione sono eseguite dall'applicazione e ricevono un risultato correlato.
- [OpenAI: Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels):
  riferimento per il collegamento esterno già previsto dal progetto.
