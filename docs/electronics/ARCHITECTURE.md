# Elettronica Fusion Takeoff — contratto E0–E3

27 settembre 2026 · T91/T92/T93/T94 · Codex · richiesta di Ross: EDA proprietario, componenti JLCPCB, assemblaggio produttivo e meccanico 3D.

## Decisione e confini

Il prodotto deve unire **schema → PCB → fabbricazione/assemblaggio → assieme meccanico** nello stesso progetto, con assistente capace di eseguire gli stessi comandi del progettista. Il motore sarà nostro. I cataloghi di componenti sono dati interoperabili, distinti dalle librerie software: consultarli o importarli non richiede incorporare un motore esterno.

`Packages/ElectronicsCore` è un package Swift 6 per macOS 27+, con Foundation, libreria standard e CryptoKit Apple, **zero dipendenze software esterne**, nessun import UI/CADCore. Il requisito macOS 27 segue la decisione di Ross del 27/09/2026. Si può aprire direttamente in Xcode. Il package è compilabile e verificabile; Claude ha collegato il modulo all’app in T99. Le viste e il ponte app restano di Claude.

Codex possiede il core elettronico, i formati, i controlli e il contratto funzionale. Claude ha confermato lettura e accordo nel registro del 27/09 alle 09:49: possiede CAD, app, UX elettronica T97, aggancio T99, strumenti MCP T100 e adattatore CAD T101. `AGENTS.md` e `docs/UX_RULES.md` regolano la collaborazione. La revisione obiettiva separa evidenze automatiche, prove nell’app, accettazione del produttore e scheda fisica.

## API implementate

| Tipo/API | Contratto |
|---|---|
| `LibraryRevision` | UUID stabile + revisione positiva; i nomi non sono chiavi. |
| `SymbolDefinition` | Pin logici con identità, numero, tipo elettrico e geometria opzionale; primitive grafiche e proprietà importate in E1. Editor e schema completo sono E2. |
| `FootprintDefinition` | Piazzole rettangolari/circolari/ovali/arrotondate, foro passante opzionale, centro di presa, riferimento modello 3D, provenienza e primitive grafiche. |
| `DeviceDefinition` | Simbolo e impronta in revisioni esatte, mappatura esplicita pin→piazzole, produttore/MPN e identificativo JLC opzionale. |
| `ElectronicsLibrary` | Snapshot incluso nel documento: riaprire non dipende da cataloghi online aggiornati. |
| `ElectronicsDesign` | Componenti, reti, collegamenti/NC espliciti, contorno scheda, posizionamenti e varianti di montaggio. |
| `ElectronicsDocument` | Scrittura formato 6, lettura 1–6; schema e rame opzionali, classi di rete, aree vietate e piani, revisione monotona, modifiche atomiche con `expectedRevision`, storico undo/redo salvato e verificato al caricamento. |
| `ElectronicsValidation.integrity` | Identità duplicate, riferimenti/revisioni mancanti, pin-map, contorno semplice, quote/angoli finiti, piazzole e fori coerenti. |
| `ElectronicsValidation.electrical` | Prime verifiche: pin senza connessione/NC, pin NC collegati, uscite multiple sulla rete. Non è ERC completo. |
| `ElectronicsConnectivity.snapshot` | Piazzole in coordinate PCB con rete associata; collegamenti ancora da sbrogliare fra isole fisiche, deterministici tramite albero minimo; piste/via provengono dai comandi PCB. |
| `ElectronicsPCB`, `PCBCommand` | Piste, via passanti, strati, DRC, snapshot/pick/snap e anteprima transazionale: [PCB.md](PCB.md). |
| `PCBZone`, `PCBZoneFill` | Piani a collegamento pieno, riempimento poligonale nativo, clearance e isole fisicamente connesse; contorni persistiti, rame ricalcolato: [PCB_ZONES.md](PCB_ZONES.md). |
| `ElectronicsAssembly.export` | BOM/CPL JLC, istanze meccaniche e collegamenti; un’unica selezione di variante. Errori bloccanti prima di produrre risultati. |
| `ElectronicsLibraryCommands` | Importazione e creazione dispositivo tipizzate, anteprima su copia e conferma atomica. Stesse API per app/chat/MCP. |
| `KiCadLibraryImporter`, `EasyEDAStandardImporter` | Importatori proprietari con sottoinsiemi espliciti, provenienza, SHA-256 e report. Vedere [LIBRARIES.md](LIBRARIES.md). |
| `ComponentCatalogImporter`, `SupplierCatalogSnapshot` | CSV configurabile, snapshot offline validato, ricerca e legame produttore/MPN/codice fornitore. Nessuna disponibilità live implicita. |

