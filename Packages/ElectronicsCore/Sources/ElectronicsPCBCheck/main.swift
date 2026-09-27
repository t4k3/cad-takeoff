import Foundation
import ElectronicsCore

@main struct PCBCheck {
    struct Export: Codable { let board: BoardConnectivity; let primitives: [PCBCopperPrimitive]; let issues: [ElectronicsIssue] }
    struct Metrics: Codable { let primitives: Int; let snapshotMS: Double; let queryP95MS: Double; let queryMaxMS: Double }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ElectronicsFailure([.init("usage","PCB","electronics-pcb cartella-output-nuova")]) }
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw ElectronicsFailure([.init("output_exists","PCB","Cartella già presente.")]) }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        func save<T:Encodable>(_ item: T, _ name: String) throws { try encoder.encode(item).write(to:output.appendingPathComponent(name),options:.atomic) }
        func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"AAAA0000-0000-4000-8000-%012d",n))! }
        let template = ElectronicsStarterLibrary.components[0]
        var d = try ElectronicsDocument.empty(name:"Collaudo routing")
        func apply(_ command: ElectronicsCommand) throws { try ElectronicsCommands.apply(command,to:&d,expectedRevision:d.revision) }
        try apply(template.command(componentID:id(1),reference:"R1",position:.init(8,10)))
        try apply(template.command(componentID:id(2),reference:"R2",position:.init(32,10)))
        try apply(.flipComponent(id(2)))
        let pads = try ElectronicsConnectivity.snapshot(d.design).pads
        let a = pads.filter { $0.componentID == id(1) }.max { $0.center.x < $1.center.x }!
        let b = pads.filter { $0.componentID == id(2) }.min { $0.center.x < $1.center.x }!
        let net = CircuitNet(id:id(10),name:"SIGNAL"), other = CircuitNet(id:id(11),name:"OTHER")
        try apply(.connect(pins:[.init(componentID:a.componentID,pinID:a.pinID),.init(componentID:b.componentID,pinID:b.pinID)],net:net))
        try apply(.addNet(other))
        let via = PCBVia(id:id(30),netID:net.id,position:.init(20,10))
        try apply(.pcb(.batch([
            .addTrack(.init(id:id(20),netID:net.id,layer:0,width:0.25,points:[a.center,via.position])),
            .addTrack(.init(id:id(21),netID:net.id,layer:1,width:0.25,points:[via.position,b.center]))
        ])))
        try save(d,"without-via.ftkc")
        try save(try ElectronicsPCB.snapshot(d).board,"without-via-board.json")
        try apply(.pcb(.addVia(via)))
        let s = try ElectronicsPCB.snapshot(d)
        try save(d,"routed.ftkc"); try save(Export(board:s.board,primitives:s.primitives,issues:s.issues),"routed-snapshot.json")
        let invalid = ElectronicsCommand.pcb(.addTrack(.init(id:id(22),netID:other.id,layer:0,width:0.25,points:[.init(15,7),.init(15,13)])))
        let preview = try ElectronicsCommands.preview(invalid,document:d,expectedRevision:d.revision)
        try save(preview.design,"collision-preview.json"); try save(preview.blockingIssues,"collision-issues.json")
        guard !preview.canApply else { throw ElectronicsFailure([.init("short_missed","PCB","Corto non rilevato.")]) }
        let original = d
        do { try apply(invalid); throw ElectronicsFailure([.init("short_accepted","PCB","Corto accettato.")]) }
        catch let error as ElectronicsFailure { guard error.issues.contains(where: { $0.code == "pcb_short" }) else { throw error } }
        guard d == original else { throw ElectronicsFailure([.init("non_atomic","PCB","Fallimento non atomico.")]) }
        d = try ElectronicsDocument.decode(d.encoded())
        try d.undo(expectedRevision:d.revision); try save(d,"undo.ftkc")
        try d.redo(expectedRevision:d.revision); try save(d,"redo.ftkc")
        var design = try ElectronicsDocument.empty(name:"1000 piste",outline:[.init(),.init(500,0),.init(500,200),.init(0,200)]).design
        design.nets = [net]
        design.board.copper = .init(tracks:(0..<1000).map { i in
            let x = Double(i%50)*9+5, y = Double(i/50)*8+5
            return .init(id:id(1000+i),netID:net.id,layer:0,width:0.25,points:[.init(x,y),.init(x+4,y)])
        })
        let large = try ElectronicsDocument(design:design), start = ProcessInfo.processInfo.systemUptime
        let snapshot = try ElectronicsPCB.snapshot(large)
        let duration = (ProcessInfo.processInfo.systemUptime-start)*1000
        var times: [Double] = []
        for i in 0..<1000 {
            let p = snapshot.primitives[i].center, t = ProcessInfo.processInfo.systemUptime
            guard !snapshot.pick(point:p,tolerance:0.5,layer:0).isEmpty,
                  snapshot.snapTargets(near:p,radius:0.5,layer:0,netID:net.id).first?.kind == .track else {
                throw ElectronicsFailure([.init("pcb_query","PCB","Selezione o aggancio mancanti.")])
            }
            times.append((ProcessInfo.processInfo.systemUptime-t)*1000)
        }
        times.sort()
        try save(Metrics(primitives:snapshot.primitives.count,snapshotMS:duration,queryP95MS:times[949],queryMaxMS:times.last!),"metrics.json")
        try PCBRuleCheck.run(in:output)
        try PCBZoneCheck.run(in:output)
        try PCBThermalCheck.run(in:output)
        print("PASS PCB: rame su due strati, via, corto rifiutato, storico e round-trip. 1000 primitive: snapshot \(duration) ms, query p95 \(times[949]) ms.")
    }
}
