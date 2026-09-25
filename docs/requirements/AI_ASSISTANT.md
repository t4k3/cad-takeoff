# Assistente geometrico e connettori — priorità principale

25 settembre 2026 · decisione di Ross, concordata Claude ↔ Codex nel registro.

La chat è un ambiente principale di progettazione: deve creare e modificare
geometrie del documento aperto, verificare il risultato e mostrare le operazioni
eseguite. La conversazione non sostituisce lo storico CAD: ogni operazione deve
restare modificabile anche tramite l'interfaccia, senza dipendere dal modello AI.

## Responsabilità

| Parte | Responsabile | Interfaccia comune |
|---|---|---|
| UX chat, selezione e schede operazioni | Claude | AssistantSession, ToolResult |
| Provider Anthropic e connettore Claude | Claude | AssistantProvider, MCP |
| Provider OpenAI e connettore ChatGPT | Codex | AssistantProvider, MCP |
| Comandi, geometria, revisioni, validazione, undo | Codex | CADToolProvider |
| Protocollo e integrazione | Concordati nel registro | ToolBridge.swift |

## Percorsi di accesso

1. **Chat dentro l'app:** provider Claude oppure OpenAI; il ciclo conversazionale
   invoca lo stesso CADToolProvider usato da MCP. Le chiavi API si configurano nel
   Portachiavi dell'utente. Il documento resta nel Model locale; gli argomenti e
   risultati degli strumenti vengono inviati al provider selezionato.
2. **Claude esterno:** bridge stdio locale `ftk-mcp` e server MCP dell'app.
3. **ChatGPT esterno:** preferenza per Secure MCP Tunnel privato OpenAI collegato
   allo stesso bridge. Richiede configurazione del tunnel e accesso del workspace;
   il server locale non diventa automaticamente pubblico. Un endpoint HTTPS
   pubblico con autenticazione rimane un'alternativa di distribuzione futura.

Il catalogo CAD è unico. Nessun provider genera shell, Swift o script arbitrari
per modificare il documento. Gli strumenti ammessi sono dichiarati con schema,
unità, limiti, descrizioni e indicazione di lettura o modifica.

## Contratto di esecuzione

- Leggere scena e revisione prima delle modifiche. Ogni mutazione porta
  `expected_revision`; richieste obsolete falliscono senza cambiare geometria.
- Ogni comando valida tutti gli argomenti e prepara il risultato prima del commit.
  Una chiamata riuscita che cambia il documento corrisponde a un passo di undo.
- Errori di geometria, ID inesistenti e funzioni non disponibili sono risultati
  espliciti; il modello non deve dichiarare una modifica che non è stata applicata.
- Le due chat condividono la scena; i comandi sono serializzati dal Model.
  Non possono sovrascrivere silenziosamente il lavoro dell'altra.
- La UI mostra comando, parametri utili, esito, feature interessate e possibilità
  di annullare. Esportazione v1 come dato o attraverso pannello utente, mai tramite
  un percorso del filesystem scelto liberamente dal modello.
- Cancellazione della risposta ferma i successivi comandi. Operazioni già applicate
  rimangono nel documento e possono essere annullate; non dichiarare un rollback
  dell'intera conversazione se non è stato eseguito.
- In futuro lo storico persistente registra provenienza, feature, parametri,
  dipendenze e risultato. Il testo della chat non è il formato geometrico.

## Incrementi verificabili

| Incremento | Task | Criterio |
|---|---|---|
| Strumenti v1 | T48 | Primitive, estrusione di profilo semplice, lettura/modifica/elimina, visibilità, misure, STL, undo/redo; test senza rete |
| Claude esterno e chat | T49, T50, T52 | Stessi strumenti visibili e chiamabili, errori mostrati, connessione verificata |
| ChatGPT e OpenAI | T51, T53 | Connessione configurabile, tool calling e streaming; credenziali mancanti dichiarate |
| Prova comune | T55 | Stessa richiesta eseguita sui tre percorsi, confronto geometrico e annullamento |
| CAD avanzato | T54 + task CAD | Schizzi, storico parametrico, lamiera e assiemi aggiunti al catalogo quando il core è pronto |

Primo caso: «Crea una base 40 × 30 × 5 mm, portala a 8 mm, verifica volume e
annulla l'ultima modifica». Casi negativi: misure non finite/negative, profilo
intrecciato, ID inesistente, revisione cambiata da un altro client, interruzione
stream, chiamata incompleta e richiesta di una piega non ancora implementata.
Il percorso completo finale include la staffa in lamiera e l'assieme definiti
in [CAD_SCOPE_V2.md](CAD_SCOPE_V2.md).

## Fonti e limiti di verifica

La chat OpenAI usa il ciclo di strumenti della
[Responses API](https://developers.openai.com/api/docs/guides/function-calling).
Il collegamento privato esterno segue la documentazione
[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
e [connessione ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt).
La disponibilità del tunnel e le autorizzazioni del workspace vanno verificate
nell'account. Build e test locali non provano l'accesso a un servizio remoto.
