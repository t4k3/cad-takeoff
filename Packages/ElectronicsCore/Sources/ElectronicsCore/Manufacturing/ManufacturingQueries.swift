import Foundation

public struct ManufacturingPick: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case component, primitive, drill }
    public let id: UUID
    public let kind: Kind
    /// Distance to a visible witness, in mm; zero when the point belongs to the object.
    public let distance: Double
}

public struct ManufacturingSnapTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case componentCenter, drillCenter, vertex }
    /// Persistent subject ID. Multiple contour vertices can share a primitive ID.
    public let id: UUID
    public let position: PCBPoint
    public let kind: Kind
}

/// Immutable, indexed CAM cursor queries. Build off the UI actor and reuse until the
/// package changes. Construction is cancellable. Results are capped at 256 items.
///
/// `layerIDs` filters artwork only; component placement markers and drills remain
/// independently selectable. Components have no inferred footprint or body bounds.
/// Primitive point membership respects the ordered local mask and subsequent layer
/// clears. A clear aperture hole does not erase an unrelated object beneath it.
///
/// Positive artwork tolerance uses analytic boundary witnesses, verified against the
/// final composite. It is conservative: a clipped intersection can be omitted when
/// only that intersection, rather than a nearest boundary witness, is within reach.
/// This is not a general Boolean distance solver. No removed material is returned.
public struct ManufacturingSnapshot: Sendable {
    private enum Item: Sendable {
        case component(UUID, PCBPoint)
        case drill(ManufacturingDrill)
        case primitive(ManufacturingPrimitive, layerID: UUID, order: Int)
    }
    private struct Snap: Sendable {
        let target: ManufacturingSnapTarget
        let primitive: Int?
        let layerID: UUID?
    }
    private let items: [Item]
    private let index: PCBIndex
    private let snaps: [Snap]
    private let snapIndex: PCBIndex
    private static let limit = 256
    private static let numericalTolerance = 1e-9

    public init(package: ManufacturingPackage) throws {
        try Task.checkCancellation()
        try ElectronicsManufacturingImport.requireIntegrity(package)
        var items: [Item] = [], boxes: [PCBBox] = [], snaps: [Snap] = [], snapBoxes: [PCBBox] = []
        var pointCount = 0, shapeCount = 0
        func addSnap(_ id: UUID, _ point: PCBPoint, _ kind: ManufacturingSnapTarget.Kind,
                     primitive: Int? = nil, layer: UUID? = nil) {
            snaps.append(.init(target: .init(id: id, position: point, kind: kind), primitive: primitive, layerID: layer))
            snapBoxes.append(PCBBox([point]))
        }
        for component in package.components {
            try Task.checkCancellation()
            guard let placement = component.placement else { continue }
            items.append(.component(component.id, placement.position)); boxes.append(PCBBox([placement.position]))
            addSnap(component.id, placement.position, .componentCenter)
        }
        for drill in package.drills {
            try Task.checkCancellation()
            items.append(.drill(drill)); boxes.append(PCBBox([drill.position, drill.end ?? drill.position], margin: drill.diameter / 2))
            let end = drill.end ?? drill.position
            addSnap(drill.id, .init((drill.position.x + end.x) / 2, (drill.position.y + end.y) / 2), .drillCenter)
        }
        for layer in package.layers {
            for (order, primitive) in layer.primitives.enumerated() {
                try Task.checkCancellation()
                guard items.count < 500_000 else { throw Self.limitFailure() }
                let itemIndex = items.count
                var bounds: PCBBox?
                var vertices = Set<PCBPoint>()
                for shape in primitive.shapes {
                    shapeCount += 1
                    guard shapeCount <= 1_000_000 else { throw Self.limitFailure() }
                    for contour in shape.contours {
                        pointCount += contour.count
                        guard pointCount <= 2_000_000 else { throw Self.limitFailure() }
                        try Task.checkCancellation()
                        guard !contour.isEmpty else { continue }
                        let box = PCBBox(contour, margin: shape.radius)
                        bounds = bounds.map { PCBBox($0, box) } ?? box
                        if primitive.isDark && shape.isDark {
                            for point in contour where vertices.insert(point).inserted {
                                addSnap(primitive.id, point, .vertex, primitive: itemIndex, layer: layer.id)
                            }
                        }
                    }
                }
                guard let bounds else { continue }
                items.append(.primitive(primitive, layerID: layer.id, order: order)); boxes.append(bounds)
            }
        }
        self.items = items; self.index = try PCBIndex(boxes: boxes)
        self.snaps = snaps; self.snapIndex = try PCBIndex(boxes: snapBoxes)
    }

