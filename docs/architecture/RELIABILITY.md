# Affidabilità della mappa — T58

Revisione 2 · 25 settembre 2026 · Codex.

**Mappa esplorativa manuale/testuale, parziale. Non è un code graph semantico.**
Specifica curata: `graph-spec.json`; dataset canonico: `graph.json`; viste
HTML/Mermaid derivate dallo stesso dataset. Il grafo del dominio richiesto
in `docs/requirements/` è distinto dal sorgente implementato.

## Identità e copertura

Checkout `/Users/ross/APP varie/FUSION-TAKEOFF`; progetto e scheme
`FusionTakeoff`; Debug, macOS arm64, Swift 6, deployment macOS 14.
Commit, dirty state, data UTC, toolchain e hash sono nel dataset.

| Misura dello snapshot T58 | Risultato |
|---|---:|
| File sorgente trovati/inventariati | 49 / 49 |
| File con simboli mappati | 28 |
| Tipi/confini selezionati | 41 |
| Archi | 57 |
| SYNTACTIC | 43 |
| INFERRED | 5 |
| RUNTIME/EXTERNAL | 9 |
| RESOLVED / AMBIGUOUS | 0 / 0 |
| File analizzati semanticamente | 0 |

Inclusi App, CADCore e bridge `Tools/ftk-mcp`. Test tracciati per freshness ma
non mappati come chiamanti. I 21 file non mappati sono elencati nel JSON.
Inventario non significa copertura completa dei simboli. `parseErrors: null`
significa non misurato: non è stato eseguito un parser AST o SourceKit/IndexStore.
Macro, result builder, overload, witness di protocolli e internals Apple esclusi.

## Metodo e aggiornamento

Ogni relazione conserva file, riga, hash SHA-256, target, estrazione testuale e
incertezza. Anchor assenti o ambigui interrompono la generazione. Il controllo
confronta anche file aggiunti/rimossi, configurazione, generatore e template,
e verifica coerenza delle viste col dataset. I sorgenti letti due volte durante
la generazione devono restare identici per evitare uno snapshot misto.

`python3 scripts/architecture_graph.py check` restituisce `FRESH_EXPLORATORY`
oppure `STALE`. Fresco non significa semanticamente risolto. Il generatore
rifiuta archi RESOLVED: richiederebbero un estrattore semantico successivo.
La collaborazione parallela può rendere lo snapshot obsoleto appena un agente
cambia sorgenti; verificare prima di usarlo per modificare API.

## Sonde aggiornate

- AssistantProvider/CADToolProvider: conformità testuali, dispatch inferito.
- UI: WorkspaceView, InspectorPanel, chat e Metal sostituiscono il vecchio
  snapshot ContentView/SceneKit. Observation e SwiftUI non espansi.
- Task/await presenti in sessione chat, provider e trasporti; nessun actor hop
  semanticamente ricostruito e nessuna deduzione di assenza di race.
- Provider OpenAI presente nel sorgente; la sua registrazione nella UI resta
  un passaggio d'integrazione di Claude. Un nodo non prova che sia selezionabile.
- Confini HTTP OpenAI/Anthropic, tunnel, GPU e disco marcati esterni/inferiti.
  Nessuna connessione remota o correttezza numerica viene provata dagli archi.
- Le API pubbliche/testate senza chiamanti UI non sono considerate codice morto.

## Verifiche separate dal grafo

- CADCore: sei test Swift Testing passati.
- Strumenti CAD: test su dimensioni, profili concavi/intersecanti, revisioni,
  mutazioni atomiche, undo/redo, cambio manuale ed export STL.
- Provider OpenAI: 23 verifiche offline, comprese chiamate incomplete, errori,
  tool results, continuità e cifratura opaca dello stato di ragionamento.
- MCP: 13 verifiche con vero HTTP loopback e Model isolato, inclusi creazione,
  volume, undo, conflitto di revisione, autenticazione e Origin.
- Xcode: build app riuscita. Nessuna chiamata ai provider remoti in queste prove.
- Interfaccia del grafo: ricerca OpenAI e filtri controllati nel browser locale;
  geometria della pagina verificata visivamente, dati incorporati senza CDN.

Il completamento dei task è nel registro e nel grafo attività, non in questa
mappa. Nessuna prova fisica di stampa/lamiera, completa implementazione assiemi,
funzionalità dello storico parametrico, pubblicazione TestFlight o disponibilità
degli account remoti è implicita.
