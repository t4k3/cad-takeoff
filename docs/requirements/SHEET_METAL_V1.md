# Lamiera propria — prima base T78

25 settembre 2026 · Codex (motore), contratto per Claude (UX).

Consegna anticipata su richiesta diretta di Ross: «comincia lamiere, vedi cosa fa Fusion e poi fai la base». Modulo `CADCore/SheetMetal`, senza dipendenze esterne. Funziona dal core e genera file di prova; **non è ancora collegato all’interfaccia, al documento `.ftk` o agli strumenti chat/MCP**.

## Confronto con il riferimento

Consultata la documentazione ufficiale Autodesk il 25/09/2026; questo confronto non è una prova interattiva dell’app Fusion.

| Funzione Fusion documentata | Base nostra verificata | Resta da sviluppare |
|---|---|---|
| Regole con spessore, raggio, K e scarichi | Regola identificata e revisionata: spessore, raggio interno, K esplicito | Libreria materiali/processi, gap, scarichi e override |
| Flange base, bordo, contorno, hem e lofted | Piastra rettangolare e una flangia di bordo intera | Bordi arbitrari/parziali/multipli, contorno, hem, lofted |
| Lunghezze con riferimenti interno, esterno o tangente | Lunghezze dalla tangente, convenzione unica dichiarata | Scelta del riferimento e della posizione della piega |
| Unfold/Refold nello storico del design | Nessuno | Stato temporaneo spiegato e lavorazioni attraverso le pieghe |
| Flat Pattern derivato, aggiornabile ed esportabile | Sviluppo analitico separato, invalidato dalle modifiche della parte | Faccia fissa selezionabile, lavorazioni sul piatto, tavole |
| Storico parametrico del progetto | Due operazioni serializzate e ricostruibili nel documento lamiera autonomo | Integrazione timeline generale, assiemi e dipendenze |

Fonti: [regole](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-RULES-REF.htm), [flange](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-FLANGES.htm), [parametri delle flange](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-REF-BASE-EDGE-CONTOUR-FLANGE.htm), [Unfold](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-UNFOLD-IN-SM.htm), [Flat Pattern](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/GUID-121F6E58-0459-4552-85EF-319F44324AE6.htm). La matrice completa SM01–SM17 rimane in [SHEET_METAL.md](SHEET_METAL.md).

## Contratto per l’interfaccia

```swift
let rule = try SheetMetalRule(name: "Prova: K da calibrare",
                             thickness: 2, insideRadius: 3, kFactor: 0.4)
let part = try SheetMetalPart(name: "Staffa L", rule: rule,
                             width: 40, baseLength: 60)
    .addingFlange(.init(length: 30, angleDegrees: 90, direction: .up))
let result = try SheetMetalEngine.rebuild(part)
// Renderer: result.foldedBody.snapshot(revision: String(part.revision))
// Sviluppo: result.flatPattern.outline / .mesh / .bendZones
let dxf = try SheetMetalDXF.export(result.flatPattern, for: part)
let saved = try part.encoded()
let reopened = try SheetMetalPart.decode(saved)
```

Tutti i valori sono in mm, Z verso l’alto. Il renderer usa la conversione già prevista per CADCore. `foldedBody` è un `BRepBody` con mesh chiusa e snapshot compatibile con [KERNEL_V1.md](KERNEL_V1.md).

Campi UX: nome, larghezza, lunghezza base, spessore, raggio interno, K-factor; per la flangia lunghezza, angolo dalla posizione piana, verso su/giù. Mostrare **«lunghezza dalla tangente»**, **«angolo dalla posizione piana»**, revisione e stato aggiornato/obsoleto dello sviluppo.

Gli editor restituiscono copie: creare il candidato, chiamare `rebuild`, presentare l’anteprima, poi applicare la copia valida come singola transazione del Model. Se `rebuild` fallisce, conservare la parte precedente e mostrare l’errore. La validazione dei parametri avviene prima di restituire la copia; quella geometrica completa in `rebuild`.

