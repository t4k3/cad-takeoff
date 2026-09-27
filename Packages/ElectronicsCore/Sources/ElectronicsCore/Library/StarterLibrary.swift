import Foundation

public struct ElectronicsStarterComponent: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let referencePrefix: String
    public let defaultValue: String
    public let library: ElectronicsLibrary
    public let device: LibraryRevision

    public func schematicCommand(componentID: UUID = UUID(), reference: String, value: String? = nil,
                                 sheetID: UUID, position: PCBPoint) -> ElectronicsCommand {
        .addSchematicComponent(component: .init(id: componentID, reference: reference, value: value ?? defaultValue, device: device),
                               sheetID: sheetID, symbol: .init(componentID: componentID, position: position), library: library)
    }

    public func command(componentID: UUID = UUID(), reference: String, value: String? = nil,
                        position: PCBPoint, side: BoardSide = .top) -> ElectronicsCommand {
        let component = CircuitComponent(id: componentID, reference: reference, value: value ?? defaultValue, device: device, assembly: .manual)
        return .addComponent(component: component, placement: .init(componentID: componentID, position: position, side: side), library: library)
    }
}

/// Native generic drawing templates, not supplier SKUs. No catalog identities, availability,
/// rotation calibration or 3D models are invented. All identities and revisions are repeatable.
public enum ElectronicsStarterLibrary {
    public static let components: [ElectronicsStarterComponent] = [
        make("resistor-0603", name: "Resistenza 0603", prefix: "R", value: "10k"),
        make("capacitor-0603", name: "Condensatore 0603", prefix: "C", value: "100nF"),
        make("header-1x02-254", name: "Connettore 1×02 · 2,54 mm", prefix: "J", value: "1×02", throughHole: true)
    ]

    private static func make(_ slug: String, name: String, prefix: String, value: String,
                             throughHole: Bool = false) -> ElectronicsStarterComponent {
        let namespace = UUID(uuidString: "743C8D98-48BF-4B1F-8F77-0B5F5C01C010")!
        func id(_ path: String) -> UUID { LibraryImportSupport.id(namespace, slug + "/" + path) }
        let source = LibrarySource(reference: "CAD Takeoff / native generic template / " + slug,
                                   license: "Dati generati internamente; condizioni del progetto", sourceRevision: "1")
        let pins = (1...2).map { number -> SymbolPin in
            var pin = SymbolPin(id: id("pin/\(number)"), name: String(number), electricalType: .passive)
            pin.number = String(number); pin.position = .init(number == 1 ? -3.81 : 3.81, 0)
            pin.rotationDegrees = number == 1 ? 0 : 180; pin.length = 1.27; pin.graphicStyle = "line"; pin.unit = 1
            return pin
        }
        var symbol = SymbolDefinition(key: .init(id: id("symbol")), name: name, pins: pins, source: source)
        if prefix == "C" {
            symbol.graphics = [
                .init(id: id("symbol/plate1"), kind: .line, points: [.init(-0.5,-1.5), .init(-0.5,1.5)], layer: "symbol", strokeWidth: 0.2),
                .init(id: id("symbol/plate2"), kind: .line, points: [.init(0.5,-1.5), .init(0.5,1.5)], layer: "symbol", strokeWidth: 0.2),
                .init(id: id("symbol/lead1"), kind: .line, points: [.init(-2.54,0), .init(-0.5,0)], layer: "symbol", strokeWidth: 0.2),
                .init(id: id("symbol/lead2"), kind: .line, points: [.init(0.5,0), .init(2.54,0)], layer: "symbol", strokeWidth: 0.2)
            ]
        } else {
            symbol.graphics = [.init(id: id("symbol/body"), kind: .rectangle,
                                     points: [.init(-2.54,-1.0), .init(2.54,1.0)], layer: "symbol", strokeWidth: 0.2)]
        }
        let pads = (1...2).map { number -> FootprintPad in
            var pad: FootprintPad
            if throughHole {
                pad = .init(id: id("pad/\(number)"), number: String(number), center: .init(0, number == 1 ? 0 : -2.54),
                            size: .init(1.7, 1.7), shape: number == 1 ? .rectangle : .circle, drillDiameter: 1.0)
                pad.sourceLayers = ["*.Cu", "*.Mask"]
            } else {
                pad = .init(id: id("pad/\(number)"), number: String(number), center: .init(number == 1 ? -0.825 : 0.825, 0),
                            size: .init(0.8, 0.95), shape: .roundedRectangle)
                pad.cornerRadius = 0.2; pad.sourceLayers = ["F.Cu", "F.Mask", "F.Paste"]
            }
            return pad
        }
        var footprint = FootprintDefinition(key: .init(id: id("footprint")), name: throughHole ? "Generic_Header_1x02_P2.54" : "Generic_0603_1608Metric",
                                             pads: pads, assemblyCentroid: throughHole ? .init(0,-1.27) : .init(), source: source)
        footprint.properties = ["qualification": "generic-unverified"]
        footprint.graphics = [.init(id: id("footprint/body"), kind: .rectangle,
                                    points: throughHole ? [.init(-1.27,1.27), .init(1.27,-3.81)] : [.init(-0.8,-0.4), .init(0.8,0.4)],
                                    layer: "F.Fab", strokeWidth: 0.1)]
        let device = DeviceDefinition(key: .init(id: id("device")), manufacturer: "Generico — da qualificare", manufacturerPartNumber: "GENERIC-" + slug,
                                      symbol: symbol.key, footprint: footprint.key,
                                      pinMap: zip(pins, pads).map { .init(pinID: $0.id, padID: $1.id) })
        return .init(id: slug, name: name, referencePrefix: prefix, defaultValue: value,
                     library: .init(symbols: [symbol], footprints: [footprint], devices: [device]), device: device.key)
    }
}
