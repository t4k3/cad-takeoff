# Spec — T112 follow-up: i18n pulita (it/en/zh-Hans) + Home in stile Pixelmator

Stato: **in attesa di approvazione** (nessuna modifica al codice prima dell'ok).
Task di riferimento: `T112` (già `done`, riaperto come follow-up). Proprietario: claude.
Vincoli: `docs/UX_RULES.md` §5 (lingua UI italiana di default) e §6; `AGENTS.md` (unità mm,
Z↑, core senza UI, build/test obbligatori).

## 1. Problema osservato (prove)

L'app in cinese mostra ancora italiano in punti visibili:

| Punto | File / riga | Causa |
|---|---|---|
| Titolo finestra «Senza titolo — modificato» | `App/Sources/UI/FusionTakeoffApp.swift:23-25` | `navigationTitle(String)` + suffisso `" — modificato"` costruito a runtime |
| Avviso di salvataggio tutto italiano | `App/Sources/Integration/Projects/ProjectLibrary.swift:482-486` | `NSAlert` con `String` non localizzate |
| Errore libreria «Esiste già…» | `ProjectLibrary.swift:499` | `LocalizedError.errorDescription` non localizzata |
| Nome predefinito «Senza titolo» / «Senza nome» / « copia » | `ProjectLibrary.swift:224,234,514,194` | `String` restituite al Model/UI |
| «GUSCIO» nel pannello comando | `App/Sources/UI/Command/CommandPanel.swift:13` | `session.title.uppercased()` impedisce la lookup della chiave |
| Etichette/opzioni/help del pannello comando | `CommandPanel.swift:27-28,71,77,83,92,99,109,116,162,169` | `String` (`f.label`, `f.help`, `options[i]`, messaggi) passate a `Text`/`Toggle`/`Picker` |
| «non scelta», «Il mio progetto», interpolazioni Home | `App/Sources/UI/Home/HomeView.swift:81,181,138,218` | literal mancanti nel catalog o concatenazioni |
| Messaggi di stato/hint (barra di stato, viewport, schizzo, circuiti) | `WorkspaceState.swift:130-340`, `StatusBar.swift:13`, `ViewportContainer.swift`, `Sketch/SketchSession*`, `Electronics/CircuitWorkspace.swift`, `Drawing/DrawingWindow.swift`, `Model/DesignModel.swift`, `Model/Electronics/CircuitModel.swift` | `String` assegnate a runtime e mostrate senza lookup |
| Etichette/campi dei comandi (LAMIERA, FORO, RACCORDO, SERIE, …) | `App/Sources/UI/Features/*.swift` (es. `ShellCommand.swift:36-37,52-55,60-64,87-89`; `SheetMetalCommand.swift:69-116`; `HoleCommand.swift`; `ChamferCommand.swift`) | literal `label:`/`help:`/`note` in italiano, molte chiavi assenti |
| Home densa (sidebar + header + griglia) | `App/Sources/UI/Home/HomeView.swift` | layout non in stile Pixelmator Pro |

Catalog attuale: `App/Resources/Localizable.xcstrings`, 771 chiavi, `sourceLanguage = it`,
tutte con `en` + `zh-Hans`; alcune chiavi interpolate (`%@`, `%lld`) già presenti.
`project.yml` ha `developmentLanguage: it` e `SWIFT_EMIT_LOC_STRINGS=YES`.

## 2. Decisioni di progetto

1. **Chiavi = stringhe italiane** (come già deciso in `docs/COLLAB.md`, 2026-10-30 22:10).
   Nessuna migrazione a chiavi semantiche (`action.*`): non richiesta e rischiosa ora.
2. **Localizzare alla sorgente i valori `String`** con `String(localized:)` (con interpolazione
   → chiave `%@`/`%lld`). Nei view, usare `LocalizedStringKey` solo per literal statiche.
   Non introdurre wrapper runtime (`NSLocalizedString` su stringhe già formattate) perché non
   risolverebbe le interpolazioni.
3. **Nessuna duplicazione di tabelle**: il catalog resta l'unica fonte; le stringhe dinamiche
   composte (es. `"Modifica \(name)"`) diventano chiavi interpolate (`"Modifica %@"`).
4. **Plurali**: dove oggi il codice distingue già singolare/plurale, mantenere la scelta esplicita
   e aggiungere le due chiavi; non introdurre `plural variations` nel JSON (fragili da scrivere a mano).
5. **Default runtime = italiano** (`it`), ma ogni chiave nuova ha `en` e `zh-Hans` tradotte.
6. **Fuori scope dichiarato**: descrizioni degli strumenti MCP/assistente e messaggi diagnostici
   di `Integration/Assistant`, `Model/Tools/CADToolCatalog.swift`, `CircuitModel+Tools.swift`
   (non sono UI: servono ai modelli AI). Se restano, va scritto in `docs/DA_PROVARE.md` e in
   `docs/COLLAB.md` come limite esplicito.
7. **Home**: eliminare la sidebar rigida; layout a due zone in stile Pixelmator Pro —
   colonna sinistra «welcome» (icona app, nome, versione, azioni capsule a larghezza piena,
   selettore progetti) e destra contenuti (toolbar unificata con breadcrumb + ricerca, griglia
   recenti/libreria, stato vuoto). Tutte le funzioni esistenti restano accessibili
   (nuovo pezzo/circuito, nuova cartella, rinomina/duplica/mostra nel Finder/Cestino, ricerca,
   scelta cartella, import mesh, add-in Fusion). Stesso `Theme` Liquid Glass, nessun nuovo colore.

## 3. Modifiche puntuali

### 3.1 App shell e libreria
- `FusionTakeoffApp.swift`
  - titolo: `library.currentName` + `String(localized: " — modificato")` (idem per circuito).
  - menu/azioni già in `Text`/`Button` literal: restano (catalog esistente).
  - «Informazioni»: crediti con `String(localized:)` per «Commit %@ · compilata il %@».
- `Integration/Projects/ProjectLibrary.swift`
  - `currentName`, `Tab.name` → `String(localized: "Senza titolo")`.
  - `duplicate` → `String(localized: " copia")`.
  - `chooseRoot` → `panel.prompt`/`panel.message` con `String(localized:)`.
  - `newDesign`/`newCircuit` → `String(localized: "Nuovo disegno.%@")` / `"Nuovo circuito.%@"`.
  - `openCircuit`/`open` → `lastError` e `statusMessage` con `String(localized:)`.
  - `write` → `statusMessage = String(localized: "Salvato %@")`.
  - `confirmDiscard` → messaggio/informativo/bottoni con `String(localized:)`.
  - `LibraryError.exists` → `String(localized: "Esiste già un elemento chiamato «%@».")`.
  - `clean` → `String(localized: "Senza nome")`.

### 3.2 Pannello comando
- `CommandPanel.swift`
  - titolo: `Text(LocalizedStringKey(session.title))` **senza** `.uppercased()`; stile: `.smallCaps()`.
  - `f.label`, `f.help`, `f.validationMessage`, `session.message`, `prompt`, opzioni:
    `Text(LocalizedStringKey(...))` per statiche; per messaggi interpolati usare
    `String(localized:)` alla sorgente (in `CommandField.validationMessage`).
  - riferimento: `Text(refs.isEmpty ? LocalizedStringKey(prompt) : "\(refs.count) selezionat\(…)" )`
    → chiavi `"%lld selezionati"` / `"%lld selezionato"`.
  - `ExpressionDimensionField.report` → `String(localized: "%@: %@")`.
- `CommandSession.swift` → `validationMessage` con `String(localized:)` e chiavi `%@`/`%lld`.
- `UI/Features/*.swift` → `label:`, `help:`, note, titoli `"Modifica %@"`/`"Posiziona %@"`,
  opzioni `.choice([...])` con `String(localized:)`; aggiungere chiavi mancanti.
- `UI/Command/FeatureCommands.swift` → etichette e help (`Posizione X/Y/Z`, `Rotazione X/Y/Z`,
  `Estensione`, `Sformo`, `Verso opposto`, `Operazione`, opzioni booleane).

### 3.3 Messaggi di stato e hint
- `StatusBar.swift`: `Text(circuits.message)` → `Text(LocalizedStringKey(circuits.message))`
  per statiche; messaggi interpolati localizzati alla sorgente.
- `WorkspaceState.swift`, `UI/Sketch/*`, `UI/Viewport/ViewportContainer.swift`,
  `UI/Drawing/DrawingWindow.swift`, `UI/Electronics/CircuitWorkspace.swift`,
  `Model/DesignModel.swift`, `Model/Electronics/CircuitModel.swift`:
  ogni assegnazione `statusMessage/message/hint = "…"` passa a `String(localized:)`
  (interpolazioni → `%@`/`%lld`).
- Non toccare i valori che sono dati tecnici (unità `mm`, sigle, percorsi file).

### 3.4 Catalog
- Aggiungere tutte le chiavi nuove (stima 250–350) con `en` e `zh-Hans`, stato `translated`.
- Validazione: stesse specifiche di formato (`%@`, `%lld`, posizionali quando ripetuti) fra
  sorgente e traduzioni; nessuna chiave senza traduzioni; nessun placeholder perso.

### 3.5 Home stile Pixelmator
- `HomeView.swift` riscritta:
  - `HStack(spacing: 0)` con colonna sinistra `frame(width: 300)` e destra contenuti.
  - Colonna sinistra: `Image(nsImage: NSApp.applicationIconImage)` 96×96,
    `Text("CAD Takeoff")` 20 semibold, `Text("Versione %@")` caption,
    4 pulsanti capsule a larghezza piena (`Nuovo disegno`, `Nuovo progetto`, `Apri…`,
    `Scegli cartella…`), `Menu` overflow per import/ad-in/cambio cartella,
    selettore «Progetti» (Recenti + progetti, menu contestuale).
  - Destra: header toolbar-like con breadcrumb + `TextField("Cerca pezzi e circuiti")`,
    azioni `Nuova cartella`/`Nuovo`; griglia `ItemCard` esistente (o semplificata) con
    anteprima, nome, data relativa; `ContentUnavailableView` per ricerca vuota/nessun progetto.
  - Rimuovere sidebar, `Divider` verticale e footer duplicato; mantenere alert rinomina/creazione.
  - Ogni stringa nuova/visibile localizzata; nessuna nuova immagine esterna.

## 4. Verifica (obbligatoria prima di dichiarare finito)

1. `xcodegen generate` (se cambia `project.yml`; qui non previsto).
2. `scripts/build.sh` con firma disattivata:
   `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → BUILD SUCCEEDED.
3. `swift test --package-path Packages/CADCore` → 205+ test PASS.
4. Script di audit (temporaneo fuori repo): tutte le chiavi del catalog hanno `en` e `zh-Hans`;
   parità placeholder (`%@`, `%lld`, `%1$@`); zero literal UI italiane non localizzate nei file
   toccati; zero `Text(String)` per etichette utente.
5. QA visiva in `docs/DA_PROVARE.md`: avvio in cinese, aprire comando Guscio/Foro/Lamiera,
   salvare un disegno modificato, vedere Home; controllo titolo finestra, dialog, etichette,
   messaggi, stato vuoto.
6. `python3 scripts/graph.py done T112 --note "…"` e voce in `docs/COLLAB.md`.

## 5. Rischi e mitigazioni

- **Interpolazioni**: una traduzione con placeholder sbagliato fa crash/lookup mancata →
  validazione automatica di parità placeholder + prova runtime.
- **`String(localized:)` in codice non-UI** (Model): il core non deve importare SwiftUI; è
  Foundation → ammesso. Nessuna dipendenza UI.
- **Test esistenti** che confrontano stringhe di stato: verificare `Tools`/assistant test;
  se asseriscono literal italiani, aggiornarli solo se il test è UI-facing (altrimenti lasciare).
- **Home**: mantenere accessibilità (label VoiceOver) e scorciatoie ⌘N/⌘O/⇧⌘H invariate.
