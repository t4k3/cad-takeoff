import simd

/// Right-handed matrices with Metal's [0, 1] clip-space depth.
extension simd_float4x4 {
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func orthographic(halfHeight: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let w = halfHeight * aspect
        return simd_float4x4(columns: (
            SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / halfHeight, 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1)))
    }
}

struct Ray {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    /// Intersection with the plane through `point` with normal `normal`.
    func intersect(planePoint point: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float>? {
        let d = simd_dot(normal, direction)
        guard abs(d) > 1e-6 else { return nil }
        let t = simd_dot(normal, point - origin) / d
        return t >= 0 ? origin + direction * t : nil
    }
}
