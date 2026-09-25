import Foundation

/// Closed 2D profile on the XY plane (sketch). Points are stored counter-clockwise.
public struct Profile2D: Codable, Sendable, Equatable {
    public private(set) var points: [Vec2]

    public init(points: [Vec2]) {
        self.points = Profile2D.signedArea(points) < 0 ? points.reversed() : points
    }

    public static func rectangle(width: Double, height: Double, center: Vec2 = Vec2(0, 0)) -> Profile2D {
        let w = width / 2, h = height / 2
        return Profile2D(points: [
            Vec2(center.x - w, center.y - h), Vec2(center.x + w, center.y - h),
            Vec2(center.x + w, center.y + h), Vec2(center.x - w, center.y + h),
        ])
    }

    public static func circle(radius: Double, segments: Int = 64, center: Vec2 = Vec2(0, 0)) -> Profile2D {
        let n = max(3, segments)
        return Profile2D(points: (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return Vec2(center.x + radius * cos(a), center.y + radius * sin(a))
        })
    }

    public static func regularPolygon(sides: Int, radius: Double, center: Vec2 = Vec2(0, 0)) -> Profile2D {
        circle(radius: radius, segments: sides, center: center)
    }

    public var area: Double { Profile2D.signedArea(points) }

    static func signedArea(_ p: [Vec2]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// Ear-clipping triangulation of a simple CCW polygon. Returns index triples.
    public func triangulate() -> [(Int, Int, Int)] {
        var idx = Array(points.indices)
        var tris: [(Int, Int, Int)] = []
        var guardCounter = 0
        while idx.count > 3 && guardCounter < 10_000 {
            guardCounter += 1
            var clipped = false
            for i in idx.indices {
                let ip = idx[(i + idx.count - 1) % idx.count], ic = idx[i], inx = idx[(i + 1) % idx.count]
                let a = points[ip], b = points[ic], c = points[inx]
                guard (b - a).cross(c - b) > 1e-12 else { continue } // reflex or degenerate
                let containsOther = idx.contains { j in
                    j != ip && j != ic && j != inx && Profile2D.pointInTriangle(points[j], a, b, c)
                }
                if containsOther { continue }
                tris.append((ip, ic, inx))
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break } // non-simple polygon; bail out with what we have
        }
        if idx.count == 3 { tris.append((idx[0], idx[1], idx[2])) }
        return tris
    }

    static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }
}
