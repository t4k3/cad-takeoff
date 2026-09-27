import Foundation
import ElectronicsCore

enum PCBThermalCheck {
    struct Metrics: Codable { let pads: Int; let cells: Int; let snapshotMS: Double; let queryP95MS: Double? }
    static func run(in output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        func save<T:Encodable>(_ item: T, _ name: String) throws { try encoder.encode(item).write(to:output.appendingPathComponent(name),options:.atomic) }
        func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"EEEE0000-0000-4000-8000-%012d",n))! }
        func rect(_ x: Double,_ y: Double,_ w: Double,_ h: Double) -> [PCBPoint] { [.init(x,y),.init(x+w,y),.init(x+w,y+h),.init(x,y+h)] }
        var d = try ElectronicsDocument.empty(name:"Collaudo termiche")
        func apply(_ c: ElectronicsCommand) throws { try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision) }
        func capture(_ name: String) throws {
            let s = try ElectronicsPCB.snapshot(d)
            try save(d,"thermals-\(name).ftkc")
            try save(PCBZoneCheck.Export(board:s.board,zones:s.zones,primitives:s.primitives,issues:s.issues),"thermals-\(name).json")
        }
        for n in 0..<4 {
            try apply(ElectronicsStarterLibrary.components[0].command(componentID:id(n+1),reference:"R\(n+1)",position:.init(n%2 == 0 ? 8:40,n/2 == 0 ? 8:22)))
        }
        let pads = try ElectronicsConnectivity.snapshot(d.design).pads
        let pins = (1...4).map { n in pads.filter { $0.componentID == id(n) }.max { $0.center.x < $1.center.x }! }
        let net = CircuitNet(id:id(10),name:"GND"), foreign = CircuitNet(id:id(11),name:"POWER")
        try apply(.connect(pins:pins.map { .init(componentID:$0.componentID,pinID:$0.pinID) },net:net))
        try apply(.addNet(foreign))
        try apply(.pcb(.addTrack(.init(id:id(12),netID:foreign.id,layer:0,width:0.5,points:[.init(12,15),.init(38,15)]))))
        var z = PCBZone(id:id(20),name:"Massa termica",netID:net.id,layer:0,outline:rect(1,1,48,28),removeIslands:false,thermalGap:0.4,thermalSpokeWidth:0.4,minimumSpokes:4)
        try apply(.pcb(.addZone(z))); try capture("solid")
        z.connection = .thermal; try apply(.pcb(.updateZone(z))); try capture("connected")
        z.minimumWidth = 0.2; try apply(.pcb(.updateZone(z))); try capture("filtered")
        let p = pins[0]
        try apply(.pcb(.addKeepout(.init(id:id(30),name:"Taglio parziale ponticello",outline:rect(p.center.x+p.size.x/2+0.08,p.center.y+0.04,0.06,0.07),layers:[0],tracks:false,vias:false,pads:false))))
        try capture("starved")
        d = try ElectronicsDocument.decode(d.encoded())
        try d.undo(expectedRevision:d.revision); try capture("undo")
        try d.redo(expectedRevision:d.revision); try capture("redo")
        z.connection = .none; z.minimumWidth = 0
        try apply(.pcb(.updateZone(z))); try capture("isolated")
        for (name,neck,length,width) in [("raw",0.4,20.0,0.0),("narrow",0.4,20.0,1.0),("wide",2.0,20.0,1.0),("pinch",0.8,0.02,1.0)] {
            var design = try ElectronicsDocument.empty(name:"Collo \(name)").design
            design.nets = [net]
            let a = 25-length/2, b = 25+length/2, y0 = 15-neck/2, y1 = 15+neck/2
            let outline: [PCBPoint] = [.init(1,1),.init(a,1),.init(a,y0),.init(b,y0),.init(b,1),.init(49,1),.init(49,29),.init(b,29),.init(b,y1),.init(a,y1),.init(a,29),.init(1,29)]
            design.board.copper = .init(zones:[.init(id:id(20),netID:net.id,layer:0,outline:outline,removeIslands:false,minimumWidth:width)])
            let s = try ElectronicsPCB.snapshot(design:design,revision:0)
            try save(PCBZoneCheck.Export(board:s.board,zones:s.zones,primitives:s.primitives,issues:s.issues),"width-\(name).json")
        }
        // Full snapshot includes fill, DRC, electrical connectivity, and spatial indices.
        let measured = try ElectronicsDocument.decode(Data(contentsOf:output.appendingPathComponent("thermals-filtered.ftkc")))
        let start = ProcessInfo.processInfo.systemUptime
        let s = try ElectronicsPCB.snapshot(measured), elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        var times: [Double] = []
        for n in 0..<1000 {
            let p = PCBPoint(Double(n%50)+0.123,Double(n%30)+0.321), t = ProcessInfo.processInfo.systemUptime
            _ = s.pick(point:p,tolerance:0.25,layer:0)
            _ = s.pickZones(point:p,tolerance:0.25,layer:0)
            _ = s.snapTargets(near:p,radius:0.5,layer:0,netID:net.id)
            times.append((ProcessInfo.processInfo.systemUptime-t)*1000)
        }
        times.sort()
        try save(Metrics(pads:s.zones[0].thermals.count,cells:s.zones[0].cells.count,snapshotMS:elapsed,queryP95MS:times[949]),"thermals-metrics.json")
        var dense = try ElectronicsDocument.empty(name:"16 termiche filtrate")
        for n in 0..<16 {
            try ElectronicsCommands.apply(ElectronicsStarterLibrary.components[0].command(componentID:id(100+n),reference:"R\(n+1)",position:.init(4+Double(n%4)*13,3+Double(n/4)*8)),to:&dense,expectedRevision:dense.revision)
        }
        let densePads = try ElectronicsConnectivity.snapshot(dense.design).pads
        let densePins = (0..<16).map { n in densePads.filter { $0.componentID == id(100+n) }.max { $0.center.x < $1.center.x }! }
        try ElectronicsCommands.apply(.connect(pins:densePins.map { .init(componentID:$0.componentID,pinID:$0.pinID) },net:net),to:&dense,expectedRevision:dense.revision)
        var denseDesign = dense.design; z.connection = .thermal; z.minimumWidth = 0.2
        denseDesign.board.copper = .init(zones:[z])
        let denseStart = ProcessInfo.processInfo.systemUptime
        let ds = try ElectronicsPCB.snapshot(design:denseDesign,revision:0), denseMS = (ProcessInfo.processInfo.systemUptime-denseStart)*1000
        guard ds.zones[0].thermals.count == 16, ds.zones[0].thermals.allSatisfy({ $0.connectedSpokes == 4 }), ds.board.airwires.isEmpty, !ds.issues.contains(where:{ $0.severity == .error }) else {
            throw ElectronicsFailure([.init("thermal_corpus","PCB","Il corpus delle 16 termiche non mantiene tutte le connessioni.")])
        }
        try save(PCBZoneCheck.Export(board:ds.board,zones:ds.zones,primitives:ds.primitives,issues:ds.issues),"thermals-dense.json")
        try save(Metrics(pads:16,cells:ds.zones[0].cells.count,snapshotMS:denseMS,queryP95MS:nil),"thermals-dense-metrics.json")
        print("PASS 16 termiche filtrate: \(ds.zones[0].cells.count) celle, snapshot \(denseMS) ms.")
        print("PASS termiche e colli: quattro piazzole, filtro, taglio parziale, isolamento, storico. Snapshot \(elapsed) ms, query p95 \(times[949]) ms.")
    }
}