    public func pick(point: PCBPoint, tolerance: Double, layerIDs: Set<UUID>? = nil) -> [ManufacturingPick] {
        guard Self.valid(point, radius: tolerance) else { return [] }
        let query = PCBBox([point], margin: tolerance)
        var result: [ManufacturingPick] = []
        result.reserveCapacity(Self.limit)
        index.visit(query) { itemIndex in
            let hit: ManufacturingPick?
            switch items[itemIndex] {
            case let .component(id, center):
                let distance = PCBGeometry.distance(point, center)
                hit = distance <= tolerance ? .init(id: id, kind: .component, distance: distance) : nil
            case let .drill(drill):
                let near = PCBGeometry.nearest(point, drill.position, drill.end ?? drill.position)
                let distance = max(0, PCBGeometry.distance(point, near) - drill.diameter / 2)
                hit = distance <= tolerance ? .init(id: drill.id, kind: .drill, distance: distance) : nil
            case let .primitive(primitive, layer, _):
                guard primitive.isDark, layerIDs?.contains(layer) ?? true else { return true }
                if let distance = distance(to: itemIndex, from: point, tolerance: tolerance) {
                    hit = .init(id: primitive.id, kind: .primitive, distance: distance)
                } else { hit = nil }
            }
            if let hit { Self.insert(hit, into: &result, before: Self.pickPrecedes) }
            return true
        }
        return result
    }

    /// Contour vertices are source construction points; rounded contour cores are
    /// not claimed to be sharp physical corners. Hidden/erased vertices are omitted.
    public func snapTargets(near point: PCBPoint, radius: Double, layerIDs: Set<UUID>? = nil) -> [ManufacturingSnapTarget] {
        guard Self.valid(point, radius: radius) else { return [] }
        var result: [ManufacturingSnapTarget] = []
        result.reserveCapacity(Self.limit)
        snapIndex.visit(PCBBox([point], margin: radius)) { index in
            let snap = snaps[index], target = snap.target
            guard snap.layerID.map({ layerIDs?.contains($0) ?? true }) ?? true,
                  PCBGeometry.distance(point, target.position) <= radius else { return true }
            if let item = snap.primitive, !visible(item, at: target.position) { return true }
            Self.insert(target, into: &result) { a, b in
                let ar = Self.snapRank(a.kind), br = Self.snapRank(b.kind)
                if ar != br { return ar < br }
                let ad = PCBGeometry.distance(point, a.position), bd = PCBGeometry.distance(point, b.position)
                if ad != bd { return ad < bd }
                if a.id != b.id { return a.id.uuidString < b.id.uuidString }
                if a.position.x != b.position.x { return a.position.x < b.position.x }
                return a.position.y < b.position.y
            }
            return true
        }
        return result
    }

    private func visible(_ item: Int, at point: PCBPoint) -> Bool {
        guard case let .primitive(primitive, layer, order) = items[item],
              Self.contains(primitive, point) else { return false }
        var erased = false
        index.visit(PCBBox([point])) { candidate in
            guard case let .primitive(other, otherLayer, otherOrder) = items[candidate],
                  !other.isDark, otherLayer == layer, otherOrder > order else { return true }
            if Self.contains(other, point) { erased = true; return false }
            return true
        }
        return !erased
    }

    private func distance(to item: Int, from point: PCBPoint, tolerance: Double) -> Double? {
        if visible(item, at: point) { return 0 }
        guard tolerance > 0, case let .primitive(primitive, layer, order) = items[item] else { return nil }
        var best = Double.infinity
        func consider(_ witness: PCBPoint) {
            let distance = PCBGeometry.distance(point, witness)
            guard distance <= tolerance, distance < best else { return }
            if visible(item, at: witness) { best = distance; return }
            // Clear boundaries belong to the void. Test infinitesimally adjacent
            // material, never a sampling step based on screen scale or tolerance.
            let e = Self.numericalTolerance
            for delta in [(e, 0.0), (-e, 0.0), (0.0, e), (0.0, -e)] {
                let adjacent = PCBPoint(witness.x + delta.0, witness.y + delta.1)
                let actual = PCBGeometry.distance(point, adjacent)
                if actual <= tolerance, visible(item, at: adjacent) { best = min(best, actual) }
            }
        }
        for shape in primitive.shapes { Self.witnesses(shape, near: point, visit: consider) }
        // A later clear's edge can be the nearest surviving material even when the
        // original dark object's boundary is nowhere near the pointer.
        index.visit(PCBBox([point], margin: tolerance)) { candidate in
            guard case let .primitive(other, otherLayer, otherOrder) = items[candidate],
                  !other.isDark, otherLayer == layer, otherOrder > order else { return true }
            for shape in other.shapes { Self.witnesses(shape, near: point, visit: consider) }
            return true
        }
        return best.isFinite ? best : nil
    }

