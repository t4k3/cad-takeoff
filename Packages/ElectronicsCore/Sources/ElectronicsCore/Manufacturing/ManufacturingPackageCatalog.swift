import Foundation

/// Native, revisioned visual package envelopes. The catalog never resolves a supplier
/// code or electrical value to geometry. Every entry is approximate and its local XY
/// origin is the body center, assuming a CPL centroid that still requires verification.
public enum ManufacturingPackageCatalog {
    public static var models: [ManufacturingPackageModel] { catalog }

    /// Exact version lookup: a saved key never silently upgrades to a different model.
    public static func model(key: String) -> ManufacturingPackageModel? {
        catalog.first { $0.key == key }
    }

    /// Whole known footprint names only, optionally qualified by a library namespace.
    /// Deliberately no fuzzy matching: DO-214AC_SMB, LM1117 and LCSC-only entries
    /// remain missing, rather than receiving a plausible but contradictory package.
    public static func suggestedModel(for component: ManufacturingComponent) -> ManufacturingPackageModel? {
        guard let footprint = component.footprint else { return nil }
        let name = footprint.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)?.lowercased() ?? ""
        guard let key = aliases[name] else { return nil }
        return model(key: key)
    }

    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        func add(_ key: String, _ names: [String]) { for name in names { result[name.lowercased()] = key } }
        add("ftk.r0805.v1", ["R0805", "R_0805", "R_0805_2012Metric"])
        add("ftk.c0805.v1", ["C0805", "C_0805", "C_0805_2012Metric"])
        add("ftk.r1210.v1", ["R1210", "R_1210", "R_1210_3225Metric"])
        add("ftk.c1210.v1", ["C1210", "C_1210", "C_1210_3225Metric"])
        add("ftk.cp-elec-6.3x7.7.v1", ["CP_Elec_6.3x7.7"])
        add("ftk.sot23-3.v1", ["SOT23", "SOT-23", "SOT23-3", "SOT-23-3"])
        add("ftk.sot23-6.v1", ["SOT23-6", "SOT-23-6"])
        add("ftk.sod923.v1", ["D_SOD-923", "SOD-923", "SOD923"])
        add("ftk.sod323.v1", ["D_SOD-323", "SOD-323", "SOD323"])
        add("ftk.sod123.v1", ["D_SOD-123", "SOD-123", "SOD123"])
        add("ftk.sma.v1", ["D_SMA", "SMA", "DO-214AC", "D_DO-214AC", "D_Zener_DO-214AC-2"])
        for count in [2, 3, 4] {
            add("ftk.pinheader-1x0\(count)-p2.54.v1", ["PinHeader_1x0\(count)_P2.54mm_Vertical"])
        }
        add("ftk.pinheader-2x03-p2.54.v1", ["PinHeader_2x03_P2.54mm_Vertical"])
        return result
    }()

    private static let catalog: [ManufacturingPackageModel] = [
        chip(key: "ftk.r0805.v1", name: "Resistenza 0805 · generica", length: 2, width: 1.25,
             height: 0.5, termination: 0.35, resistor: true),
        chip(key: "ftk.c0805.v1", name: "Condensatore ceramico 0805 · generico", length: 2, width: 1.25,
             height: 1, termination: 0.35, resistor: false),
        chip(key: "ftk.r1210.v1", name: "Resistenza 1210 · generica", length: 3.2, width: 2.5,
             height: 0.55, termination: 0.5, resistor: true),
        chip(key: "ftk.c1210.v1", name: "Condensatore ceramico 1210 · generico", length: 3.2, width: 2.5,
             height: 2, termination: 0.5, resistor: false),
        electrolytic(),
        sot(pins: 3), sot(pins: 6),
        diode(key: "ftk.sod923.v1", name: "SOD-923 · generico", length: 1, width: 0.6, height: 0.4,
              leadSpan: 1.4, leadWidth: 0.25, source: "onsemi CASE 514AB: https://www.onsemi.com/pdf/datasheet/esd9p5.0s-d.pdf"),
        diode(key: "ftk.sod323.v1", name: "SOD-323 · generico", length: 1.7, width: 1.25, height: 0.95,
              leadSpan: 2.5, leadWidth: 0.3, source: "NXP SOD323: https://www.nxp.com/packages/SOD323"),
        diode(key: "ftk.sod123.v1", name: "SOD-123 · generico", length: 2.675, width: 1.6, height: 1.15,
              leadSpan: 3.6, leadWidth: 0.55, source: "Nexperia SOD123: https://www.nexperia.com/packages/SOD123"),
        diode(key: "ftk.sma.v1", name: "SMA / DO-214AC · generico", length: 4.3, width: 2.6, height: 2.1,
              leadSpan: 5.1, leadWidth: 1.5, source: "Vishay SMA DO-214AC: https://www.vishay.com/docs/88367/p4sma.pdf"),
        header(rows: 1, columns: 2), header(rows: 1, columns: 3), header(rows: 1, columns: 4),
        header(rows: 2, columns: 3)
    ]

    private static let commonAssumptions = "Modello proprietario approssimato; raccordi, tolleranze e saldature non modellati. Origine XY al centro del corpo; corrispondenza con centro e rotazione CPL non verificata."

    private static func chip(key: String, name: String, length: Double, width: Double,
                             height: Double, termination: Double, resistor: Bool) -> ManufacturingPackageModel {
        let centerLength = length - 2 * termination
        var parts = [box("ceramic", .ceramic, center: .init(0,0,(height - (resistor ? 0.04 : 0))/2),
                         size: .init(centerLength,width,height - (resistor ? 0.04 : 0)))]
        if resistor {
            parts.append(box("coating", .body, center: .init(0,0,height-0.02), size: .init(centerLength,width,0.04)))
        }
        for (index, sign) in [-1.0,1.0].enumerated() {
            parts.append(box("terminal-\(index+1)", .metal, center: .init(sign*(length-termination)/2,0,height/2), size: .init(termination,width,height)))
        }
        let source = resistor
            ? "Dimensioni nominali famiglia chip, confronto Vishay D/CRCW: https://www.vishay.com/docs/20035/dcrcwe3.pdf."
            : "Dimensioni nominali famiglia MLCC Murata GRM: https://www.murata.com/products/capacitor/ceramiccapacitor/overview/lineup/smd/grm."
        return .init(key: key, name: name,
                     source: "\(source) Ingombro scelto \(length)×\(width)×\(height) mm, terminali \(termination) mm; altezza e metallizzazione assunte, non verificate sul codice BOM. \(commonAssumptions)",
                     parts: parts)
    }

    private static func electrolytic() -> ManufacturingPackageModel {
        // The footprint encodes diameter and height, but not the vendor's base/lead geometry.
        // Three convex can segments provide a polarity stripe without overlapping solids.
        let count = 48, radius = 3.15, z0 = 0.4, top = 7.7
        var parts = [box("base", .insulator, center: .init(0,0,0.25), size: .init(6.6,6.6,0.3))]
        parts.append(cylinderSector("can-a", .metal, radius: radius, start: 0, end: 5*Double.pi/6, segments: 20, bottom: z0, top: top))
        parts.append(cylinderSector("negative-stripe", .polarity, radius: radius, start: 5*Double.pi/6, end: 7*Double.pi/6, segments: 8, bottom: z0, top: top))
        parts.append(cylinderSector("can-b", .metal, radius: radius, start: 7*Double.pi/6, end: 2*Double.pi, segments: count-28, bottom: z0, top: top))
        for (index, sign) in [-1.0,1.0].enumerated() {
            parts.append(box("terminal-\(index+1)", .metal, center: .init(sign*2.35,0,0.05), size: .init(2.6,0.65,0.1)))
        }
        return .init(key: "ftk.cp-elec-6.3x7.7.v1", name: "Elettrolitico SMD Ø6,3 × 7,7 · generico",
                     source: "Ø6,3 mm e altezza totale 7,7 mm dal nome CP_Elec_6.3x7.7; base 6,6 mm, terminali e loro interasse assunti, non verificati sul produttore. Fascia negativa a −X e testimone positivo a +X convenzionali: polarità e CPL da verificare. \(commonAssumptions)",
                     parts: parts, pinOne: .init(2.35,0,0.1))
    }

    private static func sot(pins: Int) -> ManufacturingPackageModel {
        let width = pins == 3 ? 1.3 : 1.6, length = 2.9, height = pins == 3 ? 1.0 : 1.2
        let standoff = 0.1, leadLength = pins == 3 ? 0.55 : 0.6, leadWidth = 0.4
        var parts = [box("body", .body, center: .init(0,0,(height+standoff)/2), size: .init(width,length,height-standoff))]
        let leadX = width/2 + leadLength/2
        let leads: [(Double, Double)] = pins == 3
            ? [(-leadX,0.95),(-leadX,-0.95),(leadX,0)]
            : [(-leadX,0.95),(-leadX,0),(-leadX,-0.95),(leadX,-0.95),(leadX,0),(leadX,0.95)]
        for (index, p) in leads.enumerated() {
            parts.append(box("terminal-\(index+1)", .metal, center: .init(p.0,p.1,0.1), size: .init(leadLength,leadWidth,0.2)))
        }
        parts.append(cylinder("pin-one-mark", .polarity, center: .init(-width/2+0.22,0.98,0), radius: 0.11, bottom: height, top: height+0.02))
        let source = pins == 3
            ? "Nexperia SOT23: https://www.nexperia.com/packages/SOT23.html; corpo nominale 2,9×1,3×1 mm."
            : "TI DBV0006A: https://www.ti.com/lit/ds/symlink/sn74lvc2g17.pdf; corpo nominale 2,9×1,6 mm, passo 0,95 mm."
        return .init(key: "ftk.sot23-\(pins).v1", name: "SOT-23 · \(pins) terminali · generico",
                     source: "\(source) Altezza scelta \(height) mm, standoff 0,1 mm e terminali rettilinei semplificati assunti; nessuna verifica dimensionale del codice BOM. Punto pin 1 convenzionale a sinistra/in alto, non verificato con CPL. \(commonAssumptions)",
                     parts: parts, pinOne: .init(-leadX,0.95,0.1))
    }

    private static func diode(key: String, name: String, length: Double, width: Double, height: Double,
                              leadSpan: Double, leadWidth: Double, source: String) -> ManufacturingPackageModel {
        let leadLength = (leadSpan-length)/2, leadHeight = min(0.2,height/3), stripeWidth = min(0.3,length/6)
        // A thin marking lies above the body rather than duplicating its volume.
        var parts = [box("body", .body, center: .init(0,0,(height+0.05)/2), size: .init(length,width,height-0.05)),
                     box("cathode-mark", .polarity, center: .init(-length/2+stripeWidth,0,height+0.01), size: .init(stripeWidth,width,0.02))]
        for (index, sign) in [-1.0,1.0].enumerated() {
            parts.append(box("terminal-\(index+1)", .metal, center: .init(sign*(length+leadLength)/2,0,leadHeight/2), size: .init(leadLength,leadWidth,leadHeight)))
        }
        return .init(key: key, name: name,
                     source: "\(source). Corpo scelto \(length)×\(width)×\(height) mm; ingombro terminali \(leadSpan) mm. Altezza, terminali e tolleranze non verificati sul codice BOM; catodo/pin 1 a −X è un testimone da verificare, non una conferma CPL. \(commonAssumptions)",
                     parts: parts, pinOne: .init(-(length+leadLength)/2,0,leadHeight/2))
    }

    private static func header(rows: Int, columns: Int) -> ManufacturingPackageModel {
        let pitch = 2.54, pinWidth = 0.64, insulatorHeight = 2.5, exposedLength = 6.0, tail = 3.0
        var parts = [box("insulator", .insulator, center: .init(0,0,insulatorHeight/2), size: .init(Double(rows)*pitch,Double(columns)*pitch,insulatorHeight))]
        var pinOne = PCBPoint3()
        for column in 0..<columns { for row in 0..<rows {
            let x = (Double(row)-Double(rows-1)/2)*pitch, y = (Double(columns-1)/2-Double(column))*pitch
            let pin = column*rows+row+1
            // Hidden metal inside the insulating body is omitted: no duplicate interior volume.
            parts.append(box("terminal-\(pin)-upper", .metal, center: .init(x,y,insulatorHeight+exposedLength/2), size: .init(pinWidth,pinWidth,exposedLength)))
            parts.append(box("terminal-\(pin)-tail", .metal, center: .init(x,y,-tail/2), size: .init(pinWidth,pinWidth,tail)))
            if pin == 1 { pinOne = .init(x,y,insulatorHeight) }
        } }
        return .init(key: "ftk.pinheader-\(rows)x0\(columns)-p2.54.v1", name: "Pin header \(rows)×\(columns) · 2,54 mm verticale",
                     source: "Passo 2,54 mm e disposizione dal nome impronta; confronto famiglia Samtec TSW: https://www.samtec.com/products/tsw. Assunti pin quadrato 0,64 mm, isolante alto 2,5 mm, pin visibile 6 mm, coda THT 3 mm sotto il piano. Origine al centro del corpo, NON al pin 1; testimone pin 1 nell'angolo −X/+Y (o +Y per fila singola), corrispondenza MidX/MidY e orientamento da verificare. \(commonAssumptions)",
                     parts: parts, pinOne: pinOne)
    }

    /// Box vertices shared across faces. Every directed edge has one opposite mate.
    private static func box(_ id: String, _ material: ManufacturingAssemblyMaterial,
                            center: PCBPoint3, size: PCBPoint3) -> ManufacturingAssemblyPart {
        let x = size.x/2, y = size.y/2, z = size.z/2
        let local: [PCBPoint3] = [.init(-x,-y,-z), .init(x,-y,-z), .init(x,y,-z), .init(-x,y,-z),
                                .init(-x,-y,z), .init(x,-y,z), .init(x,y,z), .init(-x,y,z)]
        let vertices = local.map { p -> PCBPoint3 in .init(p.x+center.x,p.y+center.y,p.z+center.z) }
        let indices = [0,2,1, 0,3,2, 4,5,6, 4,6,7,
                       0,1,5, 0,5,4, 1,2,6, 1,6,5,
                       2,3,7, 2,7,6, 3,0,4, 3,4,7]
        return .init(id: id, material: material, vertices: vertices, indices: indices)
    }

    private static func cylinder(_ id: String, _ material: ManufacturingAssemblyMaterial,
                                 center: PCBPoint3, radius: Double, bottom: Double, top: Double) -> ManufacturingAssemblyPart {
        let points = (0..<24).map { i -> PCBPoint in
            let angle = Double(i)*2*Double.pi/24
            return .init(center.x+radius*cos(angle),center.y+radius*sin(angle))
        }
        return prism(id, material, polygon: points, bottom: bottom, top: top)
    }

    /// Convex sectors (<180 degrees), used to partition the capacitor can and stripe.
    private static func cylinderSector(_ id: String, _ material: ManufacturingAssemblyMaterial,
                                       radius: Double, start: Double, end: Double, segments: Int,
                                       bottom: Double, top: Double) -> ManufacturingAssemblyPart {
        var points = [PCBPoint()]
        for i in 0...segments {
            let a = start+(end-start)*Double(i)/Double(segments)
            points.append(.init(radius*cos(a),radius*sin(a)))
        }
        return prism(id, material, polygon: points, bottom: bottom, top: top)
    }

    /// Extrudes a CCW convex polygon using shared indices and opposite bottom winding.
    private static func prism(_ id: String, _ material: ManufacturingAssemblyMaterial,
                              polygon: [PCBPoint], bottom: Double, top: Double) -> ManufacturingAssemblyPart {
        let n = polygon.count
        let vertices = polygon.map { PCBPoint3($0.x,$0.y,bottom) } + polygon.map { PCBPoint3($0.x,$0.y,top) }
        var indices: [Int] = []
        for i in 1..<(n-1) { indices += [0,i+1,i, n,n+i,n+i+1] }
        for i in 0..<n { let next = (i+1)%n; indices += [i,next,n+next, i,n+next,n+i] }
        return .init(id: id, material: material, vertices: vertices, indices: indices)
    }
}
