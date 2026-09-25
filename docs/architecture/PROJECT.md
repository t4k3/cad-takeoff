# Fusion Takeoff — progetto progressivo

Revisione 1 · 25 settembre 2026 · stato iniziale dopo riconciliazione T00.
Stato operativo aggiornato: [grafo attività](../graph/GRAPH.md).

## Prodotto

Applicazione macOS per progettare piccoli componenti destinati alla stampa 3D.
Flusso obiettivo: schizzo XY → quote e vincoli essenziali → estrusione/rivoluzione
→ operazioni sui solidi → controllo mesh → STL/3MF → slicer esterno.

Il riferimento funzionale è la modellazione CAD di base di Fusion 360.
Non sono inclusi nel primo traguardo CAM, simulazione, cloud collaborativo,
assiemi cinematici, superfici NURBS, slicing o invio diretto alla stampante.

## Base presente nello snapshot T00

- Progetto `FusionTakeoff.xcodeproj`, generato da `project.yml`, Swift 6, macOS 14+.
- `CADCore` separato dalla UI e verificabile con Swift Package Manager.
- Profili 2D, triangolazione ed estrusione; box, cilindro, esempio esagonale.
- Elenco di feature con quote e traslazione; anteprima SceneKit.
- Salvataggio/caricamento JSON `.ftk`; esportazione STL binario dalla UI,
  STL ASCII nel core; controllo base dei bordi della mesh.

Queste sono funzionalità presenti nel sorgente. L'esito di test e build è registrato
in `COLLAB.md`. Uno schizzo interattivo libero, un solver di vincoli, booleane,
undo/redo e 3MF richiedono i task successivi; l'elenco delle feature attuale
non costituisce ancora un albero di dipendenze parametriche tra operazioni.

## Contratti confermati

| Area | Contratto |
|---|---|
| Coordinate | Millimetri, sistema destrorso, Z verticale; conversione solo nel viewport |
| Geometria | `Vec2`, `Vec3`, `Profile2D`; mesh con vertici e indici `UInt32` |
| Facce | Triangoli CCW visti dall'esterno, normali uscenti |
| Modello nativo | Parametri/feature persistenti; mesh rigenerata, non fonte primaria del design |
| Core | Nessuna dipendenza AppKit, SwiftUI, SceneKit o Metal |
| UI | Italiano; identificatori e codice in inglese |
| Cooperazione | Claim prima delle scritture, messaggi append-only e verifica prima di `done` |

## Traguardi verificabili

| Fase | Risultato | Criterio di accettazione |
|---|---|---|
| Fondazione | Progetto e cooperazione riproducibili | Test core, build app, claim esclusivi, grafo aggiornato |
| Disegno | Rettangoli, cerchi, polilinee e quote | Profilo valido, selezione/editing, undo/redo e salvataggio senza perdita |
| Solidi | Estrusione, rivoluzione, unione/sottrazione | Volumi e dimensioni noti, normali coerenti, gestione esplicita degli errori |
| Stampa | STL/3MF e controllo delle dimensioni | Import nello slicer in mm, chiusura e orientamento; separare warning da errori |
| Distribuzione | App installabile | Firma, packaging e prova su un Mac; attività di release separata |

Campione minimo: prisma 40 × 30 × 20 mm, volume 24.000 mm³; cilindro con
dimensioni note, volume confrontato con il poligono tessellato; profilo concavo
semplice; parametri negativi/non finiti; salvataggio/riapertura; import nello slicer.
La tolleranza della tessellazione e le impostazioni della stampante vanno rese
esplicite prima di definire l'export pronto per produzione.

## Decisioni ancora aperte

1. **Mesh o B-rep per l'evoluzione CAD.** La mesh è adatta al primo prototipo.
   Per raccordi robusti, facce/curve esatte e STEP, valutare un kernel B-rep
   separato da UI e tessellazione. Open CASCADE offre modellazione solida,
   booleane e interscambio STEP; è un candidato, non una dipendenza già integrata.
   [Documentazione ufficiale OCCT](https://occt3d.com/dev/doc/overview/html/index.html).
2. **Rendering.** SceneKit serve la base iniziale; Apple ne dichiara la deprecazione.
   T07 propone Metal e richiede porting della mesh attiva e verifica UI/GPU.
   La variante nell'archivio non è automaticamente integrabile.
   [Indicazioni Apple](https://developer.apple.com/documentation/RealityKit/bringing-your-scenekit-projects-to-realitykit).
3. **Formato documenti.** Validare versione, limiti dimensionali, profili e unità
   all'ingresso, prima della geometria. Definire migrazioni quando cambiano le feature.
4. **Esportazione di corpi sovrapposti.** Concatenare triangoli non effettua
   un'unione booleana; un controllo dei soli bordi non rileva tutte le intersezioni.
5. **STL.** I valori delle coordinate sono in mm, ma il formato non possiede
   un campo unità standard. Il 3MF successivo deve dichiarare esplicitamente mm.

Ogni scelta che cambia le API o il formato richiede una voce DECISIONE in
`COLLAB.md` con motivazione, compatibilità, file interessati e agente responsabile.
Le tempistiche verranno stimate dopo il primo ciclo completo nello slicer.
