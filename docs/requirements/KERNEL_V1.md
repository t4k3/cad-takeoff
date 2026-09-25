# Motore nostro — prima consegna B-rep e snapshot

25 settembre 2026 · implementazione Codex T70, milestone T75.

Questa consegna costruisce la topologia dai parametri dei solidi esistenti.
Non deduce le facce dalla somiglianza delle normali di una mesh e non introduce
librerie esterne. Il renderer di Claude può usare il risultato attraverso il Model.

## Perimetro verificato

| Forma | Topologia | Selezione nello snapshot |
|---|---|---|
| Box | 8 vertici, 12 spigoli, 6 facce piane, 24 coedge | 6 facce, 12 spigoli |
| Cilindro a N segmenti | 2N vertici, 3N spigoli, N+2 facce piane | 2 basi e 1 fianco cilindrico raggruppato; 2 bordi chiusi |
| Estrusione di un contorno XY semplice | Come un prisma, anche concavo | Basi e singole facce/spigoli laterali |

Un solo guscio chiuso, un contorno per faccia, nessun foro. Ogni spigolo ha due
coedge opposti; ogni faccia possiede un ciclo orientato. Il modello controlla
incidenza, planarità, orientamento dei triangoli e volume positivo. I profili
autointersecanti, a contatto, con vertici coincidenti o consecutivi allineati
sono rifiutati con un errore; non viene restituita una geometria parziale.

Limiti iniziali: dimensioni 0,01–100000 mm; coordinate del profilo e traslazioni
entro ±100000 mm; 3–128 punti per profilo libero; 3–512 segmenti per cilindro,
default 64. Sono limiti dell'API del kernel, non una validazione completa di
qualsiasi documento importato: T03 resta aperto.

## API e convenzioni

```swift
let body = try PrimitiveKernel.build(feature, cylinderSegments: 64)
try body.validate()
let mesh = body.mesh                     // vertici condivisi, CCW esterno
let snapshot = body.snapshot(revision: designRevision)

// In app, @MainActor; usa una cache finché designRevision non cambia:
let result = model.snapshot()            // DesignSnapshot
let bodies = result.bodies              // [BodySnapshot], solo feature visibili
let issues = result.issues              // featureID + messaggio per geometrie invalide
```

- Coordinate in **millimetri, Z verso l'alto**, normali unitarie nello stesso
  sistema. Traslazione della feature già applicata a punti, piani e asse cilindro.
- `DesignSnapshot.revision` e `BodySnapshot.revision` sono la stringa di revisione
  del Model. Le letture non modificano documento, revisione o undo. La cache si
  aggiorna anche dopo undo, caricamento o sostituzione diretta del documento.
- Feature non valide vengono escluse da `bodies` e presenti in `issues`; le altre
  restano disponibili. ID di parte duplicati producono una diagnosi ed escludono
  i corpi ambigui. La UI deve presentare gli errori, senza usare geometria obsoleta.
- `BodySnapshot.positions`, `normals`, `triangles` sono dati per rendering con
  vertici separati per triangolo. Per export con connettività usare `BRepBody.mesh`.
- `triangleFace` contiene **un indice in `faces` per triangolo**, non per vertice.
  `triangleTopologyFace` indica invece la faccia piana B-rep di quel triangolo.
  Non accoppiare queste mappe ai triangoli di `Feature.buildMesh()`: l'ordine può
  differire. Renderizzare e selezionare usando i triangoli dello stesso snapshot.
- `FaceInfo`: `id`, `surface`, `area`, `topologyFaceIDs`. La superficie è
  `.plane(origin:normal:)` oppure `.cylinder(axisOrigin:axisDirection:radius:)`.
  Sul cilindro descrive la superficie sorgente, mentre la geometria resta sfaccettata.
- `EdgeInfo`: `id`, `polyline`, `isSharp`, `faces: [FaceID]`, `topologyEdgeIDs`,
  `length`. Le polilinee sono ordinate; un bordo chiuso ripete il primo punto.
  Le facce adiacenti sono due. Gli spigoli interni tra faccette cilindriche non
  sono bordi di selezione. Area e lunghezza misurano la geometria sfaccettata.

La cache è sincrona sul MainActor per questi primitivi limitati. Rebuild costosi,
cancellazione e calcolo fuori dal MainActor appartengono alle tappe successive.

## Identità e riferimenti

Gli ID sono tipizzati (`FaceID`, `EdgeID`, `VertexID`) e deterministici: namespace
della feature + ruolo. Non dipendono da hash Swift, indirizzi o ordine delle
triangolazioni. Una riapertura dello stesso documento ricostruisce gli stessi ID.

| Modifica | Comportamento |
|---|---|
| Quote, posizione, nome o colore di un box | ID di facce/spigoli/vertici conservati |
| Raggio, altezza o posizione del cilindro | Ruoli conservati |
| Numero di segmenti del cilindro | ID delle tre facce di selezione e dei due bordi conservati; ID delle faccette invalidati |
| Altezza/traslazione di un'estrusione | ID conservati |
| Punti, ordine o numero di vertici del profilo libero | Basi conservate; riferimenti laterali e spigoli invalidati conservativamente |
| Nuova feature o cambio di tipo | Namespace/ruoli distinti, nessun riaggancio implicito |

Il profilo v1 non ha ID delle entità schizzo: per i riferimenti laterali si
codificano senza hash le coordinate del profilo. Questo è un contratto provvisorio,
non il naming topologico completo di T30. Split, merge, booleane e rigenerazione
dello storico richiederanno genealogia e regole di rimappatura esplicite.

## Precisione e limiti

Il cilindro resta un prisma poligonale. `maximumSurfaceDeviation` riporta la
freccia radiale `r * (1 - cos(pi / N))`; il default di 64 segmenti **non garantisce
0,01 mm per ogni raggio**. Normali lisce servono soltanto al rendering. Metadati
analitici non introducono curve esatte né una tolleranza generale certificata.

Non sono ancora implementati: booleane, raccordi, superfici analitiche/NURBS,
gusci con fori, split/merge, riferimenti per istanze, storico parametrico
persistente, solver o lamiera. STL/3MF e strumenti MCP esistenti mantengono il
percorso di export precedente; lo snapshot introduce il nuovo contratto del renderer.
La sostituzione dell'adattatore UI `DerivedTopology` resta lavoro di Claude.

## Prove ripetibili

```bash
scripts/ci.sh
```

Esito della consegna: 19 test core (incluso corpus deterministico di 80 profili),
50 verifiche assistant/Model, 15 MCP HTTP, 23 provider OpenAI offline,
3 connettore, controllo indipendente ZIP/XML/CRC del 3MF e build Xcode riuscita.
I test verificano volumi, misure, connettività, mappe renderer, ID attraverso
modifiche/riapertura/retessellazione, rifiuto input invalidi, cache, undo e diagnosi.
Log: `build/ci/run.ZUUwHC/` (artefatto locale, non versionato).

Queste sono prove di sorgente e build; non attestano l'integrazione UI dello
snapshot, la precisione di una stampa fisica o un kernel CAD generale completo.
