import CADCore
import simd

/// Drawing in a sketch as the user does it: snapping onto lines, circles, crossings and lined-up
/// points; ending a line with a double click, Esc or another tool.
@main
struct SketchTests {
    @MainActor static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FALLITO: \(what)") } }
        func at(_ x: Double, _ y: Double) -> SIMD3<Float> { SIMD3(Float(x), Float(y), 0) }
        func near(_ a: Vec2?, _ x: Double, _ y: Double) -> Bool { a.map { abs($0.x - x) < 1e-4 && abs($0.y - y) < 1e-4 } ?? false }

        // A 40 × 20 rectangle, then a line starting on its top side (not at a vertex).
        let s = SketchSession(sketch: Sketch(name: "Prova"))
        s.vertexSnap = 1
        s.tool = .rectangle
        s.click(at(0, 0)); s.click(at(40, 20))
        s.tool = .line
        s.hover(at(10.3, 20.4), screen: nil)
        check(near(s.cursor, 10.3, 20) && s.snapped?.kind == .onCurve, "il cursore si aggancia al lato del rettangolo")
        s.click(at(10.3, 20.4))
        // Lined up with the start: straight up.
        s.hover(at(10.6, 35), screen: nil)
        check(near(s.cursor, 10.3, 35) && !s.aligned.isEmpty, "allineato in verticale col punto di partenza")
        s.click(at(10.6, 35))
        // Double click (the same point again) ends the line.
        s.click(at(10.6, 35))
        check(s.shapes.count == 2 && s.pending.isEmpty, "il doppio clic chiude la linea")
        if case let .polyline(p, closed)? = s.shapes.last?.kind { check(p.count == 2 && !closed, "linea di due punti") } else { check(false, "polilinea") }
        let kinds = s.sketch.constraints.map(\.kind)
        check(kinds.contains { if case .pointOnLine = $0 { true } else { false } }, "vincolo punto su linea col rettangolo")
        check(kinds.contains { if case .vertical = $0 { true } else { false } }, "vincolo verticale")

        // A circle, and a point snapped onto its rim.
        s.tool = .circle
        s.click(at(100, 0)); s.click(at(110, 0))
        s.tool = .line
        s.hover(at(100.5, 10.6), screen: nil)
        check(s.snapped?.kind == .onCurve && s.cursor.map { abs(($0 - Vec2(100, 0)).length - 10) < 1e-6 } == true, "aggancio sulla circonferenza")

        // Where two lines cross.
        s.click(at(60, -10)); s.click(at(80, 10)); s.click(at(80, 10))
        s.click(at(60, 10)); s.click(at(80, -10)); s.click(at(80, -10))
        s.hover(at(70.4, 0.3), screen: nil)
        check(s.snapped?.kind == .intersection && near(s.cursor, 70, 0), "aggancio all'incrocio di due linee")

        // Esc keeps what is drawn; so does picking another tool.
        let before = s.shapes.count
        s.click(at(0, -30)); s.click(at(20, -30))
        check(s.cancel() && s.shapes.count == before + 1 && s.pending.isEmpty, "Esc termina la linea tenendola")
        s.click(at(0, -40)); s.click(at(20, -45))
        s.tool = .circle
        check(s.shapes.count == before + 2, "cambiare strumento tiene la linea")
        // A single point is not a line: Esc just drops it.
        s.tool = .line
        s.click(at(0, -60))
        check(s.cancel() && s.shapes.count == before + 2 && s.pending.isEmpty, "Esc con un punto solo lo scarta")

        // Nothing near: the grid (1 mm).
        s.hover(at(-20.3, -70.6), screen: nil)
        check(s.snapped == nil && near(s.cursor, -20, -71), "altrove, la griglia")

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: schizzo — agganci e fine linea")
    }
}
