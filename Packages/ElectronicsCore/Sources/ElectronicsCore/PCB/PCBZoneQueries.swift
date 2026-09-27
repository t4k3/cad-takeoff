import Foundation

public struct PCBZoneHit: Equatable, Sendable {
    public let id: UUID
    public let position: PCBPoint
    public let distance: Double
}
extension PCBSnapshot {
    /// Pick editable outlines, including a zone whose fill is empty. For routing use pick(),
    /// which targets actual copper only. The two operations must not be confused by the UI.
    public func pickZones(point: PCBPoint, tolerance: Double, layer: Int? = nil) -> [PCBZoneHit] {
        guard ElectronicsGeometry.valid(point), tolerance.isFinite, tolerance >= 0 else { return [] }
        var result: [PCBZoneHit] = []
        for i in zoneIndex.query(.init([point],margin:tolerance)) {
            let z = zones[i].zone
            if let layer, z.layer != layer { continue }
            let nearest = PCBGeometry.edges(z.outline).map { PCBGeometry.nearest(point,$0.0,$0.1) }.min { PCBGeometry.distance(point,$0) < PCBGeometry.distance(point,$1) }!
            let inside = PCBGeometry.inside(point,z.outline), distance = inside ? 0 : PCBGeometry.distance(point,nearest)
            if distance <= tolerance { result.append(.init(id:z.id,position:inside ? point : nearest,distance:distance)) }
        }
        return result.sorted { $0.distance == $1.distance ? $0.id.uuidString < $1.id.uuidString : $0.distance < $1.distance }
    }
}
