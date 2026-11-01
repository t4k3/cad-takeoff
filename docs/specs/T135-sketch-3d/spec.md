# Spec — T135: Schizzo 3D, modello dati e solver per punti e linee 3D

Stato: **in attesa di approvazione** (nessuna modifica al codice prima dell'ok).
Task: `T135` (in_progress, claude, prerequisito T133 `done`). Fase 1 del piano «3D sketch»
approvato da Ross il 2026-10-31: entità 3D + vincoli di piano di lavoro; questa fase copre solo
**modello dati e solver**. T136 (vincoli 3D e quote) e T137 (strumenti/rendering/picking UI)
restano task separati.

Vincoli: `AGENTS.md` (mm, Z↑, core puro, `swift test` + build app, nessun commit), `docs/UX_RULES.md`
§5–§6 (testi UI in italiano, il core non importa UI), `Packages/ElectronicsCore/**` non si tocca.

## 1. Problema

Lo schizzo è oggi rigorosamente 2D: `SketchShape.Kind` memorizza `Vec2` e `SketchSolver` ha due
incognite per punto. Per una modellazione 3D serve poter disegnare punti e linee nello spazio del
piano di lavoro (anche fuori dal piano) mantenendo intatti profili, estrusioni, vincoli 2D e i
documenti già salvati (226 test CADCore verdi).

## 2. Decisioni

1. **Nuove entità nel modello esistente**, in coordinate del piano di lavoro
   (`x` lungo `plane.xAxis`, `y` lungo `plane.yAxis`, `z` lungo `plane.normal`, in mm):
   - `SketchShape.Kind.point3D(position: Vec3)`
   - `SketchShape.Kind.line3D(start: Vec3, end: Vec3)`
   Le entità 2D restano su `[Vec2]`: la loro z è implicitamente 0 e **non** diventa un'incognita.
2. **Solver a 3 incognite per punto 3D**: `parameters` = 3 valori (punto) / 6 (linea). Il Jacobian
   resta sparso per vincolo (T131): le righe 3D usano solo le variabili delle forme toccate.
3. **Vincoli 2D invariati**: `point(_:)`/`segment(_:)`/`circle(_:)` restituiscono `nil` per le
   nuove entità, quindi tutti i 24 vincoli 2D non le toccano. Si estendono solo i tre vincoli già
   esistenti che hanno senso in 3D:
   - `coincident`: 3 righe (Δx, Δy, Δz) quando almeno un ref è su una forma 3D;
   - `distance`: distanza euclidea 3D punto–punto quando almeno un ref è su una forma 3D;
   - `length`: lunghezza 3D del segmento di una `line3D`.
   Nessun nuovo caso in `SketchConstraintKind` (i vincoli di piano/quote sono T136).
4. **Le entità 3D non generano profili**: `isClosed == false`, `outline == []`, `prims == []`,
   `profile == nil`, `area == 0`; `regions`, `areas`, estruzioni, `sideKeys`, trim/extend/offset/
   raccordo le ignorano automaticamente. `length` di una `line3D` è la sua lunghezza 3D (un punto 0).
5. **Compatibilità file**: si aggiungono solo casi nuovi all'enum `Codable` (sintesi invariata);
   `Sketch` continua a omettere `constraints` quando vuoto. I documenti v1/v2 senza entità 3D si
   decodificano come prima. Nessuna migrazione.
6. **UI minima per compilare e nominare** (gli strumenti sono T137): icone, riepilogo, nomi,
   snap/marker ignorano le entità 3D; il pannello parametri e il disegno nel viewport arrivano in
   T137. Due chiavi nuove nel catalog (`Punto 3D`, `Linea 3D`) con `en` e `zh-Hans`.

## 3. Modifiche puntuali

### 3.1 `Packages/CADCore/Sources/CADCore/Sketch/SketchModel.swift`
- `SketchShape.Kind`: nuovi casi `point3D(position: Vec3)`, `line3D(start: Vec3, end: Vec3)` con
  commento sulle coordinate del piano.
- `isClosed`: `.point3D`/`.line3D` → `false`.
- `outline`: `.point3D`/`.line3D` → `[]`.
- `length`: `.point3D` → 0; `.line3D` → `(end - start).length`.
- `typeName`: `.point3D` → `"Punto 3D"`; `.line3D` → `"Linea 3D"`.
- `area`/`profile`/`regions`: nessuna modifica (già protetti da `isClosed`/`outline`).

### 3.2 `Packages/CADCore/Sources/CADCore/Sketch/SketchConstraints.swift`
- `SketchRef`: commento degli indici aggiornato (punto 3D 0; linea 3D 0 inizio, 1 fine; segmento 0).
- `SketchShape.parameters`: `.point3D` → `[x, y, z]`; `.line3D` → `[a.x, a.y, a.z, b.x, b.y, b.z]`.
- `with(parameters:)`: due casi simmetrici.
- `point(_:)`, `segment(_:)`: `nil` per i nuovi casi; `pointCount` 1/2; `segmentCount` 0/1.
- Nuovi accessori pubblici:
  - `point3D(_ i: Int) -> Vec3?` (punto 3D 0; linea 3D 0/1);
  - `segment3D(_ i: Int) -> (Vec3, Vec3)?` (linea 3D 0);
  - `is3D: Bool`.

### 3.3 `Packages/CADCore/Sources/CADCore/Sketch/SketchEdit.swift`
- `prims`: `.point3D`/`.line3D` → `[]`.
- `mirror` (switch esaustivo su `s.kind`): copia con `x,y` riflessi e `z` invariata; nessuna
  relazione `symmetric` aggiunta (il vincolo è 2D, T136 potrà estenderlo).
- `exploded`, `chain`, `trim`, `extend`, `offset`: già con `default`, invariati.

### 3.4 `Packages/CADCore/Sources/CADCore/Sketch/SketchSolver.swift`
- Nuovo `struct GVec3<S: SketchScalar>`: `x,y,z`, `-`, `dot`, `length`.
- `GShape<S>`:
  - casi 3D nei `point`, `pointCount`, `segmentCount` (1, 2, 0, 1);
  - `segment` e `circle` → `nil`;
  - `is3D`;
  - `point3(_:)`: punto/linea 3D; per le forme 2D proietta con `z = S.from(0)` costante;
  - `segment3(_:)`: solo `line3D`.
- Aiutanti:
  - `point3Of(_:_:)`: `.point` → `point3`; `.origin` → `(0,0,0)`;
  - `segment3Of(_:_:)`: `.segment` → `segment3`;
  - `is3DRef(_:_:)`: `s[ref.shapeID]?.is3D == true` (le entità fisse non sono 3D).
- Righe:
  - `coincident`: se `is3DRef(a) || is3DRef(b)` → `[p.x-q.x, p.y-q.y, p.z-q.z]` con `point3Of`;
    altrimenti le due righe attuali.
  - `distance`: se una ref è 3D → `[(q-p).length - d]` con `point3Of`; altrimenti invariato.
  - `length`: prima `segment3Of` (3D), poi il ramo 2D attuale.
- `branch`, `pointOf`, drag, diagnostica: invariati (le ref 3D non hanno ramo 2D).

### 3.5 UI — solo esaustività (T137 farà strumenti/rendering/picking)
- `App/Sources/UI/Sketch/SketchInspector.swift`
  - `symbol`: `.point3D` → `"smallcircle.filled.circle"`, `.line3D` → `"line.diagonal"`;
  - `summary`: coordinate `x, y, z` per il punto, lunghezza 3D per la linea;
  - `ShapeParameters`: ramo 3D con testo informativo «Entità 3D · parametri nel pannello di T137»
    (nessun editor nuovo in questa fase);
  - `kindName`: «Punto 3D» / «Linea 3D».
- `App/Sources/UI/Sketch/SketchSession.swift`: `snapPoints` e i marker: nessun punto per le
  entità 3D (T137 aggiunge il picking nello spazio).
- `App/Sources/UI/Sketch/SketchConstraintChecker.swift`: `kindKey` `"point3d"`/`"line3d"`;
  `entityName` con i due nomi; vincoli impliciti → `nil`.
- `App/Sources/UI/Features/HoleCommand.swift`: `outline` → `[]` per le entità 3D.
- `App/Resources/Localizable.xcstrings`: chiavi `Punto 3D` e `Linea 3D` con `en`/`zh-Hans`.

### 3.6 Test — nuovo `Packages/CADCore/Tests/CADCoreTests/Sketch3DTests.swift`
1. `point3DAndLine3DParametersRoundTrip`: `parameters` 3/6, `with(parameters:)` identico,
   `point3D`/`segment3D` corretti, `point`/`segment` 2D `nil`.
2. `threeDEntitiesNeverBecomeProfiles`: solo linea 3D → `profiles`/`regions` vuoti; cerchio +
   linea 3D → una regione senza buchi e una sola forma in `profiles`.
3. `threeDLineLengthIsSolvedOffThePlane`: linea `(0,0,0)–(3,0,4)`, `.length(.segment(id,0), 10)`;
   dopo `solve()` lunghezza = 10 ± 1e-7 e le z si sono mosse (fine z > 0, inizio z < 0).
4. `threeDPointCoincidentToOriginLandsAtTheOrigin`: punto `(4,2,4)` + coincidente con `.origin`;
   dopo `solve()` è `(0,0,0)` (la z è un'incognita risolta, non bloccata).
5. `threeDGeometrySurvivesCodable`: sketch con i due casi + vincoli 3D, encode/decode uguale.
6. `legacyTwoDSketchStillDecodes`: JSON scritto a mano (polyline 2D, senza chiavi nuove) decodificato
   con `JSONDecoder` → forma e piano intatti.
7. I test 2D esistenti restano invariati e verdi.

## 4. Verifica (prima di dichiarare finito)

1. `swift test --package-path Packages/CADCore` → 226 + nuovi test, tutti verdi.
2. `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → BUILD SUCCEEDED
   (obbligatorio: sono toccati file App per l'esaustività degli switch).
3. `bash scripts/test-assistant-tools.sh` solo se cambiano snapshot del Model (qui non previsto).
4. `python3 scripts/graph.py paths T135 <percorsi aggiornati> --by claude` (aggiunge i 4 file App,
   il catalog e il nuovo test), poi `python3 scripts/graph.py done T135 --note "…"`.
5. `docs/DA_PROVARE.md`: nessuna prova UI nuova (T135 non crea entità dall'interfaccia);
   la prova visiva arriva con T137.

## 5. Rischi e mitigazioni

- **Switch esaustivi**: aggiungere casi rompe i `switch` in CADCore e App → elencati al §3.
- **Regressioni 2D**: le righe 2D restano identiche; i test esistenti fanno da rete.
- **Diagnostica**: le forme 3D compaiono in `freedomPerShape` con 3/6 parametri; nessun cambio di
  significato per le forme 2D.
- **File salvati**: solo casi nuovi, nessuna chiave obbligatoria nuova.

## 6. Fuori scope (task successivi)

- T136: `POINT_IN_PLANE`, distanza punto–piano, normale del piano di lavoro, blocco rotazione,
  `fix3D`, quote 3D, quote di distanza nel sistema del piano.
- T137: strumenti Punto/Linea 3D, rendering (proiezione sul piano e profondità), picking e snap
  nello spazio, rotella/inspector completo.
- Nessun export STEP/3MF di geometria 3D di schizzo (non è un profilo).
