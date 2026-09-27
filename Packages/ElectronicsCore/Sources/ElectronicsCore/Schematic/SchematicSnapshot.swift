import Foundation

public struct SchematicObject: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case symbol, pin, wire, junction, label, noConnect }
    public let kind: Kind
    public let id: UUID
    public let sheetID: UUID
    public let componentID: UUID?
    public let pinID: UUID?
    public let netID: UUID?
    public init(kind: Kind, id: UUID, sheetID: UUID, componentID: UUID? = nil, pinID: UUID? = nil, netID: UUID? = nil) {
        self.kind = kind; self.id = id; self.sheetID = sheetID; self.componentID = componentID; self.pinID = pinID; self.netID = netID
    }
    var key: String { "\(kind.rawValue)/\(componentID?.uuidString ?? "")/\(id)" }
    var priority: Int { switch kind { case .pin: 0; case .junction, .noConnect: 1; case .label: 2; case .wire: 3; case .symbol: 4 } }
}

public enum SchematicShape: Equatable, Sendable {
    case polyline([PCBPoint], closed: Bool)
    case circle(center: PCBPoint, radius: Double)
    case text(String, at: PCBPoint, height: Double)
}
public struct SchematicPrimitive: Equatable, Sendable {
    public enum Style: String, Sendable { case symbol, pin, wire, junction, reference, value, pinName, pinNumber, label, power, noConnect }
    public let owner: SchematicObject
    public let shape: SchematicShape
    public let style: Style
    public let strokeWidth: Double
    public let filled: Bool
}
public struct SchematicPlacedPin: Equatable, Sendable {
    public let reference: PinReference
    public let position: PCBPoint
    public let name: String
    public let number: String
    public let electricalType: PinElectricalType
    public let netID: UUID?
}
public struct SchematicPick: Equatable, Sendable {
    public let object: SchematicObject
    public let distance: Double
}
public struct SchematicSnap: Equatable, Sendable {
    public enum Kind: String, Sendable { case pin, junction, vertex, midpoint, onWire, grid }
    public let point: PCBPoint
    public let kind: Kind
    public let object: SchematicObject?
    public let distance: Double
    var priority: Int { switch kind { case .pin: 0; case .junction: 1; case .vertex: 2; case .midpoint: 3; case .onWire: 4; case .grid: 5 } }
}

struct SchematicBounds: Sendable {
    var minX: Double; var minY: Double; var maxX: Double; var maxY: Double
    init(_ points: [PCBPoint]) {
        minX = points.map(\.x).min() ?? 0; maxX = points.map(\.x).max() ?? 0
        minY = points.map(\.y).min() ?? 0; maxY = points.map(\.y).max() ?? 0
    }
    init(_ p: PCBPoint, radius: Double) { minX=p.x-radius; maxX=p.x+radius; minY=p.y-radius; maxY=p.y+radius }
    func union(_ b: Self) -> Self { .init([.init(min(minX,b.minX),min(minY,b.minY)), .init(max(maxX,b.maxX),max(maxY,b.maxY))]) }
    func overlaps(_ b: Self) -> Bool { minX <= b.maxX && maxX >= b.minX && minY <= b.maxY && maxY >= b.minY }
}

/// Immutable BVH. Construct once per document revision/sheet; hover queries visit local leaves.
private indirect enum SchematicIndex: Sendable {
    case leaf(SchematicBounds, [Int])
    case branch(SchematicBounds, SchematicIndex, SchematicIndex)
    var bounds: SchematicBounds { switch self { case .leaf(let b,_), .branch(let b,_,_): b } }
    static func build(_ entries: [(Int,SchematicBounds)]) -> Self {
        let bounds = entries.reduce(SchematicBounds(entries.first.map { [.init($0.1.minX,$0.1.minY)] } ?? [])) { $0.union($1.1) }
        guard entries.count > 8 else { return .leaf(bounds, entries.map(\.0)) }
        let x = bounds.maxX-bounds.minX >= bounds.maxY-bounds.minY
        let sorted = entries.sorted { a,b in
            let av = x ? a.1.minX+a.1.maxX : a.1.minY+a.1.maxY
            let bv = x ? b.1.minX+b.1.maxX : b.1.minY+b.1.maxY
            return av == bv ? a.0 < b.0 : av < bv
        }
        let middle = sorted.count/2
        return .branch(bounds, build(Array(sorted[..<middle])), build(Array(sorted[middle...])))
    }
    func query(_ region: SchematicBounds, into result: inout [Int]) {
        guard bounds.overlaps(region) else { return }
        switch self { case .leaf(_,let ids): result += ids
        case .branch(_,let a,let b): a.query(region, into: &result); b.query(region, into: &result) }
    }
}