    private static func contains(_ primitive: ManufacturingPrimitive, _ point: PCBPoint) -> Bool {
        var filled = false
        for shape in primitive.shapes where contains(shape, point) { filled = shape.isDark }
        return filled
    }

    private static func contains(_ shape: ManufacturingShape, _ point: PCBPoint) -> Bool {
        var inside = false
        for contour in shape.contours {
            if contour.count == 1 {
                if PCBGeometry.distance(point, contour[0]) <= shape.radius { return true }
                continue
            }
            if contour.count == 2 {
                if PCBGeometry.distance(point, PCBGeometry.nearest(point, contour[0], contour[1])) <= shape.radius { return true }
                continue
            }
            for i in contour.indices {
                let a = contour[i], b = contour[(i + 1) % contour.count]
                if PCBGeometry.distance(point, PCBGeometry.nearest(point, a, b)) <= shape.radius { return true }
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
        }
        return inside
    }

    private static func witnesses(_ shape: ManufacturingShape, near point: PCBPoint, visit: (PCBPoint) -> Void) {
        func circle(_ center: PCBPoint) {
            let d = PCBGeometry.distance(point, center)
            let ux = d > 0 ? (point.x - center.x) / d : 1
            let uy = d > 0 ? (point.y - center.y) / d : 0
            visit(.init(center.x + ux * shape.radius, center.y + uy * shape.radius))
        }
        for contour in shape.contours {
            if contour.count == 1 { circle(contour[0]); continue }
            let edgeCount = contour.count == 2 ? 1 : contour.count
            for i in 0..<edgeCount {
                let a = contour[i], b = contour[(i + 1) % contour.count]
                if shape.radius == 0 { visit(PCBGeometry.nearest(point, a, b)); continue }
                let length = PCBGeometry.distance(a, b)
                if length > 0 {
                    let x = -(b.y - a.y) * shape.radius / length, y = (b.x - a.x) * shape.radius / length
                    for sign in [-1.0, 1.0] {
                        visit(PCBGeometry.nearest(point, .init(a.x + sign * x, a.y + sign * y), .init(b.x + sign * x, b.y + sign * y)))
                    }
                }
            }
            if shape.radius > 0 { for vertex in contour { circle(vertex) } }
        }
    }

    private static func valid(_ point: PCBPoint, radius: Double) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000 &&
            radius.isFinite && radius >= 0 && radius <= 1_000_000
    }
    private static func pickRank(_ kind: ManufacturingPick.Kind) -> Int {
        switch kind { case .component: 0; case .drill: 1; case .primitive: 2 }
    }
    private static func snapRank(_ kind: ManufacturingSnapTarget.Kind) -> Int {
        switch kind { case .componentCenter: 0; case .drillCenter: 1; case .vertex: 2 }
    }
    private static func pickPrecedes(_ a: ManufacturingPick, _ b: ManufacturingPick) -> Bool {
        let ar = pickRank(a.kind), br = pickRank(b.kind)
        if ar != br { return ar < br }
        if a.distance != b.distance { return a.distance < b.distance }
        return a.id.uuidString < b.id.uuidString
    }
    private static func insert<T>(_ item: T, into result: inout [T], before: (T, T) -> Bool) {
        if result.count == limit, let last = result.last, !before(item, last) { return }
        var low = 0, high = result.count
        while low < high {
            let mid = (low + high) / 2
            if before(item, result[mid]) { high = mid } else { low = mid + 1 }
        }
        result.insert(item, at: low)
        if result.count > limit { result.removeLast() }
    }
    private static func limitFailure() -> ElectronicsFailure {
        ManufacturingReadSupport.error("Scelta e agganci", "Pacchetto troppo complesso per l’indice: ridurre il numero di oggetti o punti.")
    }
}

private extension PCBIndex {
    /// Streaming BVH traversal: cursor queries allocate only a tree-depth stack,
    /// never an array containing every broad-phase candidate on a large board.
    func visit(_ box: PCBBox, _ body: (Int) -> Bool) {
        guard !nodes.isEmpty else { return }
        var stack = [0]
        stack.reserveCapacity(32)
        while let i = stack.popLast() {
            let node = nodes[i]
            guard node.box.intersects(box) else { continue }
            for item in node.items { if !body(item) { return } }
            if let left = node.left { stack.append(left) }
            if let right = node.right { stack.append(right) }
        }
    }
}
