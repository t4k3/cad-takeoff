import Foundation

/// Native assembly geometry in the document frame. Models remain approximations even
/// when their mounting alignment has been confirmed. Build off the UI actor and reuse.
/// Board bottom is z=0 and top is z=boardThickness. No source CPL value is modified.
/// Each instance's polygons use back-to-front painter order for that component's
/// side: increasing visible maximum Z on top, decreasing visible minimum Z below.
/// This whole-part ordering is an approximation for intersecting or tilted bodies
/// whose relative surface depth changes across their projected overlap; it does not
/// replace per-pixel depth testing in 3D. Meshes retain their original order/winding.
public struct ManufacturingAssemblySnapshot: Sendable {
    public let packageID: UUID
    public let instances: [ManufacturingAssemblyInstance]
    public let boardThickness: Double
    public let isBoardThicknessAssumed: Bool
    public let boardParts: [ManufacturingAssemblyPart]
    public let issues: [ElectronicsIssue]

    private struct Snap: Sendable {
        let instance: Int
        let target: ManufacturingSnapTarget
    }
    private struct ProjectedPart {
        let polygon: ManufacturingAssemblyPolygon
        let frontDepth: Double
        let middleDepth: Double
        let ordinal: Int
    }
    private let pickInstances: [Int]
    private let pickIndex: PCBIndex
    private let snaps: [Snap]
    private let snapIndex: PCBIndex
    private let profile: ManufacturingLayer?
    private let drills: [ManufacturingDrill]
    private let boardIssues: [ElectronicsIssue]
    private static let resultLimit = 256

