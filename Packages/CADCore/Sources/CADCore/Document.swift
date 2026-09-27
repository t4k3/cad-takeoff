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

/// Copies of a body (T88): rectangular grid, circular pattern around a vertical axis, or mirror
/// image in a plane parallel to XY, XZ or YZ. The copies form one body (the pattern) or are joined
/// to the original.
public struct PatternSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangular, circular, mirror
        public var label: String {
            switch self { case .rectangular: "Serie rettangolare"; case .circular: "Serie circolare"; case .mirror: "Specchio" }
        }
    }
    public enum MirrorPlane: String, Codable, Sendable, CaseIterable {
        case yz, xz, xy
        public var label: String { switch self { case .yz: "Piano YZ (specchia X)"; case .xz: "Piano XZ (specchia Y)"; case .xy: "Piano XY (specchia Z)" } }
        var axis: Vec3 { switch self { case .yz: Vec3(1, 0, 0); case .xz: Vec3(0, 1, 0); case .xy: Vec3(0, 0, 1) } }
    }

    /// Feature that created the body to copy.
    public var body: UUID
    public var kind: Kind
    /// Rectangular: counts (including the original) and spacing along X and Y.
    public var countX: Int
    public var spacingX: Double
    public var countY: Int
    public var spacingY: Double
    /// Circular: count (including the original), total angle, centre of the vertical axis.
    public var count: Int
    public var angle: Double
    public var center: Vec3
    /// Mirror: plane and its offset along its normal (e.g. x = offset for YZ).
    public var plane: MirrorPlane
    public var offset: Double
    /// Join the copies to the original body instead of making a new one.
    public var join: Bool
    /// Copies at given places instead of the kind's grid, circle or plane (a pattern of bodies
    /// from Fusion): each a rigid motion as 12 numbers, rows of rotation | translation (mm).
    public var placements: [[Double]]?

    public init(body: UUID, kind: Kind, countX: Int = 3, spacingX: Double = 30, countY: Int = 1, spacingY: Double = 30,
                count: Int = 6, angle: Double = 360, center: Vec3 = .zero, plane: MirrorPlane = .yz, offset: Double = 0, join: Bool = false,
                placements: [[Double]]? = nil) {
        self.body = body; self.kind = kind; self.countX = countX; self.spacingX = spacingX; self.countY = countY; self.spacingY = spacingY
        self.count = count; self.angle = angle; self.center = center; self.plane = plane; self.offset = offset; self.join = join
        self.placements = placements
    }

    public func validate() throws {
        if let placements {
            guard !placements.isEmpty, placements.count <= 400, placements.allSatisfy({ $0.count == 12 && $0.allSatisfy(\.isFinite) }) else {
                throw KernelError.invalidParameter("serie: posizioni delle copie non valide")
            }
            // Rotations (or reflections) only: orthonormal columns, all turned the same way.
            let columns = placements.map { m in [Vec3(m[0], m[4], m[8]), Vec3(m[1], m[5], m[9]), Vec3(m[2], m[6], m[10])] }
            let rigid = columns.allSatisfy { c in
                (0..<3).allSatisfy { i in (0..<3).allSatisfy { j in abs(c[i].dot(c[j]) - (i == j ? 1 : 0)) < 1e-6 } }
            }
            let dets = columns.map { $0[0].cross($0[1]).dot($0[2]) }
            guard rigid, dets.allSatisfy({ ($0 > 0) == (dets[0] > 0) }) else {
                throw KernelError.invalidParameter("serie: le copie devono essere spostate senza deformarle")
            }
            return
        }
        switch kind {
        case .rectangular:
            guard (1...100).contains(countX), (1...100).contains(countY), countX * countY >= 2, countX * countY <= 400,
                  spacingX.isFinite, spacingY.isFinite else { throw KernelError.invalidParameter("serie: 1–100 copie per direzione (almeno 2 in tutto)") }
        case .circular:
            guard (2...360).contains(count), angle.isFinite, abs(angle) > 0.01, abs(angle) <= 360 else {
                throw KernelError.invalidParameter("serie circolare: 2–360 copie, angolo fino a 360°")
            }
        case .mirror:
            guard offset.isFinite else { throw KernelError.invalidParameter("specchio: posizione del piano non valida") }
        }
    }

    /// Rigid motions of the copies (the original excluded); `reflect` for the mirror.
    public func transforms() -> (copies: [(point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3)], reflect: Bool) {
        if let placements {
            let copies = placements.map { m -> (point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3) in
                let direction: (Vec3) -> Vec3 = { v in Vec3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[4] * v.x + m[5] * v.y + m[6] * v.z,
                                                             m[8] * v.x + m[9] * v.y + m[10] * v.z) }
                let shift = Vec3(m[3], m[7], m[11])
                return ({ direction($0) + shift }, direction)
            }
            let m = placements.first ?? []
            let mirrored = m.count == 12 && Vec3(m[0], m[4], m[8]).cross(Vec3(m[1], m[5], m[9])).dot(Vec3(m[2], m[6], m[10])) < 0
            return (copies, mirrored)
        }
        switch kind {
        case .rectangular:
            var out: [(point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3)] = []
            for j in 0..<countY {
                for i in 0..<countX where i != 0 || j != 0 {
                    let d = Vec3(Double(i) * spacingX, Double(j) * spacingY, 0)
                    out.append(({ $0 + d }, { $0 }))
                }
            }
            return (out, false)
        case .circular:
            // A full turn does not repeat the original on top of itself.
            let step = (abs(angle) >= 360 - 1e-9 ? angle / Double(count) : angle / Double(count - 1)) * .pi / 180
            let c = center
            return ((1..<count).map { k in
                let a = step * Double(k)
                let rotate: (Vec3) -> Vec3 = { v in Vec3(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a), v.z) }
                return ({ rotate($0 - c) + c }, rotate)
            }, false)
        case .mirror:
            let n = plane.axis, o = offset
            let reflect: (Vec3) -> Vec3 = { v in v - n * (2 * v.dot(n)) }
            return ([({ p in reflect(p) + n * (2 * o) }, reflect)], true)
        }
    }
}

