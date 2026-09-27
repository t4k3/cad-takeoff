import Foundation

/// «Sposta/Copia» (Fusion's Move): bodies turned about an axis through a pivot, then moved.
/// A step of the timeline, so later features see the bodies where they now are.
public struct MoveSpec: Codable, Sendable, Equatable {
    /// Bodies moved (their source features).
    public var bodies: [UUID]
    /// mm along X, Y, Z (world).
    public var translation: Vec3
    /// Rotation axis direction (world) and angle in degrees; about the pivot.
    public var axis: Vec3
    public var angle: Double
    /// Point the rotation turns about; nil = the centre of the bodies' bounding box.
    public var pivot: Vec3?

    public init(bodies: [UUID], translation: Vec3 = .zero, axis: Vec3 = Vec3(0, 0, 1), angle: Double = 0, pivot: Vec3? = nil) {
        self.bodies = bodies; self.translation = translation; self.axis = axis; self.angle = angle; self.pivot = pivot
    }

    public func validate() throws {
        guard !bodies.isEmpty else { throw KernelError.invalidParameter("sposta: nessun corpo scelto") }
        guard translation.isFinite, [translation.x, translation.y, translation.z].allSatisfy({ abs($0) <= 100_000 }) else {
            throw KernelError.invalidParameter("sposta: spostamento oltre ±100000 mm")
        }
        guard angle.isFinite, axis.isFinite, angle == 0 || axis.length > 1e-9 else { throw KernelError.invalidParameter("sposta: asse di rotazione nullo") }
    }

    /// The motion applied to points and to directions.
    func transform(pivot centre: Vec3) -> (point: (Vec3) -> Vec3, direction: (Vec3) -> Vec3) {
        let t = angle * .pi / 180
        let k = angle == 0 ? Vec3(0, 0, 1) : axis.normalized
        let c = cos(t), s = sin(t)
        // Rodrigues: v cosθ + (k×v) sinθ + k (k·v)(1 − cosθ).
        func rotate(_ v: Vec3) -> Vec3 { v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c)) }
        let shift = translation
        return ({ rotate($0 - centre) + centre + shift }, rotate)
    }
}
