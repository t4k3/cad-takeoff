import Foundation

/// How a feature combines with the existing bodies (phase 3).
public enum BooleanOperation: String, Codable, Sendable, CaseIterable {
    /// Creates a separate body.
    case newBody
    /// Merges with the bodies it touches.
    case join
    /// Removes its volume from the bodies it touches (holes, pockets, slots).
    case cut
    /// Keeps only the overlap with the bodies it touches.
    case intersect

    public var label: String {
        switch self {
        case .newBody: "Nuovo corpo"
        case .join: "Unisci"
        case .cut: "Taglia"
        case .intersect: "Interseca"
        }
    }
}

/// An imported triangle mesh, stored compactly in the design (float32 positions, uint32 indices,
/// base64): the file keeps working even if the original STL/3MF is moved.
public struct ImportedMesh: Codable, Sendable, Equatable {
    public var mesh: Mesh
    /// Original file name (for the browser).
    public var source: String

    /// Positions are kept at float precision, as stored (save/open gives back the same mesh).
    public init(mesh: Mesh, source: String) {
        self.mesh = Mesh(vertices: mesh.vertices.map { Vec3(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) },
                         indices: mesh.indices)
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case positions, indices, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        let p = try c.decode(Data.self, forKey: .positions), i = try c.decode(Data.self, forKey: .indices)
        guard p.count % 12 == 0, i.count % 12 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .positions, in: c, debugDescription: "mesh importata danneggiata")
        }
        let floats: [Float] = p.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.map { Float(bitPattern: $0.bitPattern.littleEndian) }
        let ints: [UInt32] = i.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }.map { $0.littleEndian }
        let count = UInt32(floats.count / 3)
        guard ints.allSatisfy({ $0 < count }) else {
            throw DecodingError.dataCorruptedError(forKey: .indices, in: c, debugDescription: "indici fuori dalla mesh")
        }
        mesh = Mesh(vertices: stride(from: 0, to: floats.count, by: 3).map { Vec3(Double(floats[$0]), Double(floats[$0 + 1]), Double(floats[$0 + 2])) },
                    indices: ints)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        let floats = mesh.vertices.flatMap { [Float($0.x), Float($0.y), Float($0.z)] }.map { $0.bitPattern.littleEndian }
        try c.encode(floats.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .positions)
        let ints = mesh.indices.map(\.littleEndian)
        try c.encode(ints.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .indices)
    }

    public static func == (a: ImportedMesh, b: ImportedMesh) -> Bool {
        a.source == b.source && a.mesh.indices == b.mesh.indices && a.mesh.vertices == b.mesh.vertices
    }
}

/// A design of the project inserted in another one (assembly component). The referenced file is
/// read when evaluating, so the assembly follows the part's changes.
public struct ComponentRef: Codable, Sendable, Equatable {
    /// Path of the part's .ftk, relative to the project library root.
    public var path: String
    /// Degrees about X, then Y, then Z (world axes), applied before `Feature.position`.
    public var rotation: Vec3

    public init(path: String, rotation: Vec3 = .zero) { self.path = path; self.rotation = rotation }

    /// Part name from the file name.
    public var partName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// Rotation matrix rows (Rz·Ry·Rx) applied to a point.
    public func rotate(_ p: Vec3) -> Vec3 {
        let (x, y, z) = (rotation.x * .pi / 180, rotation.y * .pi / 180, rotation.z * .pi / 180)
        var v = Vec3(p.x, p.y * cos(x) - p.z * sin(x), p.y * sin(x) + p.z * cos(x))
        v = Vec3(v.x * cos(y) + v.z * sin(y), v.y, -v.x * sin(y) + v.z * cos(y))
        return Vec3(v.x * cos(z) - v.y * sin(z), v.x * sin(z) + v.y * cos(z), v.z)
    }
}

/// Where a box, cylinder or extrusion is built: on a sketch plane (e.g. a face), outward along
/// its normal or, reversed, into the part. Nil = the world XY plane (the original behaviour).
public struct FeaturePlacement: Codable, Sendable, Equatable {
    public var plane: SketchPlane
    public var reversed: Bool
    public init(plane: SketchPlane, reversed: Bool = false) { self.plane = plane; self.reversed = reversed }
}

