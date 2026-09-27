import CADCore
import SwiftUI

/// Sheet-metal panel (T79–T80): material and stock thickness, press-brake rule (table or
/// custom radius), outside footprint and flanges on the four sides. Live preview; the design
/// changes only on OK (one undo step).
@MainActor
enum SheetMetalCommand {
    static let materials = SheetMaterial.all
    static let directions = SheetBendDirection.allCases
    static let references = SheetFlangeReference.allCases
    static let cornerStyles = SheetCornerStyle.allCases
    static let lipKinds = ["Nessuno", "Risvolto verso l'interno (C)", "Risvolto verso l'esterno (Z)", "Orlo (180°)"]

    /// Display colour of a new part, by material family.
    static func colour(_ material: String) -> PartColor {
        switch material {
        case "aisi304", "aisi316": PartColor(hex: "#B9C2CB")!
        case "al5754", "al6082": PartColor(hex: "#CDD3DA")!
        case "cuzn37": PartColor(hex: "#C9A447")!
        case "cu": PartColor(hex: "#C27A4A")!
        case "dx51d": PartColor(hex: "#A9B3BB")!
        default: PartColor(hex: "#7F8B97")!
        }
    }

    static func mm(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    static func start(workspace: WorkspaceState, model: DesignModel, editing feature: Feature? = nil) -> CommandSession {
        var spec = SheetMetalSpec(material: "dc01", thickness: 1.5, width: 100, depth: 60,
                                  flanges: [.front: SheetFlange(length: 20), .back: SheetFlange(length: 20)])
        if let feature, case let .sheetMetal(existing) = feature.kind { spec = existing }
        let original = feature
        let firstFlange = SheetEdge.allCases.compactMap { spec[$0] }.first ?? SheetFlange(length: 20)
        let differentLengths = Set(SheetEdge.allCases.compactMap { spec[$0]?.length }).count > 1

        func thicknessOptions(_ m: SheetMaterial) -> [String] { m.thicknesses.map { mm($0) + " mm" } }
        let material = SheetMaterial.named(spec.material) ?? materials[0]

        var fields: [CommandField] = [
            .init(id: "material", label: "Materiale", kind: .choice(materials.map(\.name)),
                  value: .index(materials.firstIndex(where: { $0.id == material.id }) ?? 0)),
            .init(id: "materialNote", label: material.note, kind: .note(warning: false), value: .flag(false)),
            .init(id: "thickness", label: "Spessore", kind: .choice(thicknessOptions(material)),
                  value: .index(material.thicknesses.firstIndex { abs($0 - spec.thickness) < 1e-9 } ?? 0),
                  help: "Spessori commerciali per questo materiale"),
            .init(id: "autoRadius", label: "Raggio da tabella (piega in aria)", kind: .toggle, value: .flag(spec.radiusOverride == nil),
                  help: "Raggio interno tipico con la matrice V standard per questo spessore. Disattiva per usare il raggio del tuo piegatore."),
            .init(id: "radius", label: "Raggio interno", kind: .length(0.1...200), value: .number(spec.radiusOverride ?? 2),
                  isHidden: spec.radiusOverride == nil),
            .init(id: "rule", label: "", kind: .note(warning: false), value: .flag(false)),
            .init(id: "width", label: "Larghezza (esterna, X)", kind: .length(5...5000), value: .number(spec.width)),
            .init(id: "depth", label: "Profondità (esterna, Y)", kind: .length(5...5000), value: .number(spec.depth)),
            .init(id: "front", label: "Flangia davanti", kind: .toggle, value: .flag(spec.front != nil)),
            .init(id: "right", label: "Flangia a destra", kind: .toggle, value: .flag(spec.right != nil)),
            .init(id: "back", label: "Flangia dietro", kind: .toggle, value: .flag(spec.back != nil)),
            .init(id: "left", label: "Flangia a sinistra", kind: .toggle, value: .flag(spec.left != nil)),
            .init(id: "length", label: "Altezza flangia", kind: .length(0.5...2000), value: .number(firstFlange.length)),
            .init(id: "perSide", label: "Altezze diverse per lato", kind: .toggle, value: .flag(differentLengths)),
        ] + SheetEdge.allCases.map { e in
            .init(id: "length-" + e.rawValue, label: "Altezza " + e.label.lowercased(), kind: .length(0.5...2000),
                  value: .number(spec[e]?.length ?? firstFlange.length), isHidden: !differentLengths || spec[e] == nil)
        } + [

            .init(id: "angle", label: "Angolo di piega", kind: .angle(5...135), value: .number(firstFlange.angle),
                  help: "Rotazione dalla posizione piana: 90° = a squadra"),
            .init(id: "direction", label: "Verso", kind: .choice(directions.map(\.label)),
                  value: .index(directions.firstIndex(of: firstFlange.direction) ?? 0)),
            .init(id: "reference", label: "Quota", kind: .choice(references.map(\.label)),
                  value: .index(references.firstIndex(of: firstFlange.reference) ?? 0),
                  help: "Quota esterna: l'altezza misurata fuori tutto, come sul disegno d'officina"),
            .init(id: "corners", label: "Angoli", kind: .choice(cornerStyles.map(\.label)),
                  value: .index(cornerStyles.firstIndex(of: spec.cornerStyle) ?? 0),
                  help: "Chiusi: le pareti davanti e dietro coprono l'angolo, quelle laterali ci arrivano contro (scatola); scarico quadrato nello sviluppo"),
            .init(id: "gap", label: "Gioco negli angoli", kind: .length(0...5), value: .number(spec.gap),
                  isHidden: spec.cornerStyle == .open),
            .init(id: "result", label: "", kind: .note(warning: false), value: .flag(false)),
            .init(id: "warnings", label: "", kind: .note(warning: true), value: .flag(false), isHidden: true),
        ]

        // The lip at the flanges' tips, before the corners.
        let lip = firstFlange.lip
        let lipKind: Int = lip == nil ? 0 : (lip!.angle >= 180 - 1e-9 ? 3 : (lip!.inward ? 1 : 2))
        let lipFields: [CommandField] = [
            .init(id: "lip", label: "Sulla punta", kind: .choice(lipKinds), value: .index(lipKind),
                  help: "Seconda piega in punta a ogni flangia: risvolto (profilo a C o a Z) o orlo ripiegato contro la flangia"),
            .init(id: "lipLength", label: "Lunghezza risvolto", kind: .length(0.5...2000), value: .number(lip?.length ?? 10),
                  help: "Quota esterna, dalla faccia della flangia fuori dalla piega", isHidden: lipKind == 0),
            .init(id: "lipAngle", label: "Angolo risvolto", kind: .angle(5...179), value: .number(min(lip?.angle ?? 90, 179)),
                  isHidden: lipKind == 0 || lipKind == 3)
        ]
        fields.insert(contentsOf: lipFields, at: fields.firstIndex { $0.id == "corners" } ?? fields.count)

        func read(_ f: [CommandField]) -> SheetMetalSpec {
            func idx(_ id: String) -> Int { if case let .index(i)? = f.first(where: { $0.id == id })?.value { i } else { 0 } }
            func flag(_ id: String) -> Bool { if case let .flag(b)? = f.first(where: { $0.id == id })?.value { b } else { false } }
            func num(_ id: String) -> Double { f.first { $0.id == id }?.number ?? 0 }
            var s = spec
            let m = materials[min(idx("material"), materials.count - 1)]
            s.material = m.id
            s.thickness = m.thicknesses[min(idx("thickness"), m.thicknesses.count - 1)]
            s.radiusOverride = flag("autoRadius") ? nil : num("radius")
            s.width = num("width"); s.depth = num("depth")
            s.corners = cornerStyles[min(idx("corners"), cornerStyles.count - 1)]
            s.cornerGap = num("gap")
            var flange = SheetFlange(length: num("length"), angle: num("angle"),
                                     direction: directions[min(idx("direction"), directions.count - 1)],
                                     reference: references[min(idx("reference"), references.count - 1)])
            switch idx("lip") {
            case 1, 2: flange.lip = SheetLip(length: num("lipLength"), angle: num("lipAngle"), inward: idx("lip") == 1)
            case 3: flange.lip = SheetLip(length: num("lipLength"), angle: 180)
            default: break
            }
            for e in SheetEdge.allCases {
                guard flag(e.rawValue) else { s[e] = nil; continue }
                var own = flange
                if flag("perSide") { own.length = num("length-" + e.rawValue) }
                s[e] = own
            }
            return s
        }

        var session: CommandSession!

        func preview(_ f: [CommandField]) {
            guard let session else { return }
            let s = read(f)
            let m = SheetMaterial.named(s.material) ?? materials[0]
            // Thickness options follow the material (keeping the nearest stock thickness).
            let options = thicknessOptions(m)
            session.update("thickness") { field in
                guard case let .choice(old) = field.kind, old != options else { return }
                let nearest = m.thicknesses.indices.min { abs(m.thicknesses[$0] - s.thickness) < abs(m.thicknesses[$1] - s.thickness) } ?? 0
                field.kind = .choice(options); field.value = .index(nearest)
            }
            session.update("materialNote") { $0.label = m.note }
            let auto = { if case let .flag(b)? = f.first(where: { $0.id == "autoRadius" })?.value { b } else { true } }()
            session.update("radius") { $0.isHidden = auto }
            let anyFlange = SheetEdge.allCases.contains { s[$0] != nil }
            let perSide = { if case let .flag(b)? = f.first(where: { $0.id == "perSide" })?.value { b } else { false } }()
            for id in ["angle", "direction", "reference", "perSide", "lip"] { session.update(id) { $0.isHidden = !anyFlange } }
            let lipKind = { if case let .index(i)? = f.first(where: { $0.id == "lip" })?.value { i } else { 0 } }()
            session.update("lipLength") { $0.isHidden = !anyFlange || lipKind == 0; $0.label = lipKind == 3 ? "Lunghezza orlo" : "Lunghezza risvolto" }
            session.update("lipAngle") { $0.isHidden = !anyFlange || lipKind == 0 || lipKind == 3 }
            session.update("length") { $0.isHidden = !anyFlange || perSide }
            // Corners exist where a front/back flange meets a side one.
            let anyCorner = [SheetEdge.front, .back].contains { s[$0] != nil } && [SheetEdge.left, .right].contains { s[$0] != nil }
            session.update("corners") { $0.isHidden = !anyCorner }
            session.update("gap") { $0.isHidden = !anyCorner || s.cornerStyle == .open }
            for e in SheetEdge.allCases { session.update("length-" + e.rawValue) { $0.isHidden = !perSide || s[e] == nil } }

            do {
                let build = try SheetMetalGeometry.build(s, featureID: original?.id ?? UUID())
                let r = build.rule
                session.update("rule") {
                    $0.label = "Matrice V\(mm(r.vDie)) · raggio interno \(mm(r.insideRadius)) mm · K \(String(format: "%.3f", r.kFactor)) (DIN 6935) · flangia minima ≈ \(mm(r.minimumFlange)) mm"
                }
                let size = build.flat.size
                let mass = build.flat.area * s.thickness * m.density / 1_000_000   // mm³ · g/cm³ → kg
                session.update("result") {
                    $0.label = "Sviluppo \(mm(size.width)) × \(mm(size.height)) mm · massa ≈ \(String(format: "%.3f", mass).replacingOccurrences(of: ".", with: ",")) kg"
                }
                session.update("warnings") { $0.label = build.warnings.joined(separator: "\n"); $0.isHidden = build.warnings.isEmpty }
                session.message = nil
            } catch {
                session.update("result") { $0.label = "" }
                session.update("warnings") { $0.isHidden = true }
                session.message = error.localizedDescription
                workspace.requestPreview(nil)
                return
            }
            guard f.allSatisfy({ $0.isHidden || $0.validationMessage == nil }) else { workspace.requestPreview(nil); return }
            workspace.requestPreview(document(with: s).0)
        }

        func document(with s: SheetMetalSpec) -> (CADDocument, Feature) {
            var doc = model.document
            if let original, let i = doc.features.firstIndex(where: { $0.id == original.id }) {
                doc.features[i].kind = .sheetMetal(s)
                return (doc, doc.features[i])
            }
            let count = doc.features.filter { if case .sheetMetal = $0.kind { true } else { false } }.count
            let f = Feature(name: "Lamiera \(count + 1)", kind: .sheetMetal(s), color: colour(s.material))
            doc.features.append(f)
            return (doc, f)
        }

        session = CommandSession(
            title: original == nil ? "Lamiera" : "Modifica \(original!.name)", symbol: "square.stack.3d.down.forward",
            fields: fields,
            onPreview: preview,
            onCommit: { f in
                defer { workspace.requestPreview(nil) }
                let s = read(f)
                do { _ = try SheetMetalGeometry.build(s, featureID: UUID()) } catch {
                    model.statusMessage = error.localizedDescription; return
                }
                let (doc, feature) = document(with: s)
                model.edit(original == nil ? "Nuova lamiera: \(s.summary)" : "Modifica \(feature.name)",
                           selected: .some(feature.id), changed: [feature.id]) { $0 = doc }
            },
            onCancel: { workspace.requestPreview(nil) })
        preview(session.fields)
        return session
    }
}