public struct SchematicSnapshot: Sendable {
    public let revision: UInt64
    public let sheetID: UUID
    public let primitives: [SchematicPrimitive]
    public let pins: [SchematicPlacedPin]
    public let issues: [ElectronicsIssue]
    private let index: SchematicIndex
    init(revision: UInt64, sheetID: UUID, primitives: [SchematicPrimitive], pins: [SchematicPlacedPin], issues: [ElectronicsIssue]) {
        self.revision=revision; self.sheetID=sheetID; self.primitives=primitives; self.pins=pins; self.issues=issues
        index = .build(primitives.enumerated().map { ($0.offset, $0.element.shape.bounds) })
    }
    public func pick(_ point: PCBPoint, tolerance: Double, filter: Set<SchematicObject.Kind> = []) -> [SchematicPick] {
        guard ElectronicsGeometry.valid(point), tolerance.isFinite, tolerance >= 0, tolerance <= 100_000 else { return [] }
        var indices: [Int] = []; index.query(.init(point, radius: tolerance), into: &indices)
        var nearest: [SchematicObject: Double] = [:]
        for i in indices {
            let p = primitives[i]
            guard filter.isEmpty || filter.contains(p.owner.kind) else { continue }
            let d = p.shape.distance(to: point, filled: p.filled)
            if d <= tolerance { nearest[p.owner] = min(nearest[p.owner] ?? .infinity, d) }
        }
        return nearest.map { SchematicPick(object: $0.key, distance: $0.value) }.sorted {
            if $0.object.priority != $1.object.priority { return $0.object.priority < $1.object.priority }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.object.key < $1.object.key
        }
    }
    /// The UI converts its pixel radius to millimetres. Grid is offered only with no closer geometry.
    public func snapTargets(near point: PCBPoint, radius: Double, grid: Double? = nil) -> [SchematicSnap] {
        guard ElectronicsGeometry.valid(point), radius.isFinite, radius >= 0, radius <= 100_000 else { return [] }
        var indices: [Int] = []; index.query(.init(point, radius: radius), into: &indices)
        var results: [SchematicSnap] = []
        func add(_ p: PCBPoint, _ kind: SchematicSnap.Kind, _ object: SchematicObject?) {
            let d = ElectronicsSchematic.distance(point,p)
            if d <= radius, !results.contains(where: { $0.point == p && $0.kind == kind && $0.object == object }) {
                results.append(.init(point: p, kind: kind, object: object, distance: d))
            }
        }
        for i in indices {
            let p = primitives[i]
            if p.owner.kind == .pin, case .polyline(let points,_) = p.shape, let start = points.first { add(start,.pin,p.owner) }
            else if p.owner.kind == .junction, case .circle(let center,_) = p.shape { add(center,.junction,p.owner) }
            else if p.owner.kind == .wire, case .polyline(let points,_) = p.shape {
                for q in points { add(q,.vertex,p.owner) }
                for (a,b) in zip(points,points.dropFirst()) {
                    add(.init((a.x+b.x)/2,(a.y+b.y)/2),.midpoint,p.owner)
                    add(ElectronicsSchematic.segmentDistance(point,a,b).point,.onWire,p.owner)
                }
            }
        }
        if results.isEmpty, let grid, grid.isFinite, grid >= 0.001, grid <= 100_000 {
            add(.init((point.x/grid).rounded()*grid,(point.y/grid).rounded()*grid),.grid,nil)
        }
        return results.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            let a = $0.object?.key ?? "", b = $1.object?.key ?? ""
            if a != b { return a < b }
            if $0.point.x != $1.point.x { return $0.point.x < $1.point.x }
            return $0.point.y < $1.point.y
        }
    }
}