    /// `previous` may reuse the expensive substrate triangulation when identity,
    /// full profile/drill content and thickness all match. Current data is always
    /// validated; component geometry, lot flags and cursor indexes are rebuilt.
    public init(package: ManufacturingPackage, previous: ManufacturingAssemblySnapshot? = nil) throws {
        try Task.checkCancellation()
        try ElectronicsManufacturingImport.requireIntegrity(package)
        packageID = package.id
        boardThickness = package.assemblySettings?.boardThickness ?? 1.6
        isBoardThicknessAssumed = package.assemblySettings?.boardThickness == nil
        profile = package.layers.first { $0.kind == .profile }
        drills = package.drills
        var issues: [ElectronicsIssue] = []
        func warn(_ code: String, _ reference: String, _ message: String, _ id: UUID, _ position: PCBPoint? = nil) {
            var issue = ElectronicsIssue(code, reference, message, severity: .warning)
            issue.subjectIDs = [id]; issue.position = position; issues.append(issue)
        }
        if isBoardThicknessAssumed {
            warn("assembly_thickness_assumed", package.name,
                 "Spessore visualizzato di 1,6 mm stimato: impostare lo spessore reale della scheda.", package.id)
        }
        if let previous, previous.packageID == package.id, previous.profile == profile,
           previous.drills == drills, previous.boardThickness == boardThickness {
            boardParts = previous.boardParts
            boardIssues = previous.boardIssues
        } else {
            do {
                boardParts = try ManufacturingAssemblyBoard.parts(package: package, thickness: boardThickness)
                boardIssues = []
            } catch let failure as ElectronicsFailure {
                boardParts = []
                boardIssues = failure.issues.map { original in
                    var issue = original
                    if issue.subjectIDs?.isEmpty != false { issue.subjectIDs = [package.id] }
                    return issue
                }
            }
        }
        issues.append(contentsOf: boardIssues)

        let fitted = Set(package.activeLot?.fittedComponentIDs ?? [])
        var instances: [ManufacturingAssemblyInstance] = []
        var pickInstances: [Int] = [], pickBoxes: [PCBBox] = []
        var snaps: [Snap] = [], snapBoxes: [PCBBox] = []
        var vertexCount = 0, indexCount = 0
        for component in package.components.sorted(by: {
            $0.reference == $1.reference ? $0.id.uuidString < $1.id.uuidString : $0.reference < $1.reference
        }) {
            try Task.checkCancellation()
            let binding = component.modelBinding
            let model: ManufacturingPackageModel?
            if let binding { model = ManufacturingPackageCatalog.model(key: binding.modelKey) }
            else { model = ManufacturingPackageCatalog.suggestedModel(for: component) }
            let placement = component.placement
            let aligned = binding?.alignmentVerified == true && model != nil && placement != nil
            if model == nil {
                warn("assembly_model_missing", component.reference,
                     "\(component.reference): modello non disponibile; scegliere un modello per visualizzare il corpo.",
                     component.id, placement?.position)
            } else {
                if model?.quality == .approximate {
                    warn("assembly_model_approximate", component.reference,
                         "\(component.reference): ingombro approssimato, da verificare sul componente reale.", component.id, placement?.position)
                }
                if !aligned {
                    warn("assembly_alignment_unverified", component.reference,
                         "\(component.reference): verificare orientamento e pin 1 rispetto alla scheda prima di confermare l’allineamento.",
                         component.id, placement?.position)
                }
            }
            if placement == nil {
                warn("assembly_position_missing", component.reference,
                     "\(component.reference): posizione assente dal CPL; il componente resta in distinta senza una posizione inventata.", component.id)
            }
            var parts: [ManufacturingAssemblyPart] = []
            var polygons: [ManufacturingAssemblyPolygon] = []
            var transform: [Double]?, pinOne: PCBPoint3?, bounds: ManufacturingBounds?
            if let model, let placement {
                let matrix = Self.transform(componentID: component.id, placement: placement,
                                            thickness: boardThickness, binding: binding)
                transform = matrix
                var projected: [ProjectedPart] = []
                for part in model.parts {
                    try Task.checkCancellation()
                    vertexCount += part.vertices.count; indexCount += part.indices.count
                    guard vertexCount <= 2_000_000, indexCount <= 12_000_000 else { throw Self.limitFailure(package.id) }
                    let vertices = part.vertices.map { Self.point($0, matrix) }
                    // A proper rotation has determinant +1, including the bottom flip;
                    // preserving indices therefore preserves outward winding.
                    parts.append(.init(id: part.id, material: part.material, vertices: vertices, indices: part.indices))
                    let hull = Self.hull(vertices.map { PCBPoint($0.x, $0.y) })
                    guard !hull.isEmpty else { continue }
                    var low = vertices[0].z, high = low
                    for vertex in vertices { low = min(low, vertex.z); high = max(high, vertex.z) }
                    let direction = placement.side == .top ? 1.0 : -1.0
                    // Sort the nearest surface extent, not average vertex Z: the
                    // latter depends on tessellation density. The interval midpoint
                    // is only a tie-breaker, followed by stable identity and order.
                    projected.append(.init(polygon: .init(partID: part.id, material: part.material, points: hull),
                                           frontDepth: placement.side == .top ? high : -low,
                                           middleDepth: direction * (low + high) / 2, ordinal: projected.count))
                    let box = PCBBox(hull)
                    if let previous = bounds {
                        bounds = .init(minimum: .init(min(previous.minimum.x, box.minX), min(previous.minimum.y, box.minY)),
                                       maximum: .init(max(previous.maximum.x, box.maxX), max(previous.maximum.y, box.maxY)))
                    } else { bounds = .init(minimum: .init(box.minX, box.minY), maximum: .init(box.maxX, box.maxY)) }
                }
                polygons = projected.sorted { a, b in
                    if a.frontDepth != b.frontDepth { return a.frontDepth < b.frontDepth }
                    if a.middleDepth != b.middleDepth { return a.middleDepth < b.middleDepth }
                    if a.polygon.partID != b.polygon.partID { return a.polygon.partID < b.polygon.partID }
                    return a.ordinal < b.ordinal
                }.map(\.polygon)
                pinOne = model.pinOne.map { Self.point($0, matrix) }
            }
            let instanceIndex = instances.count
            instances.append(.init(id: component.id, reference: component.reference, side: placement?.side,
                                   fitted: fitted.contains(component.id), modelKey: model?.key, modelName: model?.name,
                                   modelSource: model?.source, quality: model?.quality ?? .missing,
                                   alignmentVerified: aligned, position: placement?.position, transform: transform,
                                   parts: parts, polygons: polygons, pinOne: pinOne, bounds: bounds))
            if let position = placement?.position {
                pickInstances.append(instanceIndex)
                pickBoxes.append(bounds.map { PCBBox([$0.minimum, $0.maximum]) } ?? PCBBox([position]))
                var seen: Set<PCBPoint> = [position]
                func addSnap(_ point: PCBPoint, _ kind: ManufacturingSnapTarget.Kind) throws {
                    guard snaps.count < 1_000_000 else { throw Self.limitFailure(package.id) }
                    snaps.append(.init(instance: instanceIndex, target: .init(id: component.id, position: point, kind: kind)))
                    snapBoxes.append(PCBBox([point]))
                }
                try addSnap(position, .componentCenter)
                if let pinOne {
                    let p = PCBPoint(pinOne.x, pinOne.y)
                    if seen.insert(p).inserted { try addSnap(p, .vertex) }
                }
                for polygon in polygons {
                    for point in polygon.points where seen.insert(point).inserted { try addSnap(point, .vertex) }
                }
            }
        }
        self.instances = instances; self.issues = issues
        self.pickInstances = pickInstances; self.pickIndex = try PCBIndex(boxes: pickBoxes)
        self.snaps = snaps; self.snapIndex = try PCBIndex(boxes: snapBoxes)
    }

