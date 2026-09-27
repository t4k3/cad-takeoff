import Foundation
import ElectronicsCore

enum PCBRuleCheck {
    struct Drawing: Codable { let keepouts: [PCBKeepout]; let primitives: [PCBCopperPrimitive]; let issues: [ElectronicsIssue] }
    struct Rejection: Codable { let design: ElectronicsDesign; let issues: [ElectronicsIssue]; let canApply: Bool }
    struct Metrics: Codable { let areas: Int; let snapshotMS: Double; let queryP95MS: Double; let queryMaxMS: Double }
    static func run(in output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        func save<T: Encodable>(_ value: T, _ name: String) throws { try encoder.encode(value).write(to:output.appendingPathComponent(name),options:.atomic) }
        func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"BBBB0000-0000-4000-8000-%012d",n))! }
        var d = try ElectronicsDocument.empty(name:"Collaudo classi e aree vietate")
        func apply(_ c: ElectronicsCommand) throws { try ElectronicsCommands.apply(c,to:&d,expectedRevision:d.revision) }
        try apply(.addNet(.init(id:id(1),name:"POWER")))
        try apply(.addNet(.init(id:id(2),name:"SIGNAL")))
        let area = PCBKeepout(id:id(30),name:"Antenna",outline:[.init(18,8),.init(22,8),.init(22,12),.init(18,12)],layers:[0])
        let power = PCBNetClass(id:id(20),name:"Potenza",netIDs:[id(1)],constraints:.init(clearance:0.8,minimumTrackWidth:0.6,minimumDrill:0.4,minimumAnnularRing:0.2))
        try apply(.pcb(.batch([.addNetClass(power),.addKeepout(area)])))
        let track = PCBTrack(id:id(10),netID:id(1),layer:0,width:0.6,points:[.init(5,5),.init(40,5)])
        try apply(.pcb(.addTrack(track)))
        let invalid: [(name: String, code: String, command: PCBCommand)] = [
            ("clearance","pcb_clearance",.addTrack(.init(id:id(11),netID:id(2),layer:0,width:0.25,points:[.init(5,6),.init(40,6)]))),
            ("width","pcb_track_width",.addTrack(.init(id:id(12),netID:id(1),layer:0,width:0.25,points:[.init(5,16),.init(40,16)]))),
            ("keepout","pcb_keepout",.addTrack(.init(id:id(13),netID:id(1),layer:0,width:0.6,points:[.init(5,10),.init(40,10)]))),
            ("via","pcb_keepout",.addVia(.init(id:id(14),netID:id(2),position:.init(20,10))))
        ]
        for item in invalid {
            let before = d, command = ElectronicsCommand.pcb(item.command)
            let p = try ElectronicsCommands.preview(command,document:d,expectedRevision:d.revision)
            guard !p.canApply, p.blockingIssues.contains(where: { $0.code == item.code }) else {
                throw ElectronicsFailure([.init("rule_missed","PCB",item.name)])
            }
            try save(Rejection(design:p.design,issues:p.blockingIssues,canApply:p.canApply),"rule-preview-\(item.name).json")
            do { try apply(command); throw ElectronicsFailure([.init("invalid_accepted","PCB",item.name)]) }
            catch let error as ElectronicsFailure { guard error.issues.contains(where: { $0.code == item.code }) else { throw error } }
            guard d == before else { throw ElectronicsFailure([.init("non_atomic","PCB",item.name)]) }
        }
        // Same XY below the forbidden top layer is allowed; the upper path goes around it.
        try apply(.pcb(.batch([
            .addTrack(.init(id:id(15),netID:id(2),layer:1,width:0.25,points:[.init(5,10),.init(40,10)])),
            .addTrack(.init(id:id(16),netID:id(1),layer:0,width:0.6,points:[.init(5,10),.init(15,10),.init(15,15),.init(25,15),.init(25,10),.init(40,10)]))
        ])))
        let s = try ElectronicsPCB.snapshot(d)
        guard !s.issues.contains(where: { $0.severity == .error }) else { throw ElectronicsFailure(s.issues) }
        try save(d,"rules.ftkc")
        try save(Drawing(keepouts:s.keepouts,primitives:s.primitives,issues:s.issues),"rules-snapshot.json")
        try save(try d.design.nets.map { try ElectronicsPCB.resolvedRules(design:d.design,netID:$0.id) },"rules-resolved.json")
        d = try ElectronicsDocument.decode(d.encoded())
        try d.undo(expectedRevision:d.revision); try save(d,"rules-undo.ftkc")
        try d.redo(expectedRevision:d.revision); try save(d,"rules-redo.ftkc")

        var large = try ElectronicsDocument.empty(name:"Indice aree vietate",outline:[.init(),.init(500,0),.init(500,500),.init(0,500)]).design
        large.board.copper = .init(keepouts:(0..<2000).map { i in
            let x = Double(i%40)*10+2, y = Double(i/40)*9+2
            return .init(id:id(1000+i),name:"Area \(i)",outline:ElectronicsPCB.keepoutRectangle(from:.init(x,y),to:.init(x+2,y+2))!,layers:[0])
        })
        let doc = try ElectronicsDocument(design:large), start = ProcessInfo.processInfo.systemUptime
        let snap = try ElectronicsPCB.snapshot(doc)
        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        var times: [Double] = []
        for k in snap.keepouts {
            let p = k.outline[0], t = ProcessInfo.processInfo.systemUptime
            guard snap.pickKeepouts(point:p,tolerance:0.5,layer:0).first?.id == k.id,
                  snap.keepoutSnapTargets(near:p,radius:0.5,layer:0).first?.id == k.id else {
                throw ElectronicsFailure([.init("keepout_query","PCB","Area non selezionabile.")])
            }
            times.append((ProcessInfo.processInfo.systemUptime-t)*1000)
        }
        times.sort()
        try save(Metrics(areas:2000,snapshotMS:elapsed,queryP95MS:times[1899],queryMaxMS:times.last!),"rules-metrics.json")
        print("PASS PCB rules: class clearance/width, forbidden track/via, allowed lower layer, saved history; 2000 areas snapshot \(elapsed) ms, query p95 \(times[1899]) ms.")
    }
}
