import CADCore
import Foundation

/// Taglia, Estendi, Offset and Specchio in the sketch editor (geometry in CADCore's SketchEdit).
extension SketchSession {
    private var editTolerance: Double { vertexSnap * 1.2 }

    func trim(_ p: Vec2) {
        var next = sketch
        guard next.trim(at: p, tolerance: editTolerance) else { notice = "Niente da tagliare qui: clicca su una linea, un arco o un cerchio."; return }
        notice = nil
        selection = nil
        sketch = next
    }

    func extend(_ p: Vec2) {
        var next = sketch
        guard next.extend(at: p, tolerance: editTolerance) else {
            notice = "Niente da estendere: clicca vicino all'estremo libero di una linea o di un arco che punta verso un'altra curva."
            return
        }
        notice = nil
        sketch = next
    }

    func offsetClick(_ p: Vec2) {
        guard let source = offsetSource else {
            guard let id = pick(p) else { notice = "Clicca una forma da copiare in offset."; return }
            offsetSource = id
            selection = id
            notice = "Ora clicca il lato dove mettere la copia (distanza \(fmt(offsetDistance)) mm)."
            return
        }
        var next = sketch
        do {
            let made = try next.offset(source, distance: offsetDistance, toward: p)
            notice = nil
            sketch = next
            selection = made.first
            offsetSource = nil
        } catch {
            notice = "Offset: " + error.localizedDescription
        }
    }

    func mirrorClick(_ p: Vec2) {
        guard let axis = mirrorAxis else {
            guard let ref = pickRef(p, kinds: [.segment]) else { notice = "Clicca una linea: sarà l'asse di simmetria."; return }
            mirrorAxis = ref
            notice = "Ora clicca le forme da specchiare (Esc per finire)."
            return
        }
        guard let id = pick(p) else { notice = "Clicca una forma da specchiare."; return }
        var next = sketch
        do {
            let made = try next.mirror([id], about: axis)
            guard next.solve() else { notice = "Specchio in conflitto con i vincoli dello schizzo."; return }
            notice = "Specchiato. Clicca altre forme, o Esc per finire."
            sketch = next
            selection = made.first
        } catch {
            notice = "Specchio: " + error.localizedDescription
        }
    }

    /// What the editing tools show under the cursor: the piece Taglia would remove (red), the copy
    /// Offset would make, the Specchio axis and the copy of the shape under the cursor.
    func editOverlay(sketchColor: SIMD4<Float>, selectedColor: SIMD4<Float>) -> [Line] {
        var out: [Line] = []
        func w(_ p: Vec2) -> SIMD3<Float> { world(p, 0.03) }
        func polyline(_ pts: [Vec2], closed: Bool = false, _ color: SIMD4<Float>) {
            guard pts.count >= 2 else { return }
            for i in 0..<(closed ? pts.count : pts.count - 1) { out.append((w(pts[i]), w(pts[(i + 1) % pts.count]), color)) }
        }
        let preview = sketchColor * SIMD4(1, 1, 1, 0.75)
        if let r = revolvePreview { out += revolveOverlay(r) }
        switch tool {
        case .trim:
            if let raw = rawCursor, let piece = sketch.trimPiece(at: raw, tolerance: editTolerance) {
                polyline(piece, SIMD4(1, 0.3, 0.25, 1))
            }
        case .offset:
            if let source = offsetSource, let raw = rawCursor {
                var copy = sketch
                if let made = try? copy.offset(source, distance: offsetDistance, toward: raw) {
                    for id in made { if let s = copy.shapes.first(where: { $0.id == id }) { polyline(s.outline, closed: s.isClosed, preview) } }
                }
            }
        case .mirror:
            if let axis = mirrorAxis, case let .segment(id, i) = axis, let (a, b) = shape(id)?.segment(i) {
                polyline([a, b], selectedColor)
                if let raw = rawCursor, let target = pick(raw) {
                    var copy = sketch
                    if let made = try? copy.mirror([target], about: axis) {
                        for id in made { if let s = copy.shapes.first(where: { $0.id == id }) { polyline(s.outline, closed: s.isClosed, preview) } }
                    }
                }
            }
        default:
            break
        }
        return out
    }

    /// Wireframe of the revolve: the profile at a few angles and the circles its corners trace.
    private func revolveOverlay(_ r: RevolvePreview) -> [Line] {
        let areas = pickedAreas
        guard !areas.isEmpty, (r.axisEnd - r.axisStart).length > 1e-9 else { return [] }
        let color: SIMD4<Float> = r.isCut ? SIMD4(0.95, 0.25, 0.25, 0.9) : SIMD4(0.35, 0.7, 1, 0.9)
        let dir = (r.axisEnd - r.axisStart) * (1 / (r.axisEnd - r.axisStart).length)
        let left = Vec2(-dir.y, dir.x)
        let pts = areas.flatMap { [$0.outline] + $0.holes }
        let offsets: [Double] = pts.flatMap { $0 }.map { dir.cross($0 - r.axisStart) }
        let farthest: Double = offsets.max { abs($0) < abs($1) } ?? 1
        let side: Double = farthest < 0 ? -1 : 1
        let radial = left * side
        let sign = (radial.cross(dir) >= 0 ? 1.0 : -1.0) * (r.reversed ? -1 : 1)
        let span = min(360, max(0.1, r.angle)) * .pi / 180
        func at(_ q: Vec2, _ t: Double) -> SIMD3<Float> {
            let rel = q - r.axisStart
            let h = rel.dot(dir), rad = abs(dir.cross(rel))
            let inPlane = r.axisStart + dir * h + radial * (rad * cos(t))
            return world(inPlane, sign * rad * sin(t))
        }
        var out: [Line] = []
        // The axis, dashed-long.
        out.append((world(r.axisStart - dir * 5, 0.03), world(r.axisEnd + dir * 5, 0.03), color * SIMD4(1, 1, 1, 0.6)))
        let copies = span >= 2 * .pi - 1e-6 ? 8 : 4
        for k in 0...copies {
            let t = span * Double(k) / Double(copies)
            for loop in pts where loop.count >= 2 {
                for i in 0..<loop.count { out.append((at(loop[i], t), at(loop[(i + 1) % loop.count], t), color)) }
            }
        }
        // Circles from the corners (a few per loop, not every facet of a round).
        let steps = max(8, Int(span / (2 * .pi) * 48))
        for loop in pts {
            let stride = max(1, loop.count / 12)
            for i in Swift.stride(from: 0, to: loop.count, by: stride) {
                for s in 0..<steps {
                    out.append((at(loop[i], span * Double(s) / Double(steps)), at(loop[i], span * Double(s + 1) / Double(steps)), color * SIMD4(1, 1, 1, 0.55)))
                }
            }
        }
        return out
    }
}
