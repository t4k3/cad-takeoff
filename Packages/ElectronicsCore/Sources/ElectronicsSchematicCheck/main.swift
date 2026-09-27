import ElectronicsCore
import Foundation

@main
struct SchematicCheck {
    struct PinSample: Codable { let componentID: UUID; let pinID: UUID; let position: PCBPoint; let netID: UUID? }
    struct Metrics: Codable {
        let components: Int; let primitives: Int; let snapshotMS: Double
        let queryCount: Int; let pickSnapP95MS: Double; let pickSnapMaxMS: Double
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ElectronicsFailure([.init("usage","schema","electronics-schematic cartella-output-nuova")]) }
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ElectronicsFailure([.init("output_exists","schema","Cartella già presente.")]) }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        func save<T:Encodable>(_ object:T,_ name:String) throws { try encoder.encode(object).write(to:output.appendingPathComponent(name),options:.atomic) }
        func id(_ n:Int)->UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012x",n))! }
        let template=ElectronicsStarterLibrary.components[0], pin=template.library.symbols[0].pins[0].id
        var d=try ElectronicsDocument.empty()
        func command(_ c:ElectronicsCommand) throws { try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision) }
        for i in 0..<4 { try command(template.command(componentID:id(i+1),reference:"R\(i+1)",position:.init(Double(i)*10,10))) }
        let sheet=SchematicSheet(id:id(100),name:"Schema di verifica",symbols:(0..<4).map {
            .init(componentID:id($0+1),position:.init(Double($0)*20+10,10))
        })
        try command(.schematic(.addSheet(sheet)))
        let pins=(1...4).map { PinReference(componentID:id($0),pinID:pin) }
        let wires=(0..<3).map { SchematicWire(id:id(200+$0),start:.pin(pins[$0]),end:.pin(pins[$0+1])) }
        try command(.schematic(.batch(wires.map { .addWire(sheetID:sheet.id,wire:$0) })))
        try save(d,"joined.ftkc")
        try command(.schematic(.removeWire(wires[1].id)))
        try save(d,"split.ftkc")
        try command(.schematic(.batch([.moveSymbol(componentID:id(1),to:.init(5,6)),.rotateSymbol(componentID:id(1),by:90),.mirrorSymbol(id(1))])))
        let snapshot=try ElectronicsSchematic.snapshot(d,sheetID:sheet.id)
        try save(d,"transformed.ftkc")
        try save(snapshot.pins.map { PinSample(componentID:$0.reference.componentID,pinID:$0.reference.pinID,position:$0.position,netID:$0.netID) },"pins.json")
        let reopened=try ElectronicsDocument.decode(d.encoded())
        guard reopened == d else { throw ElectronicsFailure([.init("roundtrip","schema","Round-trip non identico.")]) }
        // Synthetic large drawing; no repeated history construction in the benchmark setup.
        let count=1000
        let components=(0..<count).map { CircuitComponent(id:id(1000+$0),reference:"R\($0+1)",value:"10k",device:template.device) }
        var large=try ElectronicsDocument(design:.init(name:"Prestazioni schema",library:template.library,components:components,
            board:.init(outline:[.init(),.init(100,0),.init(100,100),.init(0,100)])))
        let largeSheet=SchematicSheet(id:id(99999),name:"1000 simboli",symbols:components.enumerated().map { i,c in
            .init(componentID:c.id,position:.init(Double(i%40)*20,Double(i/40)*15))
        })
        try ElectronicsCommands.apply(.schematic(.addSheet(largeSheet)),to:&large,expectedRevision:large.revision)
        let t=ProcessInfo.processInfo.systemUptime
        let drawing=try ElectronicsSchematic.snapshot(large,sheetID:largeSheet.id)
        let snapshotMS=(ProcessInfo.processInfo.systemUptime-t)*1000
        var times:[Double]=[]
        for i in 0..<1000 {
            let p=drawing.pins[(i*17)%drawing.pins.count].position
            let start=ProcessInfo.processInfo.systemUptime
            guard !drawing.pick(p,tolerance:0.75).isEmpty, drawing.snapTargets(near:p,radius:1).first?.kind == .pin else {
                throw ElectronicsFailure([.init("query_failed","schema","Selezione pin non trovata.")])
            }
            times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        times.sort()
        let metrics=Metrics(components:count,primitives:drawing.primitives.count,snapshotMS:snapshotMS,
                            queryCount:times.count,pickSnapP95MS:times[949],pickSnapMaxMS:times.last!)
        try save(metrics,"metrics.json")
        print("PASS schema: documenti collegato/separato/trasformato e round-trip; \(count) simboli, \(drawing.primitives.count) primitive, snapshot \(snapshotMS) ms, pick+snap p95 \(times[949]) ms.")
    }
}