private extension SchematicShape {
    var bounds: SchematicBounds {
        switch self {
        case .polyline(let points,_): .init(points)
        case .circle(let center,let radius): .init(center,radius: radius)
        case .text(let text,let point,let height): .init([point,.init(point.x + Double(text.count)*height*0.7,point.y+height)])
        }
    }
    func distance(to p: PCBPoint, filled: Bool) -> Double {
        switch self {
        case .circle(let c,let r):
            let d = ElectronicsSchematic.distance(p,c); return filled ? max(0,d-r) : abs(d-r)
        case .text:
            let b = bounds
            return hypot(max(b.minX-p.x,0,p.x-b.maxX),max(b.minY-p.y,0,p.y-b.maxY))
        case .polyline(let points,let closed):
            guard let first = points.first else { return .infinity }
            let path = points + (closed ? [first] : [])
            if filled && closed && contains(p, polygon: points) { return 0 }
            return zip(path,path.dropFirst()).map { ElectronicsSchematic.segmentDistance(p,$0,$1).distance }.min() ?? ElectronicsSchematic.distance(p,first)
        }
    }
    func contains(_ p: PCBPoint, polygon: [PCBPoint]) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false; var j = polygon.count-1
        for i in polygon.indices {
            let a=polygon[i],b=polygon[j]
            if (a.y>p.y) != (b.y>p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            j=i
        }
        return inside
    }
}

