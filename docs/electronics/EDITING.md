# Circuiti — strumenti di costruzione, contratto T93

27/09/2026. Priorità dopo la prova di Ross: costruire un circuito da un documento vuoto. Le API sotto sono implementate nel motore da Codex per l’aggancio T97 di Claude. Lo stato del collaudo viene riportato in COLLAB; questa pagina non attesta da sola la presenza dei pulsanti nell’app.

## API additive per l’app

```swift
// Vuoto significa senza componenti e senza librerie inserite a sorpresa.
ElectronicsDocument.empty(name: String = "Nuovo circuito",
    outline: [PCBPoint] = [.init(0,0), .init(50,0), .init(50,30), .init(0,30)]) throws -> ElectronicsDocument

ElectronicsCommands.preview(_ command: ElectronicsCommand, document: ElectronicsDocument,
    expectedRevision: UInt64) throws -> ElectronicsCommandPreview
ElectronicsCommands.apply(_ command: ElectronicsCommand, to: inout ElectronicsDocument,
    expectedRevision: UInt64) throws

// Preview: baseRevision, design, board: BoardConnectivity, issues: [ElectronicsIssue].
// Conservare il comando e baseRevision: OK conferma quel comando con quella revisione.
// Esc scarta la preview; l’originale non è modificato. Una conferma = un undo.
```

`ElectronicsCommand` è Codable/Sendable e comprende:

```swift
case library(ElectronicsLibraryCommand)
case addComponent(component: CircuitComponent, placement: ComponentPlacement, library: ElectronicsLibrary)
case updateComponent(CircuitComponent)
case removeComponent(UUID)
case moveComponent(id: UUID, to: PCBPoint)
case rotateComponent(id: UUID, by: Double)
case setComponentSide(id: UUID, side: BoardSide)
case flipComponent(UUID)
case setBoard(outline: [PCBPoint], thickness: Double, assemblyOrigin: PCBPoint)
case addNet(CircuitNet)
case renameNet(id: UUID, name: String)
case removeNet(UUID)
case connect(pins: [PinReference], net: CircuitNet)
case disconnect([PinReference])
case markNoConnect([PinReference])
```

Una connessione crea eventualmente la rete e collega i pin in una sola transazione. Non fonde né sostituisce reti diverse implicitamente: un pin già assegnato a un’altra rete dà errore, da scollegare esplicitamente. `disconnect` toglie l’assegnazione, mentre `markNoConnect` è una scelta NC esplicita. Rimuovere una rete scollega i suoi pin, non li marca NC. Eliminare un componente rimuove in un solo undo posizionamento, collegamenti e riferimenti nelle varianti; conserva le definizioni di libreria.

```swift
ElectronicsCommands.nextReference(prefix: String, in design: ElectronicsDesign) -> String
ElectronicsCommands.pins(of componentID: UUID, in design: ElectronicsDesign) throws -> [ElectronicsPin]
// ElectronicsPin: reference: PinReference, number: String, name: String,
// electricalType: PinElectricalType, netID: UUID?, explicitlyUnconnected: Bool.

ElectronicsStarterLibrary.components: [ElectronicsStarterComponent]
// Template: id: String, name: String, referencePrefix: String, defaultValue: String,
// library: ElectronicsLibrary, device: LibraryRevision.
template.command(componentID: UUID = UUID(), reference: String, value: String? = nil,
    position: PCBPoint, side: BoardSide = .top) -> ElectronicsCommand
```

La libreria iniziale contiene modelli generici nativi: resistenza 0603, condensatore 0603, connettore a due pin passo 2,54 mm. Servono a progettare senza un file dimostrativo. Sono dati generici da verificare contro il componente fisico; nessun MPN acquistabile o codice JLC simulato, montaggio manuale predefinito. La scelta di un componente reale resta il percorso import/catalogo E1.

## Prova congiunta richiesta

1. Nuovo circuito, strumenti visibili **Componente**, **Collega**, **Scheda**, **Elimina**, oltre a Ruota/Lato.
2. Componente: scelta fra libreria del documento e modelli generici, sigla/valore/posizione, anteprima, OK/Annulla. Creazione libreria + componente + posizionamento in un unico undo.
3. Collega: scegliere due pin per identità e rete esistente/nuova. Mostrare la connessione logica (airwire), senza chiamarla pista di rame.
4. Scheda: cambiare contorno/spessore/origine, preview e controllo input; un contorno invalido lascia intatto il documento.
5. Modificare/ruotare/cambiare lato/eliminare e annullare, salvare `.ftkc`, riaprire e verificare pin e storico.

Schema grafico, routing, DRC completo, primitive render e pick/snap indicizzati non sono compresi in questa prima serie di comandi. I test di questa serie non certificano un PCB producibile. L’interfaccia non deve visualizzare «nessun problema» come sinonimo di completamento del circuito.
