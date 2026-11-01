# T138 — Tasks

Legenda: `[x]` fatto. Un solo task `in_progress` alla volta.

## Preparazione

- [x] **P0** Percorsi del task corretti nel grafo (`Packages/CADCore/Tests/CADCoreTests`
  al posto di `Sources/CADCore/Tests/CADCoreTests`).

## CADCore

- [x] **A1** `SketchConstraints.swift`: `filletAllCorners(_:radius:)`, `chamferAllCorners(_:distance:)`
  e `cutAllCorners(_:size:chamfer:)` (n linee aperte con ID stabile → `replaceShape` con H/V
  solo rettangolo + `coincident` adiacenti → `cutCornerBetween` per ogni angolo; copia locale,
  `self = next` solo a successo; ID in ordine di angolo).
- [x] **A2** Test in `SketchConstraintTests.swift`: rettangolo R2 (8 forme, 4 archi, area),
  smusso 2 (8 linee, area 192), esagono R1 (12 forme), raggio eccessivo transazionale,
  vincolo `fix` rimappato sulle nuove linee.
- [x] **A3** `swift test --package-path Packages/CADCore`: **237 test verdi**.

## App — creazione e modifica

- [x] **B1** Rettangolo creato come **single entity** (ramo speciale e `commitRectangle` rimossi;
  larghezza/altezza negative normalizzate; `selection = id`).
- [x] **B2** `filletCorner`: forma rettangolo/poligono ⇒ `filletAllCorners`/`chamferAllCorners`
  su copia con verifica `solve()` prima di applicare e selezione dell'arco più vicino al clic;
  altrimenti `jointUnder` (angolo singolo tra due linee) e `cornerUnder`.
- [x] **B3** Hint Raccordo/Smusso aggiornati in `Tool.hint`.

## App — grip e trascinamento

- [x] **C1** `gripCenter`, `gripHit`, `hoverShape`, `hotGrip`; `hover` aggiorna forma e grip;
  `overlay` disegna anello a 12 segmenti + 4 tacche (colore selezionato/hot).
- [x] **C2** `beginDrag` con precedenza al grip (`shapeDrag`, `dragRef = .point(id,0)`,
  `recordStep`, `dragging = true`); `drag` con target `anchor + delta`; `endDrag` azzera.
  `dragging` ora osservabile e `isDragging` lo segue.
- [x] **C3** `ViewportContainer`: routing con `sketch.isDragging`; cursore `closedHand`
  durante il drag, `openHand` su grip in Seleziona.

## Localizzazione

- [x] **D1** Catalogo: due nuove chiavi hint (it + en + zh-Hans, `extractionState: manual`),
  rimosse le due vecchie; JSON valido.

## Verifica e chiusura

- [x] **E1** `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → **BUILD SUCCEEDED**.
- [x] **E2** Verifica automatica completata (237 test + build); la prova interattiva dei 5 punti
  dello spec è indicata a Ross nel messaggio finale (non eseguibile da qui).
- [x] **E3** `python3 scripts/graph.py done T138 --note "..."` → `T138 -> done`; voce nel registro.
- [x] **E4** Nessun commit/push; cosa provare in app riportato nel messaggio finale.

## Rischi / note

- `replaceShape` fa cadere i vincoli che puntano al centro del rettangolo (punto 4): dopo il
  raccordo il centro non è più un punto nominato; è previsto.
- Se un lato è più corto del raggio (o del doppio della distanza di smusso), l'intera operazione
  fallisce senza toccare lo sketch (test A2/4).
- Il grip non compare per lo slot: non ha un centro parametrico unico.
- Il trascinamento del grip passa comunque dal solver: se dei vincoli bloccano la forma,
  il movimento non viene applicato (come oggi per i punti), senza corrompere lo sketch.