| API su `SheetMetalPart` | Comportamento |
|---|---|
| `addingFlange` | Aggiunge una sola flangia; una seconda viene respinta |
| `editingBase(width:length:)` | Cambia la base conservando l’ID dell’operazione |
| `editingFlange` | Cambia la flangia conservando ID e soppressione |
| `suppressingFlange` | Disattiva/riattiva senza perdere i parametri |
| `replacingRule` | Aggiorna regola e revisione parte; stesso ID regola richiede revisione maggiore |
| `rolledBack(through:)` | Restituisce una copia con il prefisso selezionato delle operazioni |
| `encoded` / `decode` | Salva/riapre dati, parametri, ID, regola e soppressione in JSON v1 |

**Limite storico:** `rolledBack` non è ancora il marker non distruttivo della timeline generale: la copia risultante contiene soltanto il prefisso, mentre l’originale resta intatto. La UI deve conservare l’originale per avanzare di nuovo. Non esistono ancora riordino, diario delle versioni, UndoManager, riferimenti tra parti o ripristino automatico dopo errore del documento globale.

Prima di integrare nel `.ftk`, concordare con Claude il contenitore con gli schizzi `sketches`/`sketchLinks` di T77. Non convertire lo storico in sola mesh. Esporre le stesse transazioni alla chat/MCP nella successiva integrazione, con controllo di revisione e undo.

## Geometria e calcolo

Base nel piano XY: `x ∈ [-baseLength, 0]`, `y ∈ [-width/2, width/2]`, `z ∈ [0, thickness]`. Unico bordo di attacco: `x = 0`, lungo tutta la larghezza. La flangia parte dalla tangente finale della curva. L’angolo è la rotazione dalla posizione piana: 90° produce una staffa a L; non è l’angolo interno.

Il verso `down` specchia la sezione XZ rispetto a `z = thickness/2` e inverte l’asse di estrusione Y, mantenendo il winding con una rotazione propria. La parte può avere Z negativo: la disposizione sul piatto va effettuata dal flusso di stampa.

La sezione piegata ha due archi concentrici, raggi `R` e `R+t`, estrusi sulla larghezza. Gli archi sono approssimati da corde; le facce effettive sono piane. `maximumSurfaceDeviation = (R+t) × (1 − cos(θ/(2N)))` riporta lo scostamento massimo radiale dall’arco ideale. Lo spessore nominale è radiale: tra i piani delle singole faccette è approssimato. Non si dichiarano superfici cilindriche esatte. Gli ID di operazione persistono; gli ID topologici derivano conservativamente dal profilo e possono cambiare al cambio quote.

Il piatto non si ottiene aprendo i triangoli. Si usa il modello circolare della linea neutra, con parametri espliciti:

```text
θ = angleDegrees × π / 180
BA = θ × (R + K × t)
lunghezza sviluppata = lunghezza base + BA + lunghezza flangia
```