    /// Picks actual projected part hulls, not their bounding rectangles. A component
    /// without a model is selectable only at its supplied CPL center. Results are
    /// capped at 256 and ordered by distance, then persistent component UUID.
    public func pick(point: PCBPoint, tolerance: Double, side: BoardSide? = nil,
                     includeExcluded: Bool = false) -> [ManufacturingPick] {
        guard Self.valid(point, tolerance) else { return [] }
        var result: [ManufacturingPick] = []
        result.reserveCapacity(Self.resultLimit)
        pickIndex.visitAssembly(PCBBox([point], margin: tolerance)) { index in
            let instance = instances[pickInstances[index]]
            guard (includeExcluded || instance.fitted), side == nil || instance.side == side,
                  let center = instance.position else { return }
            let distance = instance.polygons.isEmpty ? PCBGeometry.distance(point, center) :
                instance.polygons.reduce(Double.infinity) { min($0, Self.distance(point, $1.points)) }
            guard distance <= tolerance else { return }
            let hit = ManufacturingPick(id: instance.id, kind: .component, distance: distance)
            Self.insert(hit, into: &result) { a, b in
                a.distance == b.distance ? a.id.uuidString < b.id.uuidString : a.distance < b.distance
            }
        }
        return result
    }

    /// CPL centers win over projected part vertices/pin-1 witnesses. No position is
    /// synthesized for unplaced components; excluded components are opt-in.
    public func snapTargets(near point: PCBPoint, radius: Double, side: BoardSide? = nil,
                            includeExcluded: Bool = false) -> [ManufacturingSnapTarget] {
        guard Self.valid(point, radius) else { return [] }
        var result: [ManufacturingSnapTarget] = []
        result.reserveCapacity(Self.resultLimit)
        snapIndex.visitAssembly(PCBBox([point], margin: radius)) { index in
            let snap = snaps[index], instance = instances[snap.instance], target = snap.target
            guard (includeExcluded || instance.fitted), side == nil || instance.side == side,
                  PCBGeometry.distance(point, target.position) <= radius else { return }
            Self.insert(target, into: &result) { a, b in
                if a.kind != b.kind { return a.kind == .componentCenter }
                let ad = PCBGeometry.distance(point, a.position), bd = PCBGeometry.distance(point, b.position)
                if ad != bd { return ad < bd }
                if a.id != b.id { return a.id.uuidString < b.id.uuidString }
                if a.position.x != b.position.x { return a.position.x < b.position.x }
                return a.position.y < b.position.y
            }
        }
        return result
    }

