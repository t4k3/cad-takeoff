import Foundation
import CADCore

struct CADToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Bounded validation at the assistant boundary, before generating any mesh.
/// Core-wide file/import validation remains a separate task (T03).
enum CADToolValidation {
    static func dimension(_ value: Double) throws {
        guard value.isFinite, (0.01...100000).contains(value) else {
            throw CADToolFailure("Dimensione fuori limite: usare 0,01–100000 mm.")
        }
    }
    static func coordinate(_ value: Double) throws {
        guard value.isFinite, abs(value) <= 100000 else { throw CADToolFailure("Coordinata non valida (limite ±100000 mm).") }
    }
    static func profile(_ points: [Vec2]) throws {
        guard (3...128).contains(points.count) else { throw CADToolFailure("Il profilo richiede 3–128 vertici.") }
        for p in points { try coordinate(p.x); try coordinate(p.y) }
        let n = points.count
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n], c = points[(i + 2) % n]
            guard abs((b - a).cross(c - b)) > 1e-8 else {
                throw CADToolFailure("Vertici ripetuti o consecutivi allineati: semplificare il profilo.")
            }
            for j in (i + 1)..<n where j != (i + 1) % n && (j + 1) % n != i {
                if intersects(a, b, points[j], points[(j + 1) % n]) {
                    throw CADToolFailure("Il profilo si interseca o si tocca: usare un contorno semplice senza fori.")
                }
            }
        }
        let p = Profile2D(points: points)
        guard p.area > 1e-8, p.triangulate().count == n - 2 else { throw CADToolFailure("Impossibile triangolare il profilo completo.") }
    }
    private static func intersects(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let abC = (b - a).cross(c - a), abD = (b - a).cross(d - a)
        let cdA = (d - c).cross(a - c), cdB = (d - c).cross(b - c)
        func on(_ p: Vec2, _ q: Vec2, _ r: Vec2, _ cross: Double) -> Bool {
            abs(cross) <= 1e-8 && r.x >= min(p.x, q.x) - 1e-8 && r.x <= max(p.x, q.x) + 1e-8
                && r.y >= min(p.y, q.y) - 1e-8 && r.y <= max(p.y, q.y) + 1e-8
        }
        return (abC * abD < 0 && cdA * cdB < 0) || on(a, b, c, abC) || on(a, b, d, abD)
            || on(c, d, a, cdA) || on(c, d, b, cdB)
    }
    static func feature(_ feature: Feature) throws {
        guard !feature.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.name.count <= 160 else {
            throw CADToolFailure("Nome richiesto (massimo 160 caratteri).")
        }
        for value in [feature.position.x, feature.position.y, feature.position.z] { try coordinate(value) }
        switch feature.kind {
        case let .box(w, d, h): for v in [w, d, h] { try dimension(v) }
        case let .cylinder(r, h): try dimension(r); try dimension(h)
        case let .extrude(p, h): try dimension(h); try profile(p.points)
        case let .hole(spec):
            do { try spec.validate() } catch { throw CADToolFailure(error.localizedDescription) }
            for c in spec.centers { try coordinate(c.x); try coordinate(c.y); try coordinate(c.z) }
        }
    }
    static func mesh(_ mesh: Mesh) throws {
        guard !mesh.isEmpty, mesh.indices.count % 3 == 0, mesh.indices.allSatisfy({ Int($0) < mesh.vertices.count }),
              mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.volume.isFinite, mesh.volume > 1e-10 else { throw CADToolFailure("Mesh vuota o non valida.") }
        for i in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(i)
            guard (b - a).cross(c - a).length > 1e-10 else { throw CADToolFailure("Triangolo degenere.") }
        }
        guard MeshValidator.validate(mesh).isWatertight else { throw CADToolFailure("La mesh non è chiusa.") }
    }
}
