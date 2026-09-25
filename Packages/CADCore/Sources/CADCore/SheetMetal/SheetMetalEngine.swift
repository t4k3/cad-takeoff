import Foundation

public struct SheetMetalBendZone: Equatable, Sendable {
    public let operationID: UUID
    public let startX: Double
    public let endX: Double
    public let angleDegrees: Double
    public let insideRadius: Double
    public let direction: SheetMetalBendDirection
    public var centerX: Double { (startX + endX) / 2 }
    public var allowance: Double { endX - startX }
}

/// Derived cutting layout. Not an Unfold feature and not an editable folded body.
public struct SheetMetalFlatPattern: Equatable, Sendable {
    public let sourcePartID: UUID
    public let sourceRevision: Int
    public let ruleID: UUID
    public let ruleRevision: Int
    public let outline: Profile2D
    public let thickness: Double
    public let bendZones: [SheetMetalBendZone]
    public let developedLength: Double
    public let width: Double
    private let source: SheetMetalPart

    init(source: SheetMetalPart, outline: Profile2D, thickness: Double,
         bendZones: [SheetMetalBendZone], developedLength: Double, width: Double) {
        self.source = source; self.sourcePartID = source.id; self.sourceRevision = source.revision
        ruleID = source.rule.id; ruleRevision = source.rule.revision
        self.outline = outline; self.thickness = thickness; self.bendZones = bendZones
        self.developedLength = developedLength; self.width = width
    }

    /// Full value comparison also catches altered imported parameters with a reused revision.
    public func isCurrent(for part: SheetMetalPart) -> Bool { source == part }

    public var mesh: Mesh { Operations.extrude(outline, height: thickness) }
    public var blankArea: Double { developedLength * width }
}

public struct SheetMetalBuild: Sendable {
    public let foldedBody: BRepBody
    public let flatPattern: SheetMetalFlatPattern
}

public enum SheetMetalEngine {
    /// Circular bend neutral-line model: BA = angle(radians) * (R_inside + K * thickness).
    /// K is supplied by the caller; no automatic springback or tooling compensation.
    public static func bendAllowance(rule: SheetMetalRule, angleDegrees: Double) throws -> Double {
        try rule.validate()
        guard angleDegrees.isFinite && (5...135).contains(angleDegrees) else {
            throw SheetMetalError.invalidParameter("angolo di piega v1: 5–135 gradi dalla posizione piana")
        }
        return angleDegrees * .pi / 180 * (rule.insideRadius + rule.kFactor * rule.thickness)
    }

    /// Replays one base and at most one active full-width edge flange, in part-local mm, Z up.
    public static func rebuild(_ part: SheetMetalPart) throws -> SheetMetalBuild {
        let (base, flange) = try part.validatedParameters()
        let t = part.rule.thickness, r = part.rule.insideRadius
        var section = [Vec2(-base.length, 0), Vec2(0, 0)]
        var zones: [SheetMetalBendZone] = []
        var addedLength = 0.0, deviation = 0.0
        if let flange {
            let theta = flange.angleDegrees * .pi / 180, n = flange.bendSegments
            let centerZ = r + t
            func arc(_ radius: Double, _ angle: Double) -> Vec2 {
                Vec2(radius * sin(angle), centerZ - radius * cos(angle))
            }
            // Outer arc, straight flange, end thickness, inner arc in reverse, base top.
            for i in 1...n { section.append(arc(r + t, theta * Double(i) / Double(n))) }
            let outer = arc(r + t, theta), inner = arc(r, theta)
            let dx = flange.length * cos(theta), dz = flange.length * sin(theta)
            section.append(Vec2(outer.x + dx, outer.y + dz))
            section.append(Vec2(inner.x + dx, inner.y + dz))
            section.append(inner)
            for i in stride(from: n - 1, through: 0, by: -1) { section.append(arc(r, theta * Double(i) / Double(n))) }
            let allowance = try bendAllowance(rule: part.rule, angleDegrees: flange.angleDegrees)
            addedLength = flange.length + allowance
            zones = [.init(operationID: part.operations[1].id, startX: 0, endX: allowance,
                           angleDegrees: flange.angleDegrees, insideRadius: r, direction: flange.direction)]
            deviation = (r + t) * (1 - cos(theta / (2 * Double(n))))
        } else { section.append(Vec2(0, t)) }
        section.append(Vec2(-base.length, t))
        let profile = Profile2D(points: section)
        // Existing kernel extrudes in +Z. Rotate its section XY into XZ and its
        // extrusion axis into Y. Both up/down mappings are proper rotations (det +1).
        let raw = try PrimitiveKernel.build(Feature(id: part.id, name: part.name,
                                                    kind: .extrude(profile: profile, height: base.width)))
        let down = flange?.direction == .down
        func rotate(_ v: Vec3) -> Vec3 { down ? Vec3(v.x, v.z, -v.y) : Vec3(v.x, -v.z, v.y) }
        let offset = down ? Vec3(0, -base.width / 2, t) : Vec3(0, base.width / 2, 0)
        func point(_ v: Vec3) -> Vec3 { rotate(v) + offset }
        let faces = raw.faces.map { f in
            // Every actual face is planar; curved bend information is in the bend zone.
            BRepFace(id: f.id, halfEdges: f.halfEdges, origin: point(f.origin), normal: rotate(f.normal),
                     selectionID: f.selectionID, sourceSurface: .plane(origin: point(f.origin), normal: rotate(f.normal)))
        }
        let folded = BRepBody(id: raw.id, vertices: raw.vertices.map { .init(id: $0.id, position: point($0.position)) },
                              edges: raw.edges, halfEdges: raw.halfEdges, faces: faces,
                              maximumSurfaceDeviation: deviation, faceTriangles: raw.faceTriangles)
        try folded.validate()
        let outline = Profile2D(points: [Vec2(-base.length, -base.width / 2), Vec2(addedLength, -base.width / 2),
                                        Vec2(addedLength, base.width / 2), Vec2(-base.length, base.width / 2)])
        let flat = SheetMetalFlatPattern(source: part, outline: outline, thickness: t, bendZones: zones,
                                         developedLength: base.length + addedLength, width: base.width)
        return SheetMetalBuild(foldedBody: folded, flatPattern: flat)
    }
}
