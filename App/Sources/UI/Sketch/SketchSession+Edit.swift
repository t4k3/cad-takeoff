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
}
