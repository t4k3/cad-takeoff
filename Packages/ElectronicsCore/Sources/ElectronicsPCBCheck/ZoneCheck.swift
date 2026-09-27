import Foundation
import ElectronicsCore

enum PCBZoneCheck {
    struct Export: Codable { let board: BoardConnectivity; let zones: [PCBZoneFill]; let primitives: [PCBCopperPrimitive]; let issues: [ElectronicsIssue] }
    struct Metrics: Codable { let cells: Int; let snapshotMS: Double; let queryP95MS: Double }
    static func run(in output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        func save<T:Encodable>(_ item: T, _ name: String) throws { try encoder.encode(item).write(to:output.appendingPathComponent(name),options:.atomic) }
        func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"CCCC0000-0000-4000-8000-%012d",n))! }
        var d = try ElectronicsDocument.empty(name:"Collaudo piani")
        func apply(_ c: ElectronicsCommand) throws { try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision) }
        func capture(_ name: String) throws {
            let s = try ElectronicsPCB.snapshot(d)
            try save(d,"zones-\(name).ftkc")
            try save(Export(board:s.board,zones:s.zones,primitives:s.primitives,issues:s.issues),"zones-\(name).json")
        }
        let template = ElectronicsStarterLibrary.components[0]
        try apply(template.command(componentID:id(1),reference:"R1",position:.init(8,10)))
        try apply(template.command(componentID:id(2),reference:"R2",position:.init(40,10)))
        let pads = try ElectronicsConnectivity.snapshot(d.design).pads
        let pins = [id(1),id(2)].map { component in pads.filter { $0.componentID == component }.max { $0.center.x < $1.center.x }! }
        let net = CircuitNet(id:id(10),name:"GND"), foreign = CircuitNet(id:id(11),name:"POWER")
        try apply(.connect(pins:pins.map { .init(componentID:$0.componentID,pinID:$0.pinID) },net:net))
        try apply(.addNet(foreign))
        try apply(.pcb(.addNetClass(.init(id:id(12),name:"Potenza",netIDs:[foreign.id],constraints:.init(clearance:0.75)))))
        try apply(.pcb(.addTrack(.init(id:id(20),netID:foreign.id,layer:0,width:0.5,points:[.init(12,20),.init(38,20)]))))
        try capture("before")
        let z = PCBZone(id:id(30),name:"Massa",netID:net.id,layer:0,outline:[.init(-1,-1),.init(51,-1),.init(51,31),.init(-1,31)])
        try apply(.pcb(.addZone(z)))
        try capture("connected")
        let k = PCBKeepout(id:id(40),name:"Separazione",outline:[.init(24,0),.init(26,0),.init(26,30),.init(24,30)],layers:[0],tracks:false,vias:false,pads:false,zones:true)
        try apply(.pcb(.addKeepout(k)))
        try capture("split")
        try apply(.pcb(.addTrack(.init(id:id(21),netID:net.id,layer:0,width:0.4,points:[.init(20,10),.init(30,10)]))))
        try capture("bridged")
        d = try ElectronicsDocument.decode(d.encoded())
        try d.undo(expectedRevision:d.revision); try capture("undo")
        try d.redo(expectedRevision:d.revision); try capture("redo")
        // Distributed obstacle corpus: measure real clipping, DRC, connectivity and indexed queries.
        var large = try ElectronicsDocument.empty(name:"100 ostacoli",outline:[.init(),.init(100,0),.init(100,100),.init(0,100)]).design
        large.nets = [net,foreign]
        large.board.copper = .init(tracks:(0..<100).map { n in
            let x = Double(n%10)*9+5, y = Double(n/10)*9+5
            return .init(id:id(100+n),netID:foreign.id,layer:0,width:0.4,points:[.init(x,y),.init(x+2,y+1)])
        },zones:[.init(id:id(30),netID:net.id,layer:0,outline:large.board.outline,removeIslands:false)])
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try ElectronicsPCB.snapshot(design:large,revision:0)
        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        var queries: [Double] = []
        for n in 0..<1000 {
            let p = PCBPoint(Double(n%100)+0.5,Double((n*37)%100)+0.5), start = ProcessInfo.processInfo.systemUptime
            _ = snapshot.pick(point:p,tolerance:0.25,layer:0)
            _ = snapshot.pickZones(point:p,tolerance:0.25,layer:0)
            _ = snapshot.snapTargets(near:p,radius:0.5,layer:0,netID:net.id)
            queries.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        queries.sort()
        try save(Metrics(cells:snapshot.zones[0].cells.count,snapshotMS:elapsed,queryP95MS:queries[949]),"zones-metrics.json")
        print("PASS piani: connessione reale, isole separate, ponte, undo/redo. 100 ostacoli: \(snapshot.zones[0].cells.count) celle, snapshot \(elapsed) ms, query p95 \(queries[949]) ms.")
    }
}