Il codice è in `Models.swift`, `Geometry.swift`, `Validation.swift`, `Document.swift`, `Connectivity.swift`, `Assembly.swift`. Non copiare logica di pin-map, trasformazioni o selezione varianti nella UI o negli strumenti MCP.

### Revisioni e storico

Una modifica geometrica/elettrica a un elemento di libreria richiede una nuova revisione. Le istanze esistenti restano ancorate a quella precedente; un aggiornamento deve essere un comando esplicito con anteprima delle differenze. Le modifiche con revisione obsoleta o riferimenti non validi falliscono senza alterare il documento. Undo incrementa il contatore: tornare a un vecchio contenuto non rende valida una vecchia richiesta dell’assistente.

E0 salva snapshot prima/dopo ogni modifica, compresi undo e redo dopo riapertura; non è ancora una timeline grafica. È una soluzione iniziale verificabile: prima di grandi progetti occorrono comandi/diff compatti, checkpoint, limiti di memoria e benchmark. Lettura statica via `decode` limitata a 64 MiB. La validazione della libreria confronta anche gli stati storici e impedisce cambiamenti retroattivi della medesima revisione presente nello storico.

### Coordinate PCB e meccanica

- Millimetri, X/Y nel piano scheda, Z verso l’alto; scheda compresa fra Z=0 e Z=spessore.
- Rotazione del posizionamento positiva antioraria vista dall’alto, per entrambi i lati.
- Lato inferiore: impronta riflessa sull’asse locale X, poi rotazione nel sistema comune. Modello 3D trasformato con `Rz(angolo) × Ry(180°)`; determinante +1, normali non invertite.
- Centro di presa specificato nella libreria: non coincide necessariamente con l’origine o il centro geometrico dell’impronta.
- CPL: centro trasformato meno origine di assemblaggio. Rotazione convertita da una regola esplicita per dispositivo e lato, con evidenza della calibrazione. Regola mancante → export bloccato.
- Matrice 3D 4×4 in ordine di righe, vettori colonna. Il modello deve essere normalizzato in mm, piano di montaggio Z=0, corpo verso +Z; E0 applica solo l’offset e il posizionamento dichiarati.
- Asset 3D: percorso relativo e hash registrati; il core **non legge il file e non verifica ancora l’hash né l’ingombro reale**. Risoluzione sicura, verifica bytes e import geometrico competono all’adattatore E5. Non risolvere percorsi tramite la directory corrente o oltre la radice del progetto, inclusi symlink.

Le quote sono `Double` in mm, con rifiuto di NaN, infiniti e coordinate oltre ±100.000 mm. Il PCB usa nuclei convessi con raggio analitico per distanze del rame, BVH per i candidati, tolleranza numerica di contatto 1e-8 mm. Questa non è una tolleranza produttiva certificata. Vedere [PCB.md](PCB.md) per copertura e limiti.

### BOM, CPL e varianti

`jlcpcb`, `manual` e `doNotPopulate` sono scelte distinte. Una variante può escludere ulteriori componenti. JLC BOM/CPL includono gli stessi componenti; il modello meccanico comprende anche il montaggio manuale. DNP e varianti non eliminano le piazzole dal PCB.

La distinta aggrega solo dispositivo/revisione, valore, impronta e codice fornitore coincidenti. Il CSV usa quoting e separatori decimali indipendenti dalla lingua del Mac. La mancanza di posizione, identificativo JLC o calibrazione del lato richiesto blocca l’export, senza saltare righe. Codice componente e provenienza non attestano disponibilità attuale: stock, prezzo e stato di assemblabilità devono essere acquisiti separatamente, con timestamp, tramite l’adattatore catalogo.

`AssemblyData.fabricationReady` è sempre `false` in E0. BOM/CPL corretti sintatticamente non certificano orientamento nel viewer JLC, routabilità, distanze, polarità reale o file Gerber. Il rilascio produttivo E4 unirà le prove alla revisione esatta di documento, librerie, profilo fornitore e file esportati.

## Verifica riproducibile

```sh
bash scripts/test-electronics.sh
swift test --package-path Packages/CADCore
```

