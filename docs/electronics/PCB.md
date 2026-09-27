# PCB nativo — contratto T94

Stato: primo traguardo del motore collaudato automaticamente (88 test totali e quattro lettori indipendenti). Integrazione e collaudo UI T97 separati. Il motore non dipende da librerie esterne.

## Dati e transazioni

- `PCBBoard.copper: PCBCopper?`: assente nei vecchi documenti; equivale a due strati senza piste.
- `PCBCopper(layerCount: 2, rules: .init(), tracks: [], vias: [])`.
- `PCBTrack(id: UUID, netID: UUID, layer: Int, width: Double, points: [PCBPoint])`.
- `PCBVia(id: UUID, netID: UUID, position: PCBPoint, diameter: Double, drill: Double)` passante.
- Strati numerati dall'alto: `0` superiore, `layerCount - 1` inferiore; da 2 a 32 strati, numero pari.
- `PCBDesignRules(clearance: 0.2, edgeClearance: 0.25, minimumTrackWidth: 0.2,
  minimumDrill: 0.3, minimumAnnularRing: 0.15)`: valori di partenza del progetto,
  **non una qualificazione JLCPCB**. La clearance vale anche come distanza minima fra fori. Millimetri, geometria vista dall'alto.
- `ElectronicsCommand.pcb(PCBCommand)` con `addTrack`, `updateTrack`, `removeTrack(UUID)`,
  `addVia`, `updateVia`, `removeVia(UUID)`, `configure(layerCount:rules:)`, `batch([PCBCommand])`.
  Il batch produce un unico passo Annulla, con revisione controllata e rollback totale.
- Formato documento 4, lettura di 1–4, storico persistente incluso.

## Contratto UI

`ElectronicsPCB.snapshot(document)` oppure `snapshot(design:revision:)` produce `PCBSnapshot`:
`designID`, `revision`, `layerCount`, `primitives`, `board` (piazzole/airwire/componenti da posare), `issues`.
`ElectronicsCommandPreview.pcbSnapshot()` costruisce lo stesso disegno sulla candidata.
Costruire in background e conservare per (designID, revisione). Le selezioni di snapshot vecchi sono invalide.

Primitive `PCBCopperPrimitive`: `item: PCBItem` (`pad(componentID:padID:)`, `track(UUID)`, `via(UUID)`),
`netID`, `layers`, `core: [PCBPoint]`, `radius`, `drillDiameter`.
Il rame è la somma del nucleo convesso (punto, segmento o poligono) e un disco di `radius`.
Questo descrive senza discretizzazione cerchi, capsule, rettangoli, ovali e rettangoli arrotondati.
Renderizzare riempimento del nucleo e contorno con spessore `2 * radius`, estremità e giunti tondi.
La foratura è un disco al centro della primitiva; tutti i fori supportati sono circolari e metallizzati.
Una pista genera una capsula per segmento, tutte con lo stesso ID.

`snapshot.pick(point:tolerance:layer:)` restituisce `[PCBHit]` con item, netID, position, distance.
`snapshot.snapTargets(near:radius:layer:netID:grid:)` privilegia piazzole, via, estremità delle piste
e proiezioni sulle piste della rete, poi griglia. Distanze in mm: la UI converte circa 11 px.
`ElectronicsPCB.routePoints(from:to:diagonalFirst:)` propone segmenti a 45/90°; non aggira ostacoli.
`simplifiedPoints(_:)` rimuove duplicati e punti collineari senza eliminare inversioni;
`gridPoint(_:spacing:)` restituisce lo snap alla griglia o nil per dati non validi.
Ogni pista/via della sessione deve conservare lo stesso UUID fra preview e conferma.

Le anteprime geometricamente valide possono contenere errori DRC: usare `preview.canApply` e `preview.blockingIssues` per abilitare OK ed evidenziare il motivo. ERC e collegamenti ancora da completare non impediscono di sbrogliare.
`apply` rifiuta errori DRC sui nuovi elementi o sugli elementi modificati; eliminazioni e modifiche
dei componenti restano possibili, con diagnostica aggiornata. Non muove o riassegna piste di nascosto.
Gli errori hanno codice stabile, soggetti UUID e posizione, da evidenziare nella tela.

## Verifica fisica

Le airwire collegano isole di rame ancora separate della stessa rete, usando i centri delle piazzole come estremi. Non sono ancora ottimizzate verso le estremità delle piste parziali. Un incrocio su strati
diversi non conduce senza via o pad passante. Un corto viene segnalato, mai usato per fondere reti.
Le distanze considerano larghezze reali, forme delle piazzole e rotazioni, non solo linee centrali.
Il perimetro può essere concavo; il rame deve essere dentro e rispettare la distanza dal bordo. Tolleranza numerica di contatto: `1e-8` mm; non è una tolleranza di produzione. Il foro vuoto non conduce: una pista interamente nella foratura non collega il pad.

Non inclusi: piani/pour, blind/buried via, stackup dielettrico/impedenza, push-and-shove,
autorouter, tuning differenziale, fori ovali, regole copper-to-hole separate, solder mask DRC, Gerber e rilascio produttivo.
Riferimento funzionale studiato: [documentazione ufficiale KiCad, router interattivo](https://docs.kicad.org/9.0/it/pcbnew/pcbnew.html#routing-tracks).
Nessun sorgente KiCad incorporato.
