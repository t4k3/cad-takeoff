import Foundation

/// 3D vector in millimetres. World convention: Z-up (like slicers), right-handed.
public struct Vec3: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 {
        let l = length
        return l > 1e-12 ? self * (1 / l) : .zero
    }
}

/// 2D point on a sketch plane, in millimetres.
public struct Vec2: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public func cross(_ b: Vec2) -> Double { x * b.y - y * b.x }
}

/// Axis-aligned bounding box.
public struct BoundingBox: Equatable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public var size: Vec3 { max - min }
    public var center: Vec3 { (min + max) * 0.5 }
}
