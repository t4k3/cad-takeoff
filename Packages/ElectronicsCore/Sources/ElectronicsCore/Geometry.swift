import Foundation

public enum ElectronicsGeometry {
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        let angle = degrees.truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : (angle == 0 ? 0 : angle)
    }

    /// Bottom footprints mirror local X, then rotate in the shared top-view frame.
    /// Used by pads, placement centroid and the mechanical adapter, preventing three conventions.
    public static func boardPoint(_ local: PCBPoint, placement: ComponentPlacement) -> PCBPoint {
        let angle = normalizedDegrees(placement.rotationDegrees) * .pi / 180
        let x = placement.side == .bottom ? -local.x : local.x
        return PCBPoint(placement.position.x + cos(angle) * x - sin(angle) * local.y,
                        placement.position.y + sin(angle) * x + cos(angle) * local.y)
    }

    /// Right-handed rigid transform, row-major 4x4, acting on column vectors.
    /// Top mounting plane z=thickness; bottom z=0. Bottom uses Rz(angle)*Ry(pi),
    /// not a reflection of a 3D mesh (which would reverse winding and normals).
    public static func modelTransform(placement: ComponentPlacement, thickness: Double,
                                      offset: PCBPoint3 = .init()) -> [Double] {
        let angle = normalizedDegrees(placement.rotationDegrees) * .pi / 180
        let c = cos(angle), s = sin(angle), flip = placement.side == .bottom ? -1.0 : 1.0
        let x = c * flip * offset.x - s * offset.y + placement.position.x
        let y = s * flip * offset.x + c * offset.y + placement.position.y
        let z = flip * offset.z + (placement.side == .top ? thickness : 0)
        return [c * flip, -s, 0, x, s * flip, c, 0, y, 0, 0, flip, z, 0, 0, 0, 1]
    }

    static func valid(_ value: Double) -> Bool { value.isFinite && abs(value) <= 100_000 }
    static func valid(_ p: PCBPoint) -> Bool { valid(p.x) && valid(p.y) }
    static func validAngle(_ a: Double) -> Bool { a.isFinite && abs(a) <= 360_000 }
    private static func cross(_ a: PCBPoint, _ b: PCBPoint, _ c: PCBPoint) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    private static func onSegment(_ p: PCBPoint, _ a: PCBPoint, _ b: PCBPoint) -> Bool {
        abs(cross(a, b, p)) < 1e-9 && p.x >= min(a.x, b.x) - 1e-9 && p.x <= max(a.x, b.x) + 1e-9 &&
        p.y >= min(a.y, b.y) - 1e-9 && p.y <= max(a.y, b.y) + 1e-9
    }
    private static func intersects(_ a: PCBPoint, _ b: PCBPoint, _ c: PCBPoint, _ d: PCBPoint) -> Bool {
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        return (abC * abD < 0 && cdA * cdB < 0) || onSegment(c, a, b) || onSegment(d, a, b) ||
            onSegment(a, c, d) || onSegment(b, c, d)
    }
    static func simplePolygon(_ points: [PCBPoint]) -> Bool {
        guard points.count >= 3, points.allSatisfy(valid) else { return false }
        var area = 0.0
        for i in points.indices {
            let next = (i + 1) % points.count
            let a = points[i], b = points[next]
            guard hypot(b.x - a.x, b.y - a.y) > 1e-6 else { return false }
            area += a.x * b.y - b.x * a.y
            let previous = points[(i + points.count - 1) % points.count]
            // Reject adjacent edges that double back along one another.
            if abs(cross(previous, a, b)) < 1e-9 &&
                (previous.x - a.x) * (b.x - a.x) + (previous.y - a.y) * (b.y - a.y) > 0 { return false }
            for j in points.indices where j > i {
                let jNext = (j + 1) % points.count
                if j == next || jNext == i { continue }
                if intersects(a, b, points[j], points[jNext]) { return false }
            }
        }
        return abs(area) > 1e-9
    }
}