/// Split a body with a plane parallel to YZ, XZ or XY (T89).
public struct SplitSpec: Codable, Sendable, Equatable {
    public enum Keep: String, Codable, Sendable, CaseIterable {
        /// Both halves: the original keeps the negative side, the positive side becomes a new body.
        case both, positive, negative
        public var label: String {
            switch self { case .both: "Entrambe le parti"; case .positive: "Solo il lato +"; case .negative: "Solo il lato −" }
        }
    }
    public var body: UUID
    public var plane: PatternSpec.MirrorPlane
    public var offset: Double
    public var keep: Keep

    public init(body: UUID, plane: PatternSpec.MirrorPlane = .xy, offset: Double = 0, keep: Keep = .both) {
        self.body = body; self.plane = plane; self.offset = offset; self.keep = keep
    }

    var axis: Vec3 { plane.axis }
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
        /// Copies of a body: rectangular or circular pattern, or mirror image.
        case pattern(PatternSpec)
        /// Cuts a body in two with a plane (e.g. to print a part larger than the bed).
        case split(SplitSpec)
        /// A sketch profile turned about a line (Rivoluzione).
        case revolve(RevolveSpec)
        /// A body hollowed to a wall thickness, some faces left open (Guscio).
        case shell(ShellSpec)
        /// Bodies moved and turned (Sposta).
        case move(MoveSpec)
        /// A part placed against another by a joint (Giunto).
        case joint(JointSpec)
        /// Tool bodies joined to, cut from or intersected with a target body (Combina).
        case combine(CombineSpec)
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
    /// Extrusion of a sketch region with holes (the ring between two circles): these profiles
    /// are left open through the whole height.
    public var holes: [Profile2D]
    /// Sizes driven by parameter expressions, by key ("height" → "spessore * 2").
    public var expressions: [String: String] = [:]
    /// Extrusions: half the height each side of the sketch plane (Fusion's «Simmetrica»).
    public var symmetric = false
    /// Extrusions: draft angle of the sides in degrees; positive narrows away from the sketch.
    public var taper = 0.0
    /// Extrusions: through all the bodies before it (Fusion's «All»), the height worked out at
    /// every evaluation so a cut keeps going through when the part grows.
    public var throughAll = false
    /// Extrusions: up to this planar face of a body before it (Fusion's «To object»), the height
    /// worked out at every evaluation.
    public var untilFace: FaceID?
    /// Extrusions from a sketch: one stable name per profile side, from the sketch curve it lies
    /// on (`Sketch.sideKeys`). The side faces and edges are named after them, so a dimension
    /// change keeps the rounds, chamfers and shells made on them (as in Fusion).
    public var profileKeys: [String]?