    private static func transform(componentID: UUID, placement: ManufacturingPlacement, thickness: Double,
                                  binding: ManufacturingModelBinding?) -> [Double] {
        let base = ElectronicsGeometry.modelTransform(
            placement: .init(componentID: componentID, position: placement.position,
                             rotationDegrees: placement.rotationDegrees, side: placement.side),
            thickness: thickness, offset: binding?.offset ?? .init())
        let angles = binding?.rotationDegrees ?? .init()
        let x = ElectronicsGeometry.normalizedDegrees(angles.x) * .pi / 180
        let y = ElectronicsGeometry.normalizedDegrees(angles.y) * .pi / 180
        let z = ElectronicsGeometry.normalizedDegrees(angles.z) * .pi / 180
        let cx = cos(x), sx = sin(x), cy = cos(y), sy = sin(y), cz = cos(z), sz = sin(z)
        let local = [cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
                     sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
                     -sy, cy * sx, cy * cx]
        var result = base
        for row in 0..<3 {
            for column in 0..<3 {
                result[row * 4 + column] = (0..<3).reduce(0) { $0 + base[row * 4 + $1] * local[$1 * 3 + column] }
            }
        }
        return result
    }

    private static func point(_ p: PCBPoint3, _ m: [Double]) -> PCBPoint3 {
        .init(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
              m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
              m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
    }

    /// Monotone convex hull of a convex part's projected vertices. Projection and
    /// convex hull commute, so this is the exact silhouette of the part mesh.
    private static func hull(_ points: [PCBPoint]) -> [PCBPoint] {
        let sorted = Set(points).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        var lower: [PCBPoint] = [], upper: [PCBPoint] = []
        for point in sorted {
            while lower.count >= 2 && PCBGeometry.cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2 && PCBGeometry.cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private static func distance(_ point: PCBPoint, _ polygon: [PCBPoint]) -> Double {
        guard !polygon.isEmpty else { return .infinity }
        if polygon.count >= 3 && PCBGeometry.inside(point, polygon) { return 0 }
        if polygon.count == 1 { return PCBGeometry.distance(point, polygon[0]) }
        var distance = Double.infinity
        let count = polygon.count == 2 ? 1 : polygon.count
        for i in 0..<count {
            distance = min(distance, PCBGeometry.distance(point, PCBGeometry.nearest(point, polygon[i], polygon[(i + 1) % polygon.count])))
        }
        return distance
    }

    private static func valid(_ point: PCBPoint, _ radius: Double) -> Bool {
        // World geometry can extend beyond the validated CPL coordinate range after
        // a valid local offset. Leave room for that rigid transformation.
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000 &&
            radius.isFinite && radius >= 0 && radius <= 1_000_000
    }
    private static func insert<T>(_ item: T, into result: inout [T], before: (T, T) -> Bool) {
        if result.count == resultLimit, let last = result.last, !before(item, last) { return }
        var low = 0, high = result.count
        while low < high {
            let mid = (low + high) / 2
            if before(item, result[mid]) { high = mid } else { low = mid + 1 }
        }
        result.insert(item, at: low)
        if result.count > resultLimit { result.removeLast() }
    }
    private static func limitFailure(_ id: UUID) -> ElectronicsFailure {
        ElectronicsManufacturingImport.failure("assembly_snapshot_limit", "Troppi dettagli 3D: ridurre il numero di componenti o usare modelli più semplici.", [id])
    }
}

private extension PCBIndex {
    /// Streaming traversal keeps cursor allocations bounded by tree depth/results.
    func visitAssembly(_ box: PCBBox, _ visit: (Int) -> Void) {
        guard !nodes.isEmpty else { return }
        var stack = [0]
        stack.reserveCapacity(32)
        while let i = stack.popLast() {
            let node = nodes[i]
            guard node.box.intersects(box) else { continue }
            for item in node.items { visit(item) }
            if let left = node.left { stack.append(left) }
            if let right = node.right { stack.append(right) }
        }
    }
}