Il primo comando esegue i test Swift, legge il documento di prova con il programma `electronics-check`, esporta in una cartella nuova sotto `build/electronics/` e verifica CSV/JSON con un lettore Python indipendente. I fixture usano MPN, codici JLC, calibrazioni e hash **sintetici: non ordinare questi componenti**. La verifica indipendente controlla BOM↔CPL, quoting, DNP/manuali, centri, angoli, basi ortonormali e determinante delle matrici 3D.

Esempio di contratto applicativo:

```swift
var document = try ElectronicsDocument.decode(data)
try document.edit(title: "Sposta componente", expectedRevision: document.revision) {
    $0.board.placements[0].position = PCBPoint(25, 10)
}
let board = try ElectronicsConnectivity.snapshot(document.design)
let assembly = try ElectronicsAssembly.export(document)
let saved = try document.encoded()
```

L’adattatore UI dovrà usare identità, non indici, per individuare l’oggetto scelto; l’indice nell’esempio è solo una chiamata minima. Il catalogo di comandi tipizzati E2 dovrà servire UI e MCP con le stesse transazioni. L’undo del futuro assistente dovrà rispettare le modifiche successive dell’utente, come nel contratto CAD esistente.

## Aggancio concordato con Claude, da implementare/verificare nell’app

1. Collegamento del documento elettronico al progetto/Home senza migrazioni implicite del `.ftk` CAD.
2. Workspace coordinati Libreria, Schema, PCB, Assieme e Preparazione produzione; selezione incrociata su UUID.
3. Visualizzazione di revisioni, errori con soggetto selezionabile, reti ancora da sbrogliare e stato dei dati fornitore.
4. Adapter CAD per la scheda e i modelli, con aggiornamenti revisionati e nessuna duplicazione delle trasformazioni.
5. `bash scripts/test-electronics.sh` è collegato alla CI globale da Claude (T99); comprende test Swift e cinque lettori Python indipendenti per assemblaggio, import librerie, schema, PCB/regole e piani. La prova del ponte app resta in `scripts/test-circuits.sh`.

## Fonti studiate e scelte nostre

Consultate il 27/09/2026; nessun codice delle implementazioni esterne copiato o collegato.

- [Autodesk: documento Electronics](https://help.autodesk.com/view/fusion360/ENU/?contextId=LP-READ-P13N-SNP-GS-ECD-CRD-6): riferimento di copertura per sincronizzare schema, PCB 2D e PCB 3D. Non vincola il nostro formato o la UX.
- [LibrePCB: concetto delle librerie](https://librepcb.org/features/library-concept/): identità stabili e separazione fra simboli, segnali e impronte. La nostra prima API adotta snapshot revisionati e mappatura esplicita; grafica simboli e varianti package più articolate sono successive.
- [KiCad: formati documentati](https://dev-docs.kicad.org/en/file-formats/) e [S-expression](https://dev-docs.kicad.org/en/file-formats/sexpr-intro/): base per i lettori nostri E1, con errori sui costrutti non rappresentabili. Copertura e fonti EasyEDA in [LIBRARIES.md](LIBRARIES.md).
- [KiCad: architettura PNS router](https://docs.kicad.org/doxygen/classPNS_1_1ROUTER.html) e [replay di test](https://dev-docs.kicad.org/en/components/testing/index.html): riferimento per separare stato del routing, regole, interazione e commit; registrare casi riproducibili prima di implementare push/shove nostro.
- [JLCPCB: campi BOM](https://jlcpcb.com/help/article/how-to-generate-the-bom-and-centroid-file-from-kicad), [CPL](https://jlcpcb.com/help/article/pick-place-file-for-pcb-assembly), [coerenza BOM/CPL](https://jlcpcb.com/help/article/advice-for-bom-and-cpl-files-preparation): campi, unità e riferimenti di assemblaggio. La guida CPL richiede mm e angoli positivi antiorari; la correzione per dispositivo/lato deve essere verificata, non dedotta dal solo nome del package.
- [JLCAPI](https://api.jlcpcb.com/): Components API pubblicizzata per prezzi, inventario e specifiche; accesso tramite richiesta e applicazione sul portale. Non è stato autenticato né interrogato un account. Nessun endpoint privato dedotto e nessun ordine inviato.
- [Ucamco: specifiche e corpus Gerber/XNC](https://www.ucamco.com/en/guest/downloads/gerber-format): riferimento ufficiale della futura uscita produttiva e del collaudo con lettore indipendente. E0 non genera Gerber.
