# Tasks — T135: Schizzo 3D, modello dati e solver

Ordine di esecuzione. Ogni passo si chiude con il criterio indicato. Nessun commit.

## M0 — Processo
1. [x] `python3 scripts/graph.py paths T135 Packages/CADCore/Sources/CADCore/Sketch,Packages/CADCore/Tests/CADCoreTests,App/Sources/UI/Sketch/SketchInspector.swift,App/Sources/UI/Sketch/SketchSession.swift,App/Sources/UI/Sketch/SketchConstraintChecker.swift,App/Sources/UI/Features/HoleCommand.swift,App/Resources/Localizable.xcstrings --by claude`
   - Criterio: il comando riesce e aggiunge la voce PATHS in `docs/COLLAB.md`. Fatto (paths estesi poi con `SketchSession+Constraints.swift`).

## M1 — Modello (CADCore)
2. [x] `SketchModel.swift`: casi `point3D(position: Vec3)` e `line3D(start: Vec3, end: Vec3)`;
   `isClosed`, `outline`, `length`, `typeName`.
   - Criterio: compila; le entità 3D non producono `profile`.
3. [x] `SketchConstraints.swift`: `parameters`, `with(parameters:)`, `point`/`segment` → `nil`,
   `pointCount`, `segmentCount`, nuovi `point3D(_:)`, `segment3D(_:)`, `is3D`; commento
   `SketchRef`.
   - Criterio: `parameters.count` = 3/6; round-trip `with(parameters:)` esatto.
4. [x] `SketchEdit.swift`: `prims` → `[]`; caso `mirror` con `x,y` riflessi e `z` invariato.
   - Criterio: compila; trim/offset/raccordo continuano a ignorare le entità 3D.

## M2 — Solver (CADCore)
5. [x] `SketchSolver.swift`: `GVec3`, accessori `GShape` 3D, `point3Of`/`segment3Of`/`is3DRef`.
   - Criterio: compila; le righe 2D esistenti non cambiano.
6. [x] Righe `coincident` (3 righe se coinvolge una forma 3D), `distance` (euclidea 3D punto–punto),
   `length` (segmento 3D).
   - Criterio: i 4 test 2D del solver restano verdi; i nuovi test 3D passano.

## M3 — Test
7. [x] Nuovo `Packages/CADCore/Tests/CADCoreTests/Sketch3DTests.swift` con i 6 test del §3.6 della
   spec (parametri, profili/regioni, lunghezza fuori piano, coincidenza con origine, Codable,
   decodifica legacy 2D).
   - Criterio: `swift test --package-path Packages/CADCore` verde (226 + nuovi). Fatto: 232 test verdi.

## M4 — UI minima (compilazione e nomi)
8. [x] `SketchInspector.swift`: icona, riepilogo, ramo informativo in `ShapeParameters`, `kindName`.
9. [x] `SketchSession.swift`: `snapPoints` e marker senza punti 3D.
10. [x] `SketchConstraintChecker.swift`: `kindKey`, `entityName`, vincoli impliciti `nil`.
11. [x] `HoleCommand.swift`: `outline` → `[]` per le entità 3D.
12. [x] `Localizable.xcstrings`: chiavi `Punto 3D`, `Linea 3D` con `en` e `zh-Hans` (più
    `Inizio`/`Fine` per il ramo informativo).
    - Criterio: `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → BUILD SUCCEEDED.
    - Extra: `SketchSession+Constraints.swift` (switch dei punti propri) reso esaustivo.

## M5 — Chiusura
13. [x] `swift test --package-path Packages/CADCore` e build app di nuovo (rete finale).
14. [x] `python3 scripts/graph.py done T135 --note "Schema 3D: casi point3D/line3D nelle coordinate del piano, solver a 3 incognite per punto, coincident/distance/length estesi al 3D, codifica retrocompatibile, entità 3D fuori da profili/regioni; test Sketch3DTests verdi; UI solo esaustività."`
    - Criterio: task `done`, voce DONE in `docs/COLLAB.md`; nessun commit.

## Criteri di accettazione (fase 1)
- [x] `SketchPoint3D`/`Line3D` salvabili e riapribili; i vecchi documenti si aprono invariate.
- [x] Una linea 3D con quota di lunghezza si risolve anche fuori dal piano (z incognita).
- [x] Un punto 3D legato all'origine arriva a `(0,0,0)`.
- [x] Profili, regioni, estruzioni e strumenti 2D ignorano le entità 3D.
- [x] 226 test esistenti + nuovi test verdi; build app verde.