/// A parametric feature in the timeline. The mesh is always regenerated from parameters.
public struct Feature: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case box(width: Double, depth: Double, height: Double)
        case cylinder(radius: Double, height: Double)
        case extrude(profile: Profile2D, height: Double)
        /// One or more holes on a face (always removes material).
        case hole(HoleSpec)
        /// Bevel on selected edges of existing bodies (always removes material).
        case chamfer(ChamferSpec)
        /// Bent sheet-metal part: plate + flanges with a material bending rule (T79).
        case sheetMetal(SheetMetalSpec)
        /// Another design of the project placed in this one (assemblies).
        case component(ComponentRef)
        /// Triangle mesh from an STL/OBJ/3MF file (e.g. exported from Fusion 360).
        case importedMesh(ImportedMesh)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var position: Vec3
    public var isVisible: Bool
    public var color: PartColor
    public var operation: BooleanOperation
    /// Sketch plane the solid is built on (sketch on face); nil = world XY.
    public var placement: FeaturePlacement?

    public init(id: UUID = UUID(), name: String, kind: Kind, position: Vec3 = .zero, isVisible: Bool = true,
                color: PartColor = .defaultColor, operation: BooleanOperation = .newBody, placement: FeaturePlacement? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.position = position; self.isVisible = isVisible
        self.color = color; self.operation = operation; self.placement = placement
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, position, isVisible, color, operation, placement }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        position = try c.decode(Vec3.self, forKey: .position)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        // Existing v1 documents have no colour field. Invalid supplied colours still fail decoding.
        color = try c.decodeIfPresent(PartColor.self, forKey: .color) ?? .defaultColor
        operation = try c.decodeIfPresent(BooleanOperation.self, forKey: .operation) ?? .newBody
        placement = try c.decodeIfPresent(FeaturePlacement.self, forKey: .placement)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encode(position, forKey: .position); try c.encode(isVisible, forKey: .isVisible)
        try c.encode(color, forKey: .color); try c.encode(operation, forKey: .operation)
        try c.encodeIfPresent(placement, forKey: .placement)
    }

    public func buildMesh() -> Mesh {
        if placement != nil, let brep = try? PrimitiveKernel.build(self) { return brep.mesh }
        let local: Mesh
        switch kind {
        case let .box(w, d, h): local = Primitives.box(width: w, depth: d, height: h)
        case let .cylinder(r, h): local = Primitives.cylinder(radius: r, height: h)
        case let .extrude(profile, h): local = Operations.extrude(profile, height: h)
        case let .hole(spec): return HoleGeometry.mesh(spec, featureID: id)
        case .chamfer: return Mesh(vertices: [], indices: [])   // exists only on the body it modifies
        case let .sheetMetal(spec):
            guard let build = try? SheetMetalGeometry.build(spec, featureID: id, position: position) else { return Mesh() }
            return build.folded.triangulated().mesh
        case .component: return Mesh(vertices: [], indices: [])   // geometry comes from the referenced file
        case let .importedMesh(m): return m.mesh.translated(by: position)
        }
        return local.translated(by: position)
    }
}

/// One step of the design history.
public struct TimelineItem: Identifiable, Codable, Sendable, Equatable {
    public enum Content: Codable, Sendable, Equatable {
        case feature(Feature)
        case sketch(Sketch)
    }

    public var content: Content
    /// A suppressed step stays in the history but is not evaluated.
    public var isSuppressed: Bool

    public init(_ content: Content, isSuppressed: Bool = false) {
        self.content = content; self.isSuppressed = isSuppressed
    }

    public var id: UUID {
        switch content {
        case let .feature(f): f.id
        case let .sketch(s): s.id
        }
    }

    public var name: String {
        switch content {
        case let .feature(f): f.name
        case let .sketch(s): s.name
        }
    }

    public var feature: Feature? { if case let .feature(f) = content { f } else { nil } }
    public var sketch: Sketch? { if case let .sketch(s) = content { s } else { nil } }
}

/// The design (format v2, T82): an ordered history (`timeline`) of sketches and features
/// (solids, holes, rounds, sheet metal), with a rollback marker. Serialized as JSON (`.ftk`).
/// v1 files (`features` + optional `sketches`) are migrated on decode.
public struct CADDocument: Codable, Sendable, Equatable {
    public static let formatVersion = 2

    public var version: Int = CADDocument.formatVersion
    public var timeline: [TimelineItem] = []
    /// Number of history steps evaluated; nil = all ("end of timeline").
    public var rollback: Int?
    public var sketchLinks: [SketchLink] = []

    public init(features: [Feature] = [], sketches: [Sketch] = [], sketchLinks: [SketchLink] = []) {
        timeline = Self.orderedV1(features: features, sketches: sketches, links: sketchLinks)
        self.sketchLinks = sketchLinks
    }

    public init(timeline: [TimelineItem], rollback: Int? = nil, sketchLinks: [SketchLink] = []) {
        self.timeline = timeline; self.rollback = rollback; self.sketchLinks = sketchLinks
    }

