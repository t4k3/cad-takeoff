import Foundation
import CryptoKit

/// Native Gerber X2 and XNC (unambiguous decimal Excellon subset) writers.
/// Source: Ucamco Gerber 2026.05, XNC 2021.11, Gerber Job schema 2023.06.
enum FabricationWriter {
    static func decimal(_ x: Double) -> String {
        String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),abs(x) < 0.0000005 ? 0 : x)
    }
    static func precise(_ x: Double) -> String {
        String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),abs(x) < 0.0000000005 ? 0 : x)
    }
    static func coordinate(_ p: PCBPoint, origin: PCBPoint) -> String {
        "X\(Int64(((p.x-origin.x)*1_000_000).rounded()))Y\(Int64(((p.y-origin.y)*1_000_000).rounded()))"
    }
    static func json<T: Encodable>(_ object: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return String(decoding:try encoder.encode(object),as:UTF8.self)+"\n"
    }
    static func jsonObject(_ object: [String:Any]) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)+"\n"
    }
    static func gerber(_ layer: FabricationLayer, preview: FabricationPreview) throws -> String {
        var definitions = [String](), body = [String](), apertures: [String:Int] = [:]
        func aperture(_ definition: String, macro: Bool = false) -> Int {
            if let number = apertures[definition] { return number }
            let number = 10+apertures.count; apertures[definition] = number
            if macro {
                definitions.append("%AMFTK\(number)*\n\(definition)%")
                definitions.append("%ADD\(number)FTK\(number)*%")
            } else { definitions.append("%ADD\(number)\(definition)*%") }
            return number
        }
        for o in layer.objects {
            try Task.checkCancellation()
            switch o.kind {
            case .region:
                body += ["G36*",coordinate(o.core[0],origin:preview.origin)+"D02*"]
                body += (o.core.dropFirst()+[o.core[0]]).map { coordinate($0,origin:preview.origin)+"D01*" }
                body.append("G37*")
            case .stroke:
                let number = aperture("C,"+precise(2*o.radius))
                body += ["D\(number)*",coordinate(o.core[0],origin:preview.origin)+"D02*"]
                body += o.core.dropFirst().map { coordinate($0,origin:preview.origin)+"D01*" }
            case .flash:
                let center = o.center, points = o.core.map { PCBPoint($0.x-center.x,$0.y-center.y) }
                let number: Int
                if points.count == 1 { number = aperture("C,"+precise(2*o.radius)) }
                else {
                    var macro = ""
                    if points.count >= 3 {
                        let closed = points+[points[0]]
                        macro += "4,1,\(points.count),"+closed.flatMap { [precise($0.x),precise($0.y)] }.joined(separator:",")+",0*\n"
                    }
                    if o.radius > 0 {
                        for p in points { macro += "1,1,\(precise(2*o.radius)),\(precise(p.x)),\(precise(p.y)),0*\n" }
                        let edges = points.count == 2 ? [(points[0],points[1])] : PCBGeometry.edges(points)
                        for (a,b) in edges {
                            macro += "20,1,\(precise(2*o.radius)),\(precise(a.x)),\(precise(a.y)),\(precise(b.x)),\(precise(b.y)),0*\n"
                        }
                    }
                    number = aperture(macro,macro:true)
                }
                body += ["D\(number)*",coordinate(center,origin:preview.origin)+"D03*"]
            }
        }
        return (["G04 CAD Takeoff native fabrication v1*","%TF.GenerationSoftware,Takeoff,Circuiti,1*%",
                 "%TF.Part,Single*%","%TF.FileFunction,\(layer.kind.fileFunction)*%","%TF.FilePolarity,\(layer.kind.polarity)*%",
                 "%TF.SameCoordinates,\(preview.designID.uuidString)-\(preview.revision)*%",
                 "%FSLAX66Y66*%","%MOMM*%"]+definitions+["%LPD*%","G01*"]+body+["M02*"]).joined(separator:"\n")+"\n"
    }
    static func drill(_ holes: [FabricationDrill], origin: PCBPoint) throws -> String {
        let diameters = Set(holes.map { decimal($0.diameter) }).sorted { Double($0)! < Double($1)! }
        guard diameters.count <= 99 else { throw FabricationGeometry.issue("fabrication_drill_tools","Più di 99 diametri di foratura: uniformare i fori o usare un profilo dedicato.") }
        var lines = ["M48","; CAD Takeoff native XNC - plated through holes, finished diameter","METRIC"]
        func tool(_ i: Int) -> String { String(format:"T%02d",i+1) }
        for i in diameters.indices { lines.append(tool(i)+"C"+diameters[i]) }
        lines += ["%","G05"]
        for i in diameters.indices {
            try Task.checkCancellation()
            lines.append(tool(i))
            for h in holes.filter({ decimal($0.diameter) == diameters[i] }).sorted(by: {
                $0.position.x == $1.position.x ? $0.position.y < $1.position.y : $0.position.x < $1.position.x
            }) { lines.append("X\(decimal(h.position.x-origin.x))Y\(decimal(h.position.y-origin.y))") }
        }
        lines.append("M30"); return lines.joined(separator:"\n")+"\n"
    }
    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map { "\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:",") }.joined(separator:"\r\n")+"\r\n"
    }
    static func package(document: ElectronicsDocument, preview: FabricationPreview, assembly: AssemblyData) throws -> FabricationPackage {
        let design = document.design
        var files: [FabricationFile] = []
        for layer in preview.layers { files.append(.init(name:layer.kind.fileName,content:try gerber(layer,preview:preview))) }
        files.append(.init(name:"board-PTH.drl",content:try drill(preview.drills,origin:preview.origin)))
        files.append(.init(name:"assembly-bom.csv",content:assembly.bomCSV))
        files.append(.init(name:"assembly-cpl.csv",content:assembly.cplCSV))
        let excluded = Set(design.variants.first { $0.id == preview.variantID }?.excludedComponents ?? [])
        var rows = [["Designator","Value","Manufacturer","MPN","Footprint","Method","Fitted","Side","X mm","Y mm","Rotation deg"]]
        for c in design.components.sorted(by: { $0.reference < $1.reference }) {
            let device = design.library.devices.first { $0.key == c.device }!
            let foot = design.library.footprints.first { $0.key == device.footprint }!
            let p = design.board.placements.first { $0.componentID == c.id }!
            let point = ElectronicsGeometry.boardPoint(foot.assemblyCentroid,placement:p)
            rows.append([c.reference,c.value,device.manufacturer,device.manufacturerPartNumber,foot.name,c.assembly.rawValue,
                         c.assembly != .doNotPopulate && !excluded.contains(c.id) ? "yes" : "no",p.side.rawValue,
                         decimal(point.x-preview.origin.x),decimal(point.y-preview.origin.y),decimal(p.rotationDegrees)])
        }
        files.append(.init(name:"components.csv",content:csv(rows)))
        var attributes: [[String:Any]] = preview.layers.map {
            ["Path":$0.kind.fileName,"FileFunction":$0.kind.fileFunction,"FilePolarity":$0.kind.polarity,"FileFormat":"Gerber"]
        }
        attributes.append(["Path":"board-PTH.drl","FileFunction":"Plated,1,2,PTH","FileFormat":"XNC"])
        let outline = design.board.outline
        let job: [String:Any] = [
            "Header":["GenerationSoftware":["Vendor":"Takeoff","Application":"Circuiti","Version":"1"],"Comment":"Generic two-layer profile; supplier review required"],
            "GeneralSpecs":["ProjectId":["Name":design.name,"GUID":design.id.uuidString,"Revision":String(document.revision)],
                            "LayerNumber":2,"BoardThickness":design.board.thickness,
                            "Size":["X":outline.map(\.x).max()!-outline.map(\.x).min()!,"Y":outline.map(\.y).max()!-outline.map(\.y).min()!]],
            "FilesAttributes":attributes]
        files.append(.init(name:"board.gbrjob",content:try jsonObject(job)))
        files.append(.init(name:"preflight.json",content:try json(preview)))
        files.append(.init(name:"README.txt",content:"""
        Circuiti - pacchetto di verifica fabbricazione v1
        Progetto: \(design.id.uuidString), revisione: \(document.revision)
        Unita: mm. Tutti gli strati sono visti dall'alto, senza specchiare il lato inferiore.
        Origine comune sottratta a Gerber, forature e CSV: \(decimal(preview.origin.x)), \(decimal(preview.origin.y)).
        Gerber X2: rame, aperture maschera, pasta, serigrafia, profilo non metallizzato.
        La maschera ha FilePolarity Negative: le figure sono aperture, non materiale.
        Forature XNC/Excellon decimale: PTH rotondi, diametri finiti dopo metallizzazione.
        NPTH, asole, ritagli, bordi metallizzati e stackup multistrato non rappresentati dal modello v7.
        assembly-bom/cpl.csv: solo componenti affidati all'assemblaggio JLC, convenzioni della libreria.
        components.csv: elenco completo incluse parti manuali e non montate; rotazioni del documento.
        La variante cambia pasta e assemblaggio, non rame, fori o maschera.
        Nessuna qualifica del produttore o del circuito elettrico e nessun ordine effettuato.
        Esaminare gli avvisi in preflight.json e controllare i file in un viewer indipendente.
        Verificare componenti, pin 1 e orientamenti rispetto ai datasheet prima di produrre.
        Il manifest identifica con SHA-256 ogni file del pacchetto (escluso il manifest stesso).
        \n
        """))
        struct Entry: Encodable { let name: String; let bytes: Int; let sha256: String }
        struct Manifest: Encodable {
            let formatVersion: Int; let designID: UUID; let revision: UInt64; let variantID: UUID?
            let origin: PCBPoint; let profile: FabricationProfile; let files: [Entry]
        }
        let entries = files.map { f -> Entry in
            let data = Data(f.content.utf8)
            return .init(name:f.name,bytes:data.count,sha256:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
        }
        files.append(.init(name:"manifest.json",content:try json(Manifest(formatVersion:1,designID:design.id,revision:document.revision,
                      variantID:preview.variantID,origin:preview.origin,profile:preview.profile,files:entries))))
        try Task.checkCancellation()
        return .init(preview:preview,files:files)
    }
}
