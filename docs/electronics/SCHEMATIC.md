# Schema elettrico — contratto del motore (T93)

27/09/2026. API additive compilanti; per risultati di collaudo vedere VALIDATION.md. Solo Foundation, nessuna dipendenza grafica o motore esterno.

## Documento e responsabilità

`ElectronicsDocument` scrive formato **3**, legge 1/2/3, conserva lo storico. `ElectronicsDesign.schematic: SchematicCircuit?` è nil nei vecchi documenti. Non cambiare `.ftk`. Non abbassare formatVersion: un vecchio lettore deve rifiutare gli schemi anziché perderli.

- Componente elettrico unico (`CircuitComponent.id`) condiviso con il PCB. Posizione del simbolo indipendente dalla posizione della sua impronta.
- `SchematicCircuit.sheets`: fogli con `id`, `name`, `parentID`, `symbols`, `junctions`, `wires`, `labels`.
- Un componente ha al massimo un simbolo nello schema; librerie multisezione e istanze gerarchiche riutilizzabili restano successive.
- `SchematicSymbol(componentID:position:rotationDegrees:mirrored:)`; mm, Y verso l’alto, CCW, specchio X locale prima della rotazione.
- `SchematicTerminal.pin(PinReference)` oppure `.junction(UUID)`: **identità**, mai coincidenza di coordinate.
- `SchematicWire(id:start:end:bends:)`: bends contiene soltanto i vertici intermedi; gli estremi seguono automaticamente pin e giunzioni quando si muovono.
- `SchematicLabel(id:terminal:netID:kind:offset:)`: kind `.net` oppure `.power`. Nome letto dalla rete; identico netID collega anche fogli distinti. Una scritta uguale non crea una connessione. Un’etichetta di alimentazione non dichiara una sorgente elettrica.
- `parentID` organizza i fogli in un albero/foresta senza cicli: non implica porte né ripetizione automatica di circuiti.

## Comandi: stessa chiamata per UI, assistente e MCP

Avvolgere `SchematicCommand` in `ElectronicsCommand.schematic(...)`, poi usare `ElectronicsCommands.preview/apply` con la **stessa identità dei dati e la baseRevision della preview**. Un batch è un passo di annulla. Nessuna modifica diretta a schematic, wireNets, generatedNetIDs o connections nell’app.

```swift
let sheet = SchematicSheet(name: "Principale")
let create = ElectronicsCommand.schematic(.addSheet(sheet))
let preview = try ElectronicsCommands.preview(create, document: document,
                                              expectedRevision: document.revision)
let drawing = try preview.schematicSnapshot(sheetID: sheet.id)
try ElectronicsCommands.apply(create, to: &document, expectedRevision: preview.baseRevision)

// a e b sono componentID già nel circuito; le librerie devono avere le posizioni dei pin.
let place = ElectronicsCommand.schematic(.batch([
    .placeSymbol(sheetID: sheet.id, symbol: .init(componentID: a, position: .init(10, 10))),
    .placeSymbol(sheetID: sheet.id, symbol: .init(componentID: b, position: .init(30, 10)))
]))
// preview / conferma come sopra

let wire = SchematicWire(start: .pin(pinA), end: .pin(pinB), bends: [.init(20, 10)])
let connect = ElectronicsCommand.schematic(.addWire(sheetID: sheet.id, wire: wire))
```

Catalogo:

- `.addSheet(SchematicSheet)`, `.renameSheet(id:name:)`, `.removeSheet(UUID)` (rifiuta se ha figli).
- `.placeSymbol(sheetID:symbol:)`, `.moveSymbol(componentID:to:)`, `.rotateSymbol(componentID:by:)`, `.mirrorSymbol(UUID)`, `.removeSymbol(UUID)`.
- `.addJunction(sheetID:junction:)`, `.moveJunction(id:to:)`, `.removeJunction(UUID)`.
- `.addWire(sheetID:wire:)`, `.setWireBends(id:bends:)`, `.removeWire(UUID)`.
- `.splitWire(id:junction:newWireID:)`: la giunzione deve essere sul percorso; primo segmento mantiene il vecchio ID. Usare `.batch([.splitWire(...), .addWire(...)])` per una diramazione atomica. Per un incrocio elettrico dividere esplicitamente i fili sulla stessa giunzione (aggiungere la seconda diramazione tramite terminali esistenti).
- `.addLabel(sheetID:label:net:)`, `.removeLabel(UUID)`; net è `CircuitNet`, esistente o nuova, con lo stesso ID di label.netID.
- `.batch([SchematicCommand])`: massimo 1000 figli per livello, profondità limitata; errore in un figlio annulla l’intero batch.

Per creare direttamente sullo schema in **un solo undo** usare `ElectronicsCommand.addSchematicComponent(component:sheetID:symbol:library:)`, oppure `template.schematicCommand(componentID:reference:value:sheetID:position:)`. Il componente nasce senza posizione PCB inventata; `BoardConnectivity.unplacedComponents` lo segnala. Poi `ElectronicsCommand.placeComponent(ComponentPlacement)` lo posa sul PCB, mantenendo lo stesso componentID. Per componenti PCB preesistenti usare `.placeSymbol` senza crearne un duplicato. Per NC usare `.markNoConnect([pin])`; `.disconnect` rimuove un NC esplicito. I comandi del PCB non cambiano il disegno dello schema.

