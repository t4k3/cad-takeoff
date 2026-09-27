# CAD Takeoff — progetto progressivo

Revisione 3 · 25 settembre 2026 · requisiti T24, decisione sulle dipendenze T71.
Stato operativo aggiornato: [grafo attività](../graph/GRAPH.md).
Ordine di sviluppo: [roadmap approvata](../ROADMAP.md), un passo alla volta.

**Fondamentali: storico parametrico persistente, parti e assiemi, modulo lamiera
completo rispetto alla matrice concordata.** Specifica autorevole della nuova
direzione: [Requisiti CAD](../requirements/CAD_SCOPE_V2.md).

## Prodotto

Applicazione macOS per progettare parti meccaniche, lamiera e assiemi, con storico
modificabile. Flusso obiettivo: schizzi/parametri → feature CAD → parti/istanze e
assiemi → verifica → STEP, STL/3MF oppure sviluppo lamiera/DXF/tavole di piega.

Il riferimento funzionale comprende ora la lamiera di Fusion e il lavoro con
parti/assiemi. La precedente esclusione degli assiemi cinematici è superata.
CAM completo, FEA, cloud/PDM, nesting automatico e slicing restano fuori da questa
revisione; le funzioni avanzano per fasi, mantenendo tutti i requisiti nel grafo.

## Base presente nello snapshot T00

- Progetto `FusionTakeoff.xcodeproj`, generato da `project.yml`, Swift 6, macOS 27+.
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
| Modello nativo | Storico e dipendenze persistenti, parti e istanze con ID distinti; migrazione della base iniziale da implementare |
| Core | Nessuna dipendenza AppKit, SwiftUI, SceneKit o Metal |
| UI | Italiano; identificatori e codice in inglese |
| Cooperazione | Claim prima delle scritture, messaggi append-only e verifica prima di `done` |

## Traguardi verificabili

| Fase | Risultato | Criterio di accettazione |
|---|---|---|
| Fondazione | Progetto e cooperazione riproducibili | Test core, build app, claim esclusivi, grafo aggiornato |
| Fondazione CAD | Kernel, storico e componenti | Rebuild deterministico, riferimenti stabili, rollback e riapertura senza perdita |
| Disegno | Rettangoli, cerchi, polilinee e quote | Profilo valido, selezione/editing, undo/redo e salvataggio senza perdita |
| Solidi | Estrusione, rivoluzione, unione/sottrazione | Volumi e dimensioni noti, normali coerenti, gestione esplicita degli errori |
| Assiemi | Parti riutilizzabili, sottoassiemi, vincoli/giunti e distinta | Modifica parte propagata alle istanze, DOF e riferimenti verificati |
| Lamiera | Regole, flange/pieghe, lavorazioni, sviluppo e documenti | Matrice SM01–SM17 e corpus di accettazione verificati |
| Stampa | STL/3MF e controllo delle dimensioni | Import nello slicer in mm, chiusura e orientamento; separare warning da errori |
| Distribuzione | App installabile | Firma, packaging e prova su un Mac; attività di release separata |

Campione minimo: prisma 40 × 30 × 20 mm, volume 24.000 mm³; cilindro con
dimensioni note, volume confrontato con il poligono tessellato; profilo concavo
semplice; parametri negativi/non finiti; salvataggio/riapertura; import nello slicer.
La tolleranza della tessellazione e le impostazioni della stampante vanno rese
esplicite prima di definire l'export pronto per produzione.

## Decisioni e verifiche architetturali

1. **Kernel nostro per l'evoluzione CAD.** Sviluppare T70 in `CADCore`, separato
   da UI e tessellazione, partendo da solidi a facce piane. La mesh resta un
   risultato derivato. OpenCascade è escluso dal piano e T26/T62 sono annullati.
   Librerie esterne solo se strettamente necessarie: valgono le
   [regole sulle dipendenze](../requirements/DEPENDENCY_POLICY.md).
   Precisione, rimappatura dei riferimenti e robustezza sono criteri da verificare;
   metadati di superficie non rendono esatte le approssimazioni sfaccettate.
2. **Rendering.** Lo snapshot T00 sopra descriveva SceneKit. T07 è stato completato
   da Claude con un viewport Metal; stato e prove sono nel registro. Il rendering
   è separato dalla futura geometria CAD e non decide il modello dei documenti.
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

## Priorità aggiornata: assistente geometrico

La chat e i connettori MCP sono la prima consegna. Claude cura UX e Anthropic;
Codex strumenti geometrici e OpenAI/ChatGPT. Il [contratto assistente](../requirements/AI_ASSISTANT.md)
definisce l accesso unico al Model e i controlli di revisione. Lamiera, storico,
parti e assiemi restano requisiti fondamentali, implementati progressivamente.
