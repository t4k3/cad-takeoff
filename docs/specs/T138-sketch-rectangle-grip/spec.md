# T138 — Rettangolo come entità unica, raccordo/smusso di tutti gli angoli, presa centrale

Stato: **approvata e implementata** (nessun commit, come da istruzione dell'utente).

## 1. Problema (dal riscontro di Ross)

1. Il tool Rettangolo oggi crea **quattro linee** (T126, `addRectangle`): nell'elenco compaiono
   «Linea 1…4», non un rettangolo. Il poligono invece resta una entità unica. Deve tornare così
   anche il rettangolo: una sola entità, parametrica (angolo X/Y, larghezza, altezza).
2. Raccordo/Smusso cliccando **la forma** (rettangolo o poligono) devono agire su **tutti i
   angoli** in un colpo solo, convertendo la forma in linee + archi (o linee, per lo smusso).
   Cliccando l'angolo tra **due linee indipendenti** resta il raccordo/smusso singolo.
3. Il centro geometrico di cerchio/poligono/rettangolo è già trascinabile, ma **non si vede**
   che è una presa: serve un grip visibile (anello + quattro tacche), cursore a manina e
   trascinamento dell'intera forma.

Riferimenti di comportamento: SolidWorks (grip al centro della entità selezionata, maniglia
aperta/chiusa), FreeCAD (dragging del profilo), dune3d (rettangolo come entità parametrica).

## 2. Decisioni di prodotto

- **Creazione**: Rettangolo = una entità `.rectangle` (angolo + larghezza + altezza), come il
  poligono. Nessuna esplosione in 4 linee, nessun vincolo H/V aggiunto alla creazione.
- **Raccordo/Smusso**: clic sull'entità rettangolo/poligono ⇒ tutti i suoi angoli, in un solo
  passo di undo. Clic tra due linee aperte ⇒ singolo angolo (comportamento attuale).
  Dopo l'operazione l'entità diventa linee + archi (smusso: solo linee), cioè un profilo
  multi-entità, coerente con «自动设置为多边形».
- **Grip**: visibile su rettangolo, cerchio e poligono quando la forma è **selezionata o
  sotto il cursore**; cursore `openHand` sopra il grip, `closedHand` durante il trascinamento.
  Trascinare il grip sposta **l'intera forma**; il trascinamento dagli angoli resta quello
  attuale (con l'angolo opposto fissato). Lo slot non ha un vero centro parametrico: niente grip.
- **Nessun cambiamento** a quote, vincoli, undo/redo oltre a quanto elencato.

## 3. Modifiche tecniche

### 3.1 CADCore — `Packages/CADCore/Sources/CADCore/Sketch/SketchConstraints.swift`

Nuove API pubbliche (chiamate dalla UI, quindi stabili):

```swift
/// Raccorda tutti gli angoli di un rettangolo o poligono. Ritorna gli ID degli archi,
/// nell'ordine degli angoli (rettangolo: angolo 0→3; poligono: vertici 1…n).
@discardableResult
public mutating func filletAllCorners(_ shapeID: UUID, radius r: Double) throws -> [UUID]

/// Smussa tutti gli angoli di un rettangolo o poligono. Ritorna gli ID delle linee di smusso.
@discardableResult
public mutating func chamferAllCorners(_ shapeID: UUID, distance d: Double) throws -> [UUID]

private mutating func cutAllCorners(_ shapeID: UUID, size r: Double, chamfer: Bool) throws -> [UUID]
```

Algoritmo di `cutAllCorners`:

1. Valida: forma esistente, `r` finita e > 0; solo `.rectangle` o `.polygon`. Altrimenti
   `SketchEditError.invalid("raccordo: scegli un rettangolo o un poligono")`.
2. Raccoglie i vertici: rettangolo `point(0…3)`; poligono `point(1…max(3, n))`. `n =` vertici.
3. Costruisce `n` linee aperte `[corner[i], corner[(i+1)%n]]`; la prima **riusa l'ID originale**,
   le altre hanno UUID nuovi, conservano `isConstruction`.
4. Lavora su una **copia locale** (`var next = self`), applica `next.replaceShape(shapeID, with: lines,
   implied:)` con:
   - rettangolo: H/V come da `cutCorner` (`horizontal(segment(id,0))`, `vertical(segment(id,1))`,
     `horizontal(segment(id,2))`, `vertical(segment(id,3))`);
   - poligono: nessun implicito;
   - più `coincident(.point(line[i], 1), .point(line[i+1], 0))` per ogni angolo.
   `replaceShape` rimappa i vincoli esistenti per posizione (i vincoli sul centro del rettangolo,
   punto 4, cadono: il centro non è più un punto nominato).
5. Per ogni angolo `i` (in ordine) chiama `next.cutCornerBetween(line[i], 1, line[(i+1)%n], 0,
   size: r, chamfer:)` sugli ID stabili. `cutCornerBetween` non cambia ID né indici dei punti
   (sostituisce solo l'estremo con il punto di tangenza), quindi il ciclo è stabile.
6. Solo se **tutte** le operazioni riescono: `self = next` e ritorna gli ID. Se una fallisce
   (raggio/smusso troppo grande per un lato), rilancia l'errore **senza** modificare lo sketch
   (transazione). Errore propagato: `SketchEditError.invalid` già localizzato in italiano.

Vincoli risultanti: perimetro chiuso linee/archi con `coincident` + `tangent` (raccordo) e
`radius` per arco; H/V conservati sul rettangolo. Nessun nuovo tipo di vincolo.

`addRectangle(corner:width:height:)` **resta** (usata dai test esistenti e da eventuali
comandi legacy) ma non è più chiamata dalla UI.

### 3.2 App — creazione rettangolo

`App/Sources/UI/Sketch/SketchSession.swift`

- In `commit(_:)` (o nel ramo `case .rectangle` di `click`) rimuovere il ramo speciale
  `commitRectangle` e usare il percorso comune: `SketchShape(kind: .rectangle(...))`,
  append, `autoConstraints(for:)`, `solve`, `selection = id`.
- **Normalizzazione**: nel secondo clic, se `width`/`height` sono negative, usare
  `corner = min(a, p)` e `width/height = abs`, così il rettangolo resta CCW con
  `width, height > 0` (prima lo faceva `addRectangle`).
- Eliminare `commitRectangle(corner:width:height:)` (nessun altro chiamante).
- L'ispettore (`SketchInspector.swift`) già mostra «Rettangolo» e i 4 parametri: nessuna modifica.
- `autoConstraints(for:)` già considera `ownPoints [0…3]` del rettangolo: nessuna modifica.

### 3.3 App — raccordo/smusso di tutti gli angoli

`App/Sources/UI/Sketch/SketchSession+Constraints.swift`, `filletCorner(_:chamfer:)`:

1. Se `pick(p)` restituisce una forma con `kind` `.rectangle` o `.polygon`:
   - `var next = sketch`;
   - `next.filletAllCorners(id, radius: filletRadius)` oppure
     `next.chamferAllCorners(id, distance: chamferDistance)`;
   - se `next.solve()` fallisce ⇒ `notice = "Raccordo/Smusso in conflitto con i vincoli dello schizzo."`,
     non applicare;
   - altrimenti `sketch = next`, `notice = nil`, `selection =` ID (tra quelli restituiti) il cui
     punto medio (`shape.prims.first?.at(0.5)`) è più vicino a `p`.
2. Altrimenti percorso attuale: `jointUnder(p)` (due linee aperte, angolo singolo) e poi
   `cornerUnder(p)` (vertice di polilinea chiusa o angolo di rettangolo). Per il rettangolo
   questa via non serve più (gestita al punto 1) ma resta per le polilinee chiuse.
3. Errori CADCore mostrati in `notice` come oggi (`error.localizedDescription`).
4. Hint dei tool in `Tool.hint` aggiornati:
   - Raccordo: «Clicca un rettangolo o un poligono: tutti gli angoli diventano archi del raggio
     impostato. Clicca vicino all'angolo tra due linee per un solo raccordo.»
   - Smusso: «Clicca un rettangolo o un poligono: tutti gli angoli vengono tagliati alla distanza
     impostata. Clicca vicino all'angolo tra due linee per un solo smusso.»

### 3.4 App — grip, cursore e trascinamento della forma

`App/Sources/UI/Sketch/SketchSession.swift`

- Nuovi helper (logica di presentazione, nessun calcolo nel core):
  ```swift
  /// Centro geometrico trascinabile: rettangolo punto 4, cerchio/poligono punto 0.
  func gripCenter(_ s: SketchShape) -> Vec2?
  /// Forma il cui grip è entro la tolleranza di snap da p.
  func gripHit(_ p: Vec2) -> UUID?
  ```
- Nuovo stato osservabile:
  - `var hoverShape: SketchShape.ID?` (forma sotto il cursore in modalità Seleziona);
  - `var hotGrip: SketchShape.ID?` (grip sotto il cursore, per colore e cursore).
- In `hover(_:)`: in modalità `.select` aggiorna `hoverShape = pick(raw)` e
  `hotGrip = gripHit(raw)`; negli altri tool entrambi a `nil`.
- In `overlay(...)`: per la forma `selection` o `hoverShape`, se `gripCenter` esiste, disegnare
  il grip con le `Line` esistenti: anello a 12 segmenti di raggio `vertexSnap * 0.6` e quattro
  tacche a croce di lunghezza `vertexSnap * 0.9`, colore `selectedColor` se `hotGrip == id`,
  altrimenti `sketchColor` attenuato. Nessuna nuova primitiva di rendering.
- Trascinamento:
  - `@ObservationIgnored var shapeDrag: (id: UUID, startCursor: Vec2, anchor: Vec2)?`
  - `var isDragging: Bool { dragRef != nil || shapeDrag != nil }`.
- `SketchSession+Constraints.swift`, `beginDrag(_:)`:
  - dopo il guard `tool == .select`, `constraintTool == nil`:
    - se `gripHit(local(world))` restituisce una forma con grip ⇒
      `shapeDrag = (id, cursor, point(id, 0))`, `dragRef = .point(id, 0)`, `dragFixes = []`,
      `setBlocking([])`, `recordStep()`, `dragging = true`, return `true`
      (il grip ha precedenza sul punto centrale, che è lo stesso punto per cerchio/poligono);
    - altrimenti percorso attuale `pickRef(.point)` (angoli, estremi, centri slot).
- `drag(_:)`: se `shapeDrag` attivo, il target del punto `(id, 0)` è
  `anchor + (local(cursor) - startCursor)`; il resto (solve con `drag:`, blocking, aggiornamento
  di `sketch.shapes`) resta invariato. Per cerchio/poligono il punto 0 è il centro, quindi il
  risultato è identico a oggi ma con il feedback visivo.
- `endDrag`: azzera `shapeDrag`, poi `analyze()` come oggi.

`App/Sources/UI/Viewport/ViewportContainer.swift`

- `onDragMove`/`onDragEnd`: sostituire `sketch.dragRef != nil` con `sketch.isDragging`.
- `viewportCursor`: ordine
  1. `sketch.isDragging` ⇒ `NSCursor.closedHand`;
  2. `sketch.tool == .select && sketch.hotGrip != nil` ⇒ `NSCursor.openHand`;
  3. resto invariato (crosshair per i tool che posano punti, freccia per Seleziona).
- `MetalViewport.updateNSView` applica già `viewCursor`: nessuna modifica.

### 3.5 Localizzazione — `App/Resources/Localizable.xcstrings`

- Rimuovere le due chiavi vecchie degli hint Raccordo/Smusso e inserire le nuove chiavi del §3.3
  con valori `en` e `zh-Hans`, in ordine alfabetico, `extractionState: manual`, it = chiave:
  - en Raccordo: «Click a rectangle or polygon: every corner becomes an arc of the set radius.
    Click near the corner between two lines for a single fillet.»
  - zh-Hans Raccordo: «点击矩形或多边形：所有角都变为设定半径的圆弧。点击两条线之间的角可做单个圆角。»
  - en Smusso: «Click a rectangle or polygon: every corner is cut at the set distance. Click near
    the corner between two lines for a single chamfer.»
  - zh-Hans Smusso: «点击矩形或多边形：所有角都按设定距离切角。点击两条线之间的角可做单个倒角。»
- Le stringhe `notice` sono già italiane e non localizzate: nessuna nuova chiave.

## 4. Test e verifica

### CADCore (`Packages/CADCore/Tests/CADCoreTests/SketchConstraintTests.swift`, nuova sezione)

1. **Rettangolo 20×10, raccordo R2 su tutti gli angoli**: `shapes.count == 8` (4 linee + 4 archi),
   4 `radius` = 2, tutti gli archi con `radius == 2`; `sketch.solve()` vero; il profilo è chiuso
   (ogni estremo di linea/arco ha un `coincident` con il successivo).
2. **Rettangolo 20×10, smusso 2 su tutti gli angoli**: 8 linee, 4 linee di smusso lunghe
   `2√2 ≈ 2.828`, `solve()` vero.
3. **Poligono esagono R5, raccordo R1**: 6 linee + 6 archi = 12 forme, 6 `radius` = 1.
4. **Transazione**: rettangolo 10×6 con R = 10 ⇒ `throws`, `shapes.count` resta 1 e i parametri
   del rettangolo non cambiano.
5. **Vincoli preservati**: un `fix` su un angolo del rettangolo resta nello sketch dopo il
   raccordo (rimappato su un estremo di linea).

### Build e comandi

- `swift test --package-path Packages/CADCore`
- `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh`
- Prima di implementare: correggere i percorsi del task T138
  (`Packages/CADCore/Tests/CADCoreTests`, manca `Packages/`) con `scripts/graph.py paths`.
- A fine lavoro: `scripts/graph.py done T138 --note "..."` e voce in `docs/COLLAB.md`.
- **Nessun `git commit`/`git push`** (istruzione esplicita dell'utente).

### Prova manuale (accettazione)

1. Tool Rettangolo: crea un rettangolo ⇒ nell'elenco **una** voce «Rettangolo»; Parametri mostra
   angolo X/Y, larghezza, altezza.
2. Cursore al centro del rettangolo ⇒ anello + 4 tacche, cursore a manina aperta; trascina ⇒
   l'intero rettangolo si sposta (con undo in un solo passo).
3. Stesso comportamento su cerchio e poligono; lo slot non mostra il grip.
4. Tool Raccordo, clic sul rettangolo ⇒ 4 archi (tutti gli angoli); clic sul poligono ⇒ tutti i
   vertici raccordati; clic tra due linee ⇒ un solo raccordo. Smusso idem.
5. Raggio troppo grande ⇒ messaggio d'errore, rettangolo intatto.

## 5. File toccati (percorsi del task T138)

- `Packages/CADCore/Sources/CADCore/Sketch/SketchConstraints.swift`
- `Packages/CADCore/Tests/CADCoreTests/SketchConstraintTests.swift`
- `App/Sources/UI/Sketch/SketchSession.swift`
- `App/Sources/UI/Sketch/SketchSession+Constraints.swift`
- `App/Sources/UI/Viewport/ViewportContainer.swift`
- `App/Resources/Localizable.xcstrings`
- `docs/specs/T138-sketch-rectangle-grip/{spec.md,tasks.md}`

Nessun tocco a `Packages/ElectronicsCore/**`, `project.yml`, `scripts/ci.sh`.