## Connettività e cancellazione

L’ingresso del primo comando schematico conserva i collegamenti preesistenti in `directConnections`. Il motore unisce questi collegamenti indipendenti alla connettività dei fili, e aggiorna `design.connections`: PCB, ERC e export continuano a usare quella netlist.

- Gli incroci, i vertici sovrapposti e un filo che passa sopra un pin NON collegano nulla da soli. La UI deve usare l’ID del terminale scelto dallo snap.
- I fili con terminale comune formano un gruppo. Senza etichetta/collegamento diretto, il motore assegna una rete N# con UUID deterministico e la conserva mentre il gruppo si estende o si muove.
- Rinomina esplicita con `.renameNet` conserva la rete come vincolo nominato (anche senza etichetta disegnata); reti nominate diverse non vengono fuse.
- Rimuovere un ponte separa le reti automatiche; le isole non rimangono collegate perché avevano lo stesso ID prima della modifica.
- Etichette/directConnections sono vincoli espliciti: due gruppi che nominano la stessa rete restano collegati; reti esplicite diverse unite da un filo producono errore, nessuna fusione implicita.
- Rimuovere un filo toglie solo la connettività prodotta dallo schema. Non cancella un collegamento diretto precedente. Rimuovere un simbolo lascia il componente nel PCB ma toglie fili ed etichette attaccati al simbolo. `.removeComponent` rimuove anche il simbolo.
- `.disconnect` su pin con filo/etichetta e `.removeNet` su rete usata dallo schema sono rifiutati: la UI deve proporre di modificare lo schema.
- NC + filo/etichetta viene rifiutato. La sola cancellazione di un filo non aggiunge NC.

## Disegno, selezione, agganci

```swift
let drawing = try ElectronicsSchematic.snapshot(document, sheetID: sheet.id)
let hits = drawing.pick(point, tolerance: mmPerScreenPoint * 8,
                        filter: [.pin, .wire, .symbol, .junction, .label])
let snaps = drawing.snapTargets(near: point, radius: mmPerScreenPoint * 11, grid: 1.27)
```

Costruire e conservare lo snapshot per revisione/foglio; non ricostruirlo a ogni movimento del mouse. Per l’anteprima usare `ElectronicsCommandPreview.schematicSnapshot(sheetID:)`. Gli input sono valori Sendable; snapshot e preview possono essere costruiti fuori dal main actor.

`SchematicSnapshot`: revision, sheetID, primitives, pins, issues, indice spaziale BVH interno.
`SchematicPrimitive`: owner, shape, style, strokeWidth, filled.
`SchematicShape`: `.polyline([PCBPoint], closed: Bool)`, `.circle(center:radius:)`, `.text(String, at:height:)`.
Stili semantici: symbol, pin, wire, junction, reference, value, pinName, pinNumber, label, power, noConnect. **I colori li decide Claude**. La UI inverte Y nella trasformazione verso lo schermo; non rigenera pin, fili o geometrie.

Owner: kind/id/sheetID/componentID/pinID/netID. La coppia componentID+pinID identifica un pin; mai usare il solo pinID della libreria. Per un click sul filo, SchematicPick.object.id è il wireID e snap.kind `.onWire` fornisce la posizione per splitWire. Snap prioritario: pin, giunzione, vertice, punto medio, punto sul filo; griglia soltanto in assenza di geometria nel raggio. Pick ordinato per priorità, distanza e identità stabile. Il testo ha una stima di ingombro; metriche tipografiche esatte restano al renderer.

## Verifiche

ERC aggiunge, quando lo schema è presente: simboli non posizionati, rete con un solo pin, ingresso senza driver, alimentazione senza sorgente dichiarata, giunzioni sospese. Messaggi italiani, codici stabili, subjectIDs e posizione; non è simulazione analogica né matrice ERC completa configurabile.

## Import richiesto da Claude

`KiCadLibraryImporter.symbolNames(_ data: Data) throws -> [String]` usa il parser ufficiale, elenca soltanto simboli top-level, ordine deterministico, rifiuta duplicati e input malformati. Importatori e risultati sono puri/Sendable, senza stato globale mutabile; usarli in task fuori dal MainActor e rispettare cancellazione. Conservare document.revision al lancio e usare quella alla conferma, anche se l’import finisce più tardi.

Licenza sconosciuta: “da verificare” descrive lo stato, non concede diritti. `source.reference` identifica il file scelto; data di modifica può essere `sourceRevision` locale dichiarata come tale, non una release upstream. L’hash viene dal parser. Non inventare licenze o codici acquistabili.

## Limiti attuali

Non ci sono bus, porte gerarchiche, istanze ripetute, simboli multisezione, simulatore, auto-router né rame. La gerarchia di fogli e le etichette globali sono esplicite; non presentarle come gerarchia parametrica completa. Le entità geometriche vanno posate tramite snapshot/snap e preview; nessun algoritmo deve essere duplicato nel Model/UI.
