# Tasks — T112 follow-up: i18n pulita + Home stile Pixelmator

Legenda stato: `[ ]` da fare · `[~]` in corso · `[x]` fatto. Un solo task `[~]` alla volta.
Ogni task si chiude con build/test verdi e diff limitato ai percorsi indicati.

## Blocco A — Fondamenta i18n (App shell, libreria)
- [x] **A1. Titolo finestra e menu app** — `App/Sources/UI/FusionTakeoffApp.swift`
  - `navigationTitle`: `String(localized: " — modificato")` per disegno e circuito.
  - crediti pannello Informazioni: `String(localized: "Commit %@ · compilata il %@")`.
  - Chiavi nuove nel catalog: ` — modificato`, `Commit %@ · compilata il %@`.
- [x] **A2. ProjectLibrary** — `App/Sources/Integration/Projects/ProjectLibrary.swift`
  - `currentName`, `Tab.name`, `duplicate` (« copia»), `chooseRoot`, `newDesign`/`newCircuit`,
    `openCircuit`, `open`, `write`, `confirmDiscard` (NSAlert), `LibraryError.exists`, `clean`.
  - Tutte le stringhe via `String(localized:)`; interpolazioni → chiavi `%@`.
- [x] **A3. Barra di stato** — `App/Sources/UI/Workspace/StatusBar.swift`
  - `circuits.message` → `LocalizedStringKey`; etichette circuito con chiavi `%lld` e plurali
    espliciti (componente/componenti, lotto/lotti, errore/errori, avviso/avvisi).

## Blocco B — Pannello comando e campi
- [x] **B1. CommandPanel** — `App/Sources/UI/Command/CommandPanel.swift`
  - titolo senza `uppercased()`; label/help/note/opzioni/prompt/messaggi localizzati.
  - selezione riferimento: chiavi `%lld selezionato` / `%lld selezionati`.
- [x] **B2. CommandField/CommandSession** — `App/Sources/UI/Command/CommandSession.swift`
  - `validationMessage` con `String(localized:)` (`Valore tra %@ e %@`, `Selezione richiesta`).
- [x] **B3. FeatureCommands** — `App/Sources/UI/Command/FeatureCommands.swift`
  - etichette/help/opzioni (`Posizione/Rotazione`, `Estensione`, `Sformo`, `Operazione`).
- [x] **B4. Comandi feature** — `App/Sources/UI/Features/*.swift`
  - `label:`, `help:`, note, `.choice([...])`, titoli `Modifica %@`/`Posiziona %@`.
  - File: Shell, Hole, Chamfer, SheetMetal, Pattern, Thread, Split, Combine, Move,
    PressPull, Joint, Explode.
- [x] **B5. Schizzo** — `App/Sources/UI/Sketch/{SketchCommands,SketchSession,SketchSession+Edit,SketchSession+Constraints,SketchInspector}.swift`
  - label/help/note/hint e messaggi di stato via `String(localized:)`.

## Blocco C — Messaggi visibili (viewport, disegno, circuiti, modello)
- [x] **C1. Viewport e tavola** — `UI/Viewport/ViewportContainer.swift`,
  `UI/Drawing/DrawingWindow.swift` (hint, misurazioni, didascalie quota, errori).
- [x] **C2. Workspace** — `App/Sources/UI/Workspace/WorkspaceState.swift` (5 messaggi).
- [x] **C3. DesignModel** — `App/Sources/Model/DesignModel.swift` (status di salvataggio,
  apertura, export, BOM, import; interpolazioni → `%@`/`%lld`).
- [x] **C4. CircuitModel** — `App/Sources/Model/Electronics/CircuitModel.swift`
  (apertura/salvataggio/alert modifiche/export JLC; interpolazioni → `%@`).
- [x] **C5. CircuitWorkspace e schede elettroniche** — `UI/Electronics/CircuitWorkspace.swift`,
  `LibraryImportSheet.swift`, `FabricationSheet.swift`, `ManufacturingViews.swift`,
  `Assembly2D.swift`, `CAMDrawing.swift`, `CircuitSchematicView.swift`:
  solo stringhe UI visibili, non i nomi tecnici di strati/rete.

## Blocco D — Catalog
- [x] **D1. Raccolta chiavi nuove** — script temporaneo fuori repo (`/tmp`) elenca le chiavi usate
  da `LocalizedStringKey`/`String(localized:)` assenti dal catalog.
- [x] **D2. Traduzioni en + zh-Hans** — batch paralleli (3 agenti) su file JSON in `/tmp`;
  merge con validazione placeholder e stato `translated`.
- [x] **D3. Validazione** — nessuna chiave senza traduzioni, parità `%@`/`%lld`/posizionali,
  JSON valido, `sourceLanguage` invariato `it`.

## Blocco E — Home Pixelmator
- [x] **E1. Riscrittura HomeView** — `App/Sources/UI/Home/HomeView.swift`
  - colonna sinistra 300 pt (icona app, nome, versione, 4 capsule, overflow, selettore progetti).
  - destra: header breadcrumb+ricerca, griglia o empty state, contesti e alert invariati.
  - tutte le stringhe localizzate; nessuna funzione persa; Liquid Glass coerente.
- [x] **E2. Rifinitura stile** — spaziature, tipografia, hover, scuro/chiaro; verifica con
  scala 13" e finestra minima 1100×700.

## Blocco F — Chiusura
- [x] **F1. Audit finale** — grep dei literal italiani non localizzati in `App/Sources/UI`,
  `App/Sources/Integration/Projects`; zero casi; elenco residui fuori scope in DA_PROVARE.
- [x] **F2. Build** — `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` PASS.
- [x] **F3. Test** — `swift test --package-path Packages/CADCore` PASS (205+).
- [x] **F4. Documentazione** — `docs/DA_PROVARE.md` (prova in cinese: titolo, alert, Guscio,
  Home); `docs/COLLAB.md` (NOTA/DONE); eventuale aggiornamento della DECISIONE i18n.
- [x] **F5. Commit** — `[T112] i18n pulita … Home stile Pixelmator`; solo percorsi del task
  (`App/Sources/UI`, `App/Sources/Integration/Projects`, `App/Sources/Model` solo per i
  messaggi di stato, `App/Resources/Localizable.xcstrings`, `docs/…`).

## Criteri di accettazione
1. In cinese e in inglese non resta **nessun** testo italiano visibile nei percorsi UI
   dichiarati (titolo, menu, alert, pannello comando, barra di stato, hint, Home).
2. Tutte le nuove chiavi hanno `en` e `zh-Hans`, con placeholder coerenti.
3. Home ha layout a due zone in stile Pixelmator, senza sidebar rigida, tutte le azioni presenti.
4. Build app e test CADCore verdi; audit automatico verde; QA visiva documentata.
5. Fuori scope (assistente/MCP/diagnostica AI) dichiarato esplicitamente, non silenzioso.