La definizione di K come posizione relativa della linea neutra segue il [riferimento delle regole](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-RULES-REF.htm); l’intervallo 0–1 è coerente con [l’API Autodesk](https://help.autodesk.com/cloudhelp/ENU/Fusion-360-API/files/SheetMetalRule_kFactor.htm). La formula è il nostro modello analitico, non replica tabelle proprietarie. Non compensa ritorno elastico, utensili o processo. K=0,4 del campione è un valore di prova, non una prescrizione per un materiale.

Il volume del piegato nominale a spessore costante usa l’arco medio R+t/2; il piatto usa R+K×t. Per K diverso da 0,5 i due volumi nominali possono differire: non sono una simulazione della deformazione plastica. Anche per K=0,5 rimane lo scostamento della tessellazione. Per questa base non dedurre la massa di produzione dal volume piegato.

## Revisioni e DXF

Lo sviluppo conserva parte/revisione e regola/revisione. `isCurrent(for:)` confronta anche l’intero valore della parte, così modifiche a un JSON che riutilizzano la revisione non aggirano il controllo. L’export DXF rifiuta uno sviluppo obsoleto. La mesh del piatto rimane un valore leggibile: l’integrazione dovrà applicare lo stesso controllo prima di stamparla o salvarla.

DXF ASCII AC1015, `$INSUNITS = 4` (mm), una `LWPOLYLINE` chiusa sul layer `CUT`. Linea centrale sul layer `BEND_UP` o `BEND_DOWN`, tangenti sul layer `BEND_TANGENT`. Zona da `x=0` a `x=BA`, centro a `BA/2`. Commenti DXF includono ID, revisione, angolo geometrico e raggio; non sono istruzioni della pressa. Contorno e linee sono tutti a Z=0.

Struttura confrontata con [LWPOLYLINE](https://help.autodesk.com/cloudhelp/2015/ENU/AutoCAD-DXF/files/GUID-748FC305-F3F2-4F74-825A-61F04D757A50.htm) e [variabili DXF](https://help.autodesk.com/cloudhelp/2021/ENU/AutoCAD-DXF/files/GUID-A85E8E67-27CD-4C59-BE61-4DC9FADBE74A.htm).

## Limiti

- Dimensioni, spessore e raggio: 0,01–10000 mm, finiti. K finito tra 0 e 1.
- Angolo 5–135°, tessellazione 2–60 segmenti per piega (default 24).
- Una base rettangolare, una sola flangia intera; nessun foro, scarico, miter, cucitura, multipiega, hem, loft, conversione, Unfold/Refold o assieme.
- Combinazioni numericamente degeneri possono essere respinte dal kernel anche se i singoli parametri sono nell’intervallo; nessuna correzione silenziosa.
- `decode` limita il JSON a 1 MiB e valida formato/operazioni/parametri. Un decode Codable standard va seguito da `rebuild`, che valida nuovamente.
- JSON lamiera v1 è un formato autonomo sperimentale, non un nuovo `.ftk`.
- Nessuna integrazione con la timeline generale, interfaccia o AI in questa consegna.

## Evidenze ripetibili

```sh
swift test --package-path Packages/CADCore
bash scripts/test-sheet-metal.sh
bash scripts/ci.sh
```

11 test Swift dedicati: piastra, staffa su/giù, volume da sezione, chiusura, convergenza della tessellazione, sviluppo indipendente dalla tessellazione, salvataggio/replay, edit/ID, soppressione/rollback, cambio regola/obsolescenza, JSON alterato e input invalidi. Il corpus parametrico copre 30 combinazioni di angolo/verso/K; si aggiunge ai test già presenti.

`Tests/SheetMetal/Fixture.swift` salva e rilegge le operazioni prima di generare gli export. `verify.py`, con la sola libreria standard Python, legge STL, ZIP/XML 3MF e coppie DXF e confronta quote, volumi, orientamento/chiusura, colori, unità, contorno e linee con risultati analitici indipendenti. È una verifica dei file, non un collaudo del loro import in un CAD/CAM.

File generati in `build/sheet-metal/` (esclusi da Git, riproducibili):

- `index.html`: anteprima tecnica derivata dagli STL/DXF effettivi;
- `LBracket.sheetmetal.json`: regola e due operazioni;
- `LBracket.stl`, `LBracket.3mf`: modello piegato;
- `LBracket-flat.dxf`, `LBracket-flat.3mf`: sviluppo;
- `LBracket-down-flat.dxf`: variante verso il basso;
- `report.json`: parametri e risultati misurabili.

Campione: larghezza 40, base 60, flangia 30, spessore 2, R=3, K=0,4, angolo 90°. Atteso: BA=5,96902604182 mm, sviluppo 95,96902604182×40 mm; piegato X[-60,5], Y[-20,20], Z[0,35]. Nessuna prova in officina o confronto con un pezzo fabbricato incluso.