    public init(id: UUID = UUID(), name: String, kind: Kind, position: Vec3 = .zero, isVisible: Bool = true,
                color: PartColor = .defaultColor, operation: BooleanOperation = .newBody, placement: FeaturePlacement? = nil,
                holes: [Profile2D] = []) {
        self.id = id; self.name = name; self.kind = kind; self.position = position; self.isVisible = isVisible
        self.color = color; self.operation = operation; self.placement = placement; self.holes = holes
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, position, isVisible, color, operation, placement, holes, expressions, symmetric, taper, throughAll, untilFace, profileKeys }

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
        holes = try c.decodeIfPresent([Profile2D].self, forKey: .holes) ?? []
        expressions = try c.decodeIfPresent([String: String].self, forKey: .expressions) ?? [:]
        symmetric = try c.decodeIfPresent(Bool.self, forKey: .symmetric) ?? false
        taper = try c.decodeIfPresent(Double.self, forKey: .taper) ?? 0
        throughAll = try c.decodeIfPresent(Bool.self, forKey: .throughAll) ?? false
        untilFace = try c.decodeIfPresent(FaceID.self, forKey: .untilFace)
        profileKeys = try c.decodeIfPresent([String].self, forKey: .profileKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encode(position, forKey: .position); try c.encode(isVisible, forKey: .isVisible)
        try c.encode(color, forKey: .color); try c.encode(operation, forKey: .operation)
        try c.encodeIfPresent(placement, forKey: .placement)
        if !holes.isEmpty { try c.encode(holes, forKey: .holes) }
        if !expressions.isEmpty { try c.encode(expressions, forKey: .expressions) }
        if symmetric { try c.encode(symmetric, forKey: .symmetric) }
        if taper != 0 { try c.encode(taper, forKey: .taper) }
        if throughAll { try c.encode(throughAll, forKey: .throughAll) }
        try c.encodeIfPresent(untilFace, forKey: .untilFace)
        try c.encodeIfPresent(profileKeys, forKey: .profileKeys)
    }

    public func buildMesh() -> Mesh {
        if case let .revolve(spec) = kind {
            return (try? Revolve.build(spec, holes: holes, featureID: id, position: position))?.triangulated().mesh ?? Mesh()
        }
        if !holes.isEmpty { return (try? PrimitiveKernel.solidWithHoles(self))?.triangulated().mesh ?? Mesh() }
        if placement != nil || symmetric || taper != 0, let brep = try? PrimitiveKernel.build(self) { return brep.mesh }
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
        case .pattern: return Mesh(vertices: [], indices: [])   // copies of another body
        case .split: return Mesh(vertices: [], indices: [])     // acts on another body
        case .revolve: return Mesh()                            // built above
        case .shell, .move, .joint, .combine: return Mesh()     // act on other bodies
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
    /// User parameters (Fusion's «Parametri»), used by dimension and size expressions.
    public var parameters: [UserParameter] = []
    /// The technical drawing's own changes (dimensions added, moved, taken off).
    public var drawing = DrawingAnnotations()
    /// What an import did (e.g. how much of a Fusion design came in editable); not saved.
    public var importReport: String?

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

    private enum CodingKeys: String, CodingKey { case version, timeline, rollback, sketchLinks, features, sketches, parameters, drawing }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sketchLinks = try c.decodeIfPresent([SketchLink].self, forKey: .sketchLinks) ?? []
        parameters = try c.decodeIfPresent([UserParameter].self, forKey: .parameters) ?? []
        drawing = try c.decodeIfPresent(DrawingAnnotations.self, forKey: .drawing) ?? DrawingAnnotations()
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
        if !parameters.isEmpty { try c.encode(parameters, forKey: .parameters) }
        if !drawing.isEmpty { try c.encode(drawing, forKey: .drawing) }
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

    /// A file written by the Fusion add-in also carries the design's history (`fusion`): it is
    /// rebuilt as editable steps, with the bodies' meshes only for what cannot be rebuilt.
    public static func decode(_ data: Data) throws -> CADDocument {
        var doc = try JSONDecoder().decode(CADDocument.self, from: data)
        struct Envelope: Decodable { let fusion: FusionTimeline? }
        if let timeline = (try? JSONDecoder().decode(Envelope.self, from: data))?.fusion {
            let meshes = doc.features.filter { if case .importedMesh = $0.kind { true } else { false } }
            var (converted, report) = FusionImport.convert(timeline, meshes: meshes)
            if report.editable.isEmpty {
                doc.importReport = report.summary
            } else {
                converted.importReport = report.summary
                doc = converted
            }
        }
        return doc
    }
}
