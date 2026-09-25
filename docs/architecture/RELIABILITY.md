# Affidabilità della mappa — T70/T75

Revisione 3 · 25 settembre 2026 · Codex.

**Mappa esplorativa manuale/testuale, parziale. Non è un code graph semantico.**
Specifica curata: `graph-spec.json`; dataset canonico: `graph.json`; viste
HTML/Mermaid derivate dallo stesso dataset. Il grafo del dominio richiesto
in `docs/requirements/` è distinto dal sorgente implementato.

## Identità e copertura

Checkout `/Users/ross/APP varie/FUSION-TAKEOFF`; progetto e scheme
`FusionTakeoff`; Debug, macOS arm64, Swift 6, deployment macOS 14.
Commit, dirty state, data UTC, toolchain e hash sono nel dataset.

| Misura dello snapshot T70/T75 | Risultato |
|---|---:|
| File sorgente trovati/inventariati | 64 / 64 |
| File con simboli mappati | 36 |
| Tipi/confini selezionati | 63 |
| Archi | 86 |
| SYNTACTIC | 71 |
| INFERRED | 5 |
| RUNTIME/EXTERNAL | 10 |
| RESOLVED / AMBIGUOUS | 0 / 0 |
| File analizzati semanticamente | 0 |

Inclusi App, CADCore e bridge `Tools/ftk-mcp`. Test tracciati per freshness ma
non mappati come chiamanti. I 28 file non mappati sono elencati nel JSON.
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
- Kernel: `DesignModel.snapshot` chiama `PrimitiveKernel.build`, che costruisce
  `BRepBody`; il metodo `BRepBody.snapshot` produce `BodySnapshot`. Riferimenti
  testuali verificati, zero chiamanti semanticamente risolti. API pubblica usata
  dal Model e dai test, non codice morto anche in attesa del renderer.
- WorkspaceView osserva DesignModel e ProjectLibrary tramite Environment e
  possiede WorkspaceState/ViewportState. La Home è lavoro concorrente di Claude:
  lettura dello stato mappata, navigazione e I/O non integralmente attraversati.
- Nessun arco di ereditarietà nel dataset. Le conformità mappate sono state
  ricontrollate; `ThreeMFExportProfile: String` è un raw value, non una superclass.
  Nessuna catena Combine (`import Combine`, `sink`, `assign`) trovata nei sorgenti.
- `view.delegate = renderer` e `MTKViewDelegate.draw` collegano registrazione e
  callback; AppKit/Metal sono confini runtime. Non costituiscono chiamate dirette
  continue attraverso Objective-C/GPU. Nessun kernel C/C++ aggiunto.
- Confini HTTP OpenAI/Anthropic, tunnel, GPU e disco marcati esterni/inferiti.
  Nessuna connessione remota o correttezza numerica viene provata dagli archi.
- Le API pubbliche/testate senza chiamanti UI non sono considerate codice morto.
- Campione casuale riproducibile (seed 70): E027, `Mesh.vertices: [Vec3]`,
  verificato come `references_symbol` SYNTACTIC, non chiamata né ereditarietà.

## Verifiche separate dal grafo

- CADCore: 19 test Swift Testing passati, incluso corpus di 80 profili semplici;
  incidenza, volume, ID e mappe dello snapshot verificati separatamente dal grafo.
- Strumenti CAD/Model: 50 verifiche su geometria, revisioni, undo/redo, colore,
  3MF e snapshot, invalidazione cache e geometrie invalide/ID duplicati.
- Provider OpenAI: 23 verifiche offline, comprese chiamate incomplete, errori,
  tool results, continuità e cifratura opaca dello stato di ragionamento.
- MCP: 15 verifiche con vero HTTP loopback e Model isolato, inclusi creazione,
  volume, undo, conflitto di revisione, autenticazione, Origin e 3MF.
- Connettore: 3 test Python; archivio 3MF verificato con parser ZIP/XML indipendente.
- Xcode: build app riuscita. Nessuna chiamata ai provider remoti in queste prove.
- Interfaccia del grafo: pagina locale ricaricata, 63 nodi/86 archi visibili;
  ricerca BodySnapshot verificata (4 relazioni). Coerenza HTML/JSON/Mermaid
  verificata dal generatore.
- Comando unico: `scripts/ci.sh`. Log della consegna: `build/ci/run.ZUUwHC/`.

Il completamento dei task è nel registro e nel grafo attività, non in questa
mappa. Nessuna prova fisica di stampa/lamiera, completa implementazione assiemi,
funzionalità dello storico parametrico, pubblicazione TestFlight o disponibilità
degli account remoti è implicita.