extension ElectronicsSchematic {
    public static func snapshot(_ document: ElectronicsDocument, sheetID: UUID) throws -> SchematicSnapshot {
        try snapshot(design: document.design, revision: document.revision, sheetID: sheetID)
    }
    public static func snapshot(design: ElectronicsDesign, revision: UInt64, sheetID: UUID) throws -> SchematicSnapshot {
        try Task.checkCancellation()
        try ElectronicsValidation.requireIntegrity(design)
        guard let schema = design.schematic, let sheet = schema.sheets.first(where: { $0.id == sheetID }) else {
            throw error("sheet_missing", "Foglio assente: crearne uno prima di disegnare.", [sheetID])
        }
        var primitives: [SchematicPrimitive] = [], pins: [SchematicPlacedPin] = []
        func append(_ owner: SchematicObject, _ shape: SchematicShape, _ style: SchematicPrimitive.Style, _ width: Double = 0.2, filled: Bool = false) {
            primitives.append(.init(owner: owner, shape: shape, style: style, strokeWidth: width, filled: filled))
        }
        let connections = Dictionary(uniqueKeysWithValues: design.connections.map { ($0.pin,$0) })
        let netByWire = Dictionary(uniqueKeysWithValues: schema.wireNets.map { ($0.wireID,$0.netID) })
        for instance in sheet.symbols.sorted(by: { $0.componentID.uuidString < $1.componentID.uuidString }) {
            try Task.checkCancellation()
            guard let symbol = definition(instance.componentID, design: design),
                  let component = design.components.first(where: { $0.id == instance.componentID }) else { continue }
            let owner = SchematicObject(kind: .symbol, id: component.id, sheetID: sheetID, componentID: component.id)
            var localPoints: [PCBPoint] = []
            for graphic in symbol.graphics ?? [] {
                let g = graphic.points
                let shape: SchematicShape
                switch graphic.kind {
                case .circle: shape = .circle(center: point(g[0],symbol: instance), radius: distance(g[0],g[1]))
                case .rectangle:
                    let corners = [g[0],PCBPoint(g[1].x,g[0].y),g[1],PCBPoint(g[0].x,g[1].y)]
                    shape = .polyline(corners.map { point($0,symbol: instance) }, closed: true)
                case .arc: shape = .polyline(arcPoints(g).map { point($0,symbol: instance) }, closed: false)
                case .line, .polyline: shape = .polyline(g.map { point($0,symbol: instance) }, closed: graphic.filled)
                }
                localPoints += g
                append(owner,shape,.symbol,graphic.strokeWidth,filled: graphic.filled)
            }
            for pin in symbol.pins {
                let ref = PinReference(componentID: component.id,pinID: pin.id)
                guard let p = pin.position else { continue }
                let start = point(p,symbol: instance), a = (pin.rotationDegrees ?? 0) * .pi/180, length = pin.length ?? 1.27
                let end = point(.init(p.x+cos(a)*length,p.y+sin(a)*length),symbol: instance)
                let pinOwner = SchematicObject(kind: .pin,id: pin.id,sheetID: sheetID,componentID: component.id,pinID: pin.id,netID: connections[ref]?.netID)
                append(pinOwner,.polyline([start,end],closed: false),.pin)
                // Text belongs to the symbol so hovering a name cannot snap to a false pin location.
                append(owner,.text(pin.number ?? pin.name,at: .init(start.x+0.35,start.y+0.35),height: 0.9),.pinNumber)
                append(owner,.text(pin.name,at: .init(end.x+0.35,end.y+0.35),height: 0.9),.pinName)
                pins.append(.init(reference: ref,position: start,name: pin.name,number: pin.number ?? pin.name,electricalType: pin.electricalType,netID: connections[ref]?.netID))
                localPoints.append(p)
                if let c = connections[ref], c.netID == nil {
                    let nc = SchematicObject(kind: .noConnect,id: pin.id,sheetID: sheetID,componentID: component.id,pinID: pin.id)
                    append(nc,.polyline([.init(start.x-0.5,start.y-0.5),.init(start.x+0.5,start.y+0.5)],closed: false),.noConnect)
                    append(nc,.polyline([.init(start.x-0.5,start.y+0.5),.init(start.x+0.5,start.y-0.5)],closed: false),.noConnect)
                }
            }
            let b = SchematicBounds(localPoints.map { point($0,symbol: instance) })
            append(owner,.text(component.reference,at: .init(b.minX,b.maxY+1),height: 1.5),.reference)
            append(owner,.text(component.value,at: .init(b.minX,b.minY-2),height: 1.2),.value)
        }
        for wire in sheet.wires.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let owner = SchematicObject(kind: .wire,id: wire.id,sheetID: sheetID,netID: netByWire[wire.id])
            append(owner,.polyline(try wirePoints(wire,sheet: sheet,design: design),closed: false),.wire)
        }
        for j in sheet.junctions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let netID = sheet.wires.first(where: { $0.start == .junction(j.id) || $0.end == .junction(j.id) }).flatMap { netByWire[$0.id] }
                ?? sheet.labels.first(where: { $0.terminal == .junction(j.id) })?.netID
            append(.init(kind: .junction,id: j.id,sheetID: sheetID,netID: netID),.circle(center: j.position,radius: 0.35),.junction,filled: true)
        }
        for label in sheet.labels.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let p = try terminalPosition(label.terminal,sheet: sheet,design: design)
            let at = PCBPoint(p.x+label.offset.x,p.y+label.offset.y)
            let owner = SchematicObject(kind: .label,id: label.id,sheetID: sheetID,netID: label.netID)
            let style: SchematicPrimitive.Style = label.kind == .power ? .power : .label
            append(owner,.polyline([p,at],closed: false),style)
            append(owner,.text(design.nets.first(where: { $0.id == label.netID })?.name ?? "?",at: at,height: 1.2),style)
            if label.kind == .power { append(owner,.polyline([.init(at.x-0.6,at.y-0.6),at,.init(at.x+0.6,at.y-0.6)],closed: false),style) }
        }
        let ids = Set([sheet.id] + sheet.symbols.map(\.componentID) + sheet.wires.map(\.id) + sheet.junctions.map(\.id) + sheet.labels.map(\.id))
        let issues = ElectronicsValidation.electrical(design).filter { !Set($0.subjectIDs ?? []).isDisjoint(with: ids) }
        return .init(revision: revision,sheetID: sheetID,primitives: primitives,pins: pins,issues: issues)
    }
    /// Rendering tessellation only; connectivity never depends on these approximation points.
    private static func arcPoints(_ p: [PCBPoint]) -> [PCBPoint] {
        let a=p[0],b=p[1],c=p[2]
        let d=2*(a.x*(b.y-c.y)+b.x*(c.y-a.y)+c.x*(a.y-b.y))
        guard abs(d)>1e-12 else { return p }
        let aa=a.x*a.x+a.y*a.y,bb=b.x*b.x+b.y*b.y,cc=c.x*c.x+c.y*c.y
        let center=PCBPoint((aa*(b.y-c.y)+bb*(c.y-a.y)+cc*(a.y-b.y))/d,(aa*(c.x-b.x)+bb*(a.x-c.x)+cc*(b.x-a.x))/d)
        let start=atan2(a.y-center.y,a.x-center.x),mid=atan2(b.y-center.y,b.x-center.x),end=atan2(c.y-center.y,c.x-center.x)
        func positive(_ angle: Double) -> Double { let x=angle.truncatingRemainder(dividingBy: 2 * .pi); return x<0 ? x+2 * .pi : x }
        let ccw=positive(end-start),sweep=positive(mid-start)<=ccw ? ccw : ccw-2 * .pi
        let count=max(2,Int(ceil(abs(sweep)/(.pi/36)))),radius=distance(a,center)
        return (0...count).map { let angle=start+sweep*Double($0)/Double(count); return .init(center.x+radius*cos(angle),center.y+radius*sin(angle)) }
    }
}
