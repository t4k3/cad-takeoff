# Contratto UX ↔ funzionalità

Responsabilità confermate dall'utente e accettate da entrambi gli agenti:

| Area | Responsabile | Interfaccia di collaborazione |
|---|---|---|
| `App/Sources/UI/**`, viewport e rendering | Claude | Legge lo stato del Model, invoca i suoi comandi |
| `App/Sources/Model/**` | Codex | Espone stato osservabile e comandi; gestisce errori e cronologia |
| `Packages/CADCore/**`, test, CI | Codex | Tipi geometrici, operazioni e formato dati indipendenti dalla UI |
| Build, configurazione, documenti, release | Concordato per task | Claim esclusivo e registro condiviso |

Questo file descrive il contratto; **non dichiara implementate API future**.
Le firme attuali sono nel sorgente e nel dataset della mappa.

## Estensione fondamentale R7–R9 · 25 settembre 2026

Requisiti di Ross: [storico, parti/assiemi e lamiera](../requirements/CAD_SCOPE_V2.md).
Contratto dettagliato concordato con Claude, incluso il modello schizzo:
[UX / Core revisione 2](../requirements/UX_CORE_CONTRACT.md).

- **R7 — storico:** snapshot della timeline con `FeatureID`, componente,
  dipendenze, parametri, stato e diagnostica; comandi edit/suppress/reorder/rollback
  separati da undo/redo. Tutto deve sopravvivere a salvataggio e riapertura.
- **R8 — parti/assiemi:** `ComponentID` per la definizione, `OccurrenceID` e percorso
  d'istanza per la selezione; trasformazioni, contesto attivo, giunti e DOF. La
  firma iniziale basata solo su `Feature.ID` non basta per distinguere istanze.
- **R9 — lamiera:** regole versionate e override, operazioni di piega/flangia,
  unfold/refold e flat pattern distinti; risultati con revisione sorgente,
  diagnostica e stato obsoleto esplicito, export DXF/tavola controllato.

Estensione a R3/R6: i RenderItem dovranno identificare occorrenza, corpo, revisione
e mappa di selezione topologica. Gli indici dei triangoli nei report sono validi
solo per lo snapshot indicato; non sono identificatori persistenti delle facce.

Le firme definitive si concordano prima dell'implementazione. Per il futuro
kernel, preview/rebuild possono essere asincroni e annullabili: pubblicazione
atomica nel Model solo se la revisione è ancora attuale. La precedente proposta
«tutto sincrono su MainActor» riguarda le API semplici, non obbliga i calcoli CAD
complessi a bloccare la UX.

## API della base T00/T16

`DesignModel` è `@MainActor` e `@Observable`; espone `document`, `selection`,
`selectedIndex` e `statusMessage`, oltre ai comandi `addBox()`, `addCylinder()`,
`addHexPrism()`, `deleteSelected()`, `newDesign()`, `saveWithPanel()`,
`openWithPanel()` ed `exportSTLWithPanel()`.

Nella base iniziale l'inspector modifica ancora proprietà mediante Binding.
La migrazione ai comandi del Model è parte dell'evoluzione undo/redo e validazione:
Claude non deve introdurre nuove scritture dirette dove esiste già un comando.

`CADCore` espone `Vec2`, `Vec3`, `Mesh`, `Profile2D`, `Primitives`, `Operations`,
`Feature`, `CADDocument`, `STLExporter` e `MeshValidator`.
La mesh attiva usa `vertices: [Vec3]` e `indices: [UInt32]`; i tre indici consecutivi
definiscono un triangolo. Z è verticale e le coordinate sono millimetri.

## Richiesta di nuova API

Claude registra in `COLLAB.md` una voce `RICHIESTA-API` con:

- gesto o bisogno UX e task che lo richiede;
- firma Swift proposta, unità, valori opzionali e comportamento degli errori;
- chiamata su MainActor o operazione asincrona, se necessaria;
- prova di accettazione attesa dalla UI.

Codex risponde con accettazione o firma alternativa, prende il task funzionale,
implementa e verifica prima di dichiarare pronta l'API. Claude può usare mock
soltanto in `App/Sources/UI/Previews/`; il mock non vale come implementazione.
Il produttore segnala quando la firma è stabile; il consumatore conferma
l'integrazione e la verifica UX. Nessun agente assume che un messaggio sia letto
solo perché è presente nel file.

## Evoluzioni da concordare

- Comandi di editing validati e annullabili in luogo di Binding diretti al documento.
- Errori strutturati senza aggiornamenti parziali del design.
- Snapshot delle mesh per il renderer, mantenendo la geometria fuori dalla UI.
- Controllo delle versioni del documento e import atomico.
- Esportazione verificata prima della scrittura; il report non deve dichiarare
  stampabilità generale a partire dal solo conteggio dei bordi.

Questi punti hanno valore di requisiti; non aggiungono overload né promesse di
compatibilità alle API attualmente implementate.

## R10 — Assistente e MCP (T47–T55)

`DesignModel: CADToolProvider` espone il catalogo condiviso (mm, Z-up), risultati
strutturati, feature interessate e token di revisione. Mutazioni con
`expected_revision`, validation-before-commit e undo di sessione.
`AssistantProvider` isola i formati Anthropic e OpenAI dalla UX.
Il [contratto completo](../requirements/AI_ASSISTANT.md) distingue queste API
dallo storico parametrico persistente pianificato in T29.

## Stampa a colori — API T59

`PartColor(red: UInt8, green: UInt8, blue: UInt8)`, `init?(hex: String)` (`#RRGGBB`),
`.hex` e `.defaultColor`. `Feature.color` viene codificato nel `.ftk`; i file
precedenti senza questo campo ricevono il valore predefinito.

`DesignModel.setFeatureColor(_ id: UUID, color: PartColor) throws` esegue una
transazione con revisione e undo condiviso con gli strumenti dell'assistente.
Il selettore UI converte il colore in **sRGB** a 8 bit, senza alpha, e usa questo
comando; non scrive direttamente in `document.features[i].color`.

`export3MFData(featureID: UUID? = nil) throws -> Data` e `export3MFWithPanel()`
esportano le parti visibili (o quella identificata) con nomi, colori e posizioni.
Il core espone `ThreeMFPart`, `ThreeMFExporter.archive(parts:profile:)` e
`ThreeMFExportProfile.standard / .bambuOrca` (predefinito, anche Snapmaker Orca).
Il profilo di compatibilità aggiunge solo nomi/indici delle parti e palette colore;
la stampante e i parametri di stampa vengono scelti nello slicer.

Catalogo condiviso chat/MCP: 14 strumenti, inclusi `set_color` ed `export_3mf`.
Dettagli e prove: [stampa 3MF](../requirements/PRINT_3MF.md).