    // MARK: Views over the timeline (read/write, in history order)

    /// All solids in history order, including suppressed and rolled-back ones (for editing).
    /// Setting keeps the other steps in place: existing solids are updated in their slot,
    /// removed ones are dropped, new ones are inserted at the rollback marker.
    public var features: [Feature] {
        get { timeline.compactMap(\.feature) }
        set { replace(newValue.map { .feature($0) }, matching: { $0.feature != nil }) }
    }

    /// All sketches in history order. Same setter rules as `features`.
    public var sketches: [Sketch] {
        get { timeline.compactMap(\.sketch) }
        set { replace(newValue.map { .sketch($0) }, matching: { $0.sketch != nil }) }
    }


    /// Index where new steps go (the rollback marker, or the end).
    public var insertionIndex: Int { min(rollback ?? timeline.count, timeline.count) }

    /// Steps that are evaluated: before the marker and not suppressed.
    public var activeItems: [TimelineItem] {
        timeline.prefix(insertionIndex).filter { !$0.isSuppressed }
    }

    /// Solids that exist in the evaluated design (visibility is a separate, display-only flag).
    public var activeFeatures: [Feature] { activeItems.compactMap(\.feature) }

    public func isActive(_ id: UUID) -> Bool { activeItems.contains { $0.id == id } }

    private mutating func replace(_ items: [TimelineItem.Content], matching belongs: (TimelineItem) -> Bool) {
        let byID = Dictionary(items.map { (TimelineItem($0).id, $0) }, uniquingKeysWith: { a, _ in a })
        var kept = Set<UUID>()
        var next: [TimelineItem] = []
        var marker = rollback
        for (i, item) in timeline.enumerated() {
            if belongs(item) {
                if let content = byID[item.id] {
                    next.append(TimelineItem(content, isSuppressed: item.isSuppressed)); kept.insert(item.id)
                } else if let m = marker, i < m { marker = m - 1 }   // removed before the marker
            } else {
                next.append(item)
            }
        }
        let added = items.filter { !kept.contains(TimelineItem($0).id) }
        let at = min(marker ?? next.count, next.count)
        next.insert(contentsOf: added.map { TimelineItem($0) }, at: at)
        if let m = marker { marker = m + added.count }
        timeline = next
        rollback = marker.flatMap { $0 >= timeline.count ? nil : $0 }
    }

    // MARK: Evaluation

    /// Combined printable mesh of the evaluated, visible bodies (booleans applied).
    public func buildMesh() -> Mesh {
        Mesh.merged(DesignEvaluator.evaluate(self, revision: "").bodies.filter(\.isVisible).map(\.mesh))
    }

    // MARK: Coding (v2, with v1 migration)

    private enum CodingKeys: String, CodingKey { case version, timeline, rollback, sketchLinks, features, sketches }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sketchLinks = try c.decodeIfPresent([SketchLink].self, forKey: .sketchLinks) ?? []
        if let tl = try c.decodeIfPresent([TimelineItem].self, forKey: .timeline) {
            timeline = tl
            rollback = try c.decodeIfPresent(Int.self, forKey: .rollback)
        } else {
            // v1: flat `features` and (since T77) `sketches`.
            let features = try c.decode([Feature].self, forKey: .features)
            let sketches = try c.decodeIfPresent([Sketch].self, forKey: .sketches) ?? []
            timeline = Self.orderedV1(features: features, sketches: sketches, links: sketchLinks)
        }
        guard fileVersion <= Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                debugDescription: "Documento creato da una versione più recente (formato \(fileVersion)).")
        }
        version = Self.formatVersion
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(timeline, forKey: .timeline)
        try c.encodeIfPresent(rollback, forKey: .rollback)
        if !sketchLinks.isEmpty { try c.encode(sketchLinks, forKey: .sketchLinks) }
    }

    /// v1 had no global order: each sketch goes right before the first solid made from it.
    static func orderedV1(features: [Feature], sketches: [Sketch], links: [SketchLink]) -> [TimelineItem] {
        var placed = Set<UUID>()
        var out: [TimelineItem] = []
        for f in features {
            for s in sketches where !placed.contains(s.id) && links.contains(where: { $0.sketchID == s.id && $0.featureID == f.id }) {
                out.append(TimelineItem(.sketch(s))); placed.insert(s.id)
            }
            out.append(TimelineItem(.feature(f)))
        }
        out += sketches.filter { !placed.contains($0.id) }.map { TimelineItem(.sketch($0)) }
        return out
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> CADDocument {
        try JSONDecoder().decode(CADDocument.self, from: data)
    }
}
