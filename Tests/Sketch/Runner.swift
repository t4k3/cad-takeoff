import CADCore
import Foundation
import simd

/// Drawing in a sketch as the user does it: snapping onto lines, circles, crossings and lined-up
/// points; ending a line with a double click, Esc or another tool.
@main
struct SketchTests {
    @MainActor static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            guard !ok else { return }
            failures += 1
            // stderr: stdout is lost when the process stops at the final fatalError.
            FileHandle.standardError.write(Data("FALLITO: \(what)\n".utf8))
        }
        func at(_ x: Double, _ y: Double) -> SIMD3<Float> { SIMD3(Float(x), Float(y), 0) }
        func near(_ a: Vec2?, _ x: Double, _ y: Double) -> Bool { a.map { abs($0.x - x) < 1e-4 && abs($0.y - y) < 1e-4 } ?? false }

        // A 40 × 20 rectangle, then a line starting on its top side (not at a vertex).
        let s = SketchSession(sketch: Sketch(name: "Prova"))
        s.vertexSnap = 1
        s.tool = .rectangle
        s.click(at(0, 0)); s.click(at(40, 20))
        let rectangleShapes = s.shapes.count
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
        check(s.shapes.count == rectangleShapes + 1 && s.pending.isEmpty, "il doppio clic chiude la linea")
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

        // Sketching on a face: the edge of the part is split in pieces by a cut (points at 10 and
        // 25 along it); its midpoint snap is still the middle of the whole 60 mm edge.
        let face = SketchSession(sketch: Sketch(name: "Faccia"))
        face.vertexSnap = 1
        face.references = [SketchSession.straightened([Vec2(0, 0), Vec2(10, 0), Vec2(25, 0), Vec2(60, 0)])]
        face.tool = .line
        face.hover(at(30.4, 0.3), screen: nil)
        check(face.snapped?.kind == .midpoint && near(face.cursor, 30, 0), "punto medio del bordo intero della faccia")

        // A hole's rim split in two half circles (as the booleans leave it), and a rounded corner:
        // no snapping onto their chord points; the middle of the arc and the centres snap.
        let round = SketchSession(sketch: Sketch(name: "Fori"))
        round.vertexSnap = 1
        func arc(_ c: Vec2, _ r: Double, _ from: Double, _ to: Double) -> [Vec2] {
            (0...32).map { k in let t = from + (to - from) * Double(k) / 32; return c + Vec2(cos(t), sin(t)) * r }
        }
        round.references = [arc(Vec2(0, 0), 10, 0, .pi), arc(Vec2(0, 0), 10, .pi, 2 * .pi), arc(Vec2(50, 0), 8, 0, .pi / 2)]
        round.tool = .line
        let chord = Vec2(cos(.pi * 3 / 32), sin(.pi * 3 / 32)) * 10
        round.hover(at(chord.x + 0.05, chord.y + 0.05), screen: nil)
        check(round.snapped?.kind != .vertex, "niente aggancio sui punti delle corde di un foro")
        round.hover(at(0.3, -0.4), screen: nil)
        check(round.snapped?.kind == .center && near(round.cursor, 0, 0), "centro del foro diviso in due metà")
        let middle = Vec2(50, 0) + Vec2(cos(.pi / 4), sin(.pi / 4)) * 8
        round.hover(at(middle.x + 0.3, middle.y + 0.2), screen: nil)
        check(round.snapped?.kind == .midpoint && near(round.cursor, middle.x, middle.y), "metà dell'arco del raccordo")
        round.hover(at(50.2, 0.9), screen: nil)
        check(round.snapped?.kind == .center && near(round.cursor, 50, 0), "centro del raccordo")
        // With the cursor on an edge a little off its middle, the midpoint wins over sliding along it.
        face.hover(at(31.2, 0), screen: nil)
        check(face.snapped?.kind == .midpoint, "il punto medio si prende anche stando sulla linea")

        // Crosshair only where a click places a point; the arrow where it picks something.
        let tools = SketchSession(sketch: Sketch(name: "Puntatore"))
        for t in [SketchSession.Tool.line, .rectangle, .circle, .polygon, .slot, .arc, .spline, .bezier] {
            tools.tool = t; check(tools.placesPoints, "\(t.rawValue): crocetta")
        }
        for t in [SketchSession.Tool.select, .fillet, .chamfer, .trim, .extend, .offset, .mirror, .move, .rotate, .dimension] {
            tools.tool = t; check(!tools.placesPoints, "\(t.rawValue): freccia")
        }
        tools.constraintTool = .parallel
        check(!tools.placesPoints, "vincolo: freccia")

        // The Bezier tool: four clicks (start, two handles, end) draw the cubic curve.
        let bez = SketchSession(sketch: Sketch(name: "Bezier"))
        bez.vertexSnap = 1
        bez.tool = .bezier
        for p in [at(0, 0), at(10, 20), at(30, 20), at(40, 0)] { bez.click(p) }
        check(bez.shapes.count == 1 && bez.pending.isEmpty, "la Bezier nasce dai quattro clic")
        if case let .bezier(p0, c1, c2, p3)? = bez.shapes.last?.kind {
            check(p0.x == 0 && c1.y == 20 && c2.x == 30 && p3.x == 40, "i quattro punti finiscono nella curva")
        } else {
            check(false, "bezier")
        }
        // A half-drawn curve is dropped when another tool is picked.
        bez.click(at(0, 50)); bez.click(at(10, 60))
        bez.tool = .line
        check(bez.pending.isEmpty && bez.shapes.count == 1, "cambiare strumento scarta la Bezier a metà")

        // A point on the curve: the constraint takes the curve's parameter.
        bez.tool = .point
        bez.click(at(5, 5))
        check(bez.shapes.count == 2, "punto per il vincolo sulla Bezier")
        bez.constraintTool = .pointOnBezier
        bez.click(at(5, 5))
        bez.click(at(20, 15))
        let bezKinds = bez.sketch.constraints.map(\.kind)
        check(bezKinds.contains { if case let .pointOnBezier(_, _, t) = $0 { (0...1).contains(t) } else { false } }, "vincolo punto su Bezier col parametro t")

        // Construction geometry: the switch applies to the next entities, and the toolbar button
        // converts the selected one (a construction profile is no longer a profile).
        let con = SketchSession(sketch: Sketch(name: "Costruzione"))
        con.vertexSnap = 1
        con.constructionNext = true
        con.tool = .line
        con.click(at(0, 0)); con.click(at(20, 0)); con.click(at(20, 0))
        check(con.shapes.last?.isConstruction == true, "linea di costruzione col commutatore acceso")
        con.constructionNext = false
        con.tool = .rectangle
        con.click(at(0, 20)); con.click(at(30, 50))
        check(con.shapes.last?.isConstruction == false, "commutatore spento: entità normale")
        check(!con.faces.isEmpty, "il rettangolo normale fa un profilo")
        con.toggleConstructionSelection()
        check(con.shapes.last?.isConstruction == true && con.faces.isEmpty, "di costruzione non fa più profilo")
        con.toggleConstructionSelection()
        check(con.shapes.last?.isConstruction == false && !con.faces.isEmpty, "e torna a farlo")
        // The switch never touches off-plane entities, which never bound a profile anyway.
        con.constructionNext = true
        con.tool = .point3D
        con.click(at(5, 5))
        check(con.shapes.last?.isConstruction == false, "i punti 3D restano normali")

        // Sposta and Ruota: the selected entity follows the clicked points.
        let mv = SketchSession(sketch: Sketch(name: "Sposta"))
        mv.vertexSnap = 1
        mv.tool = .rectangle
        mv.click(at(0, 0)); mv.click(at(20, 10))
        check(mv.selection != nil && mv.shapes.count == 1, "rettangolo da spostare")
        mv.tool = .move
        mv.click(at(0, 0))
        check(mv.moveFrom != nil && mv.notice != nil, "primo clic: il punto di partenza")
        mv.click(at(5, 3))
        check(mv.moveFrom == nil && mv.notice == nil, "secondo clic: spostato")
        if let s = mv.selectedShape, case let .rectangle(c, w, h) = s.kind {
            check(abs(c.x - 5) < 1e-6 && abs(c.y - 3) < 1e-6 && abs(w - 20) < 1e-6 && abs(h - 10) < 1e-6, "il rettangolo è dove è stato portato")
        } else { check(false, "rettangolo spostato") }
        mv.tool = .rotate
        mv.click(at(0, 0))
        check(mv.rotateCenter != nil, "primo clic: il centro di rotazione")
        mv.click(at(0, 10))
        check(mv.rotateCenter == nil, "secondo clic: ruotato")
        if let s = mv.selectedShape, case let .rectangle(c, w, h) = s.kind {
            check(abs(c.x + 13) < 1e-6 && abs(c.y - 5) < 1e-6 && abs(w - 10) < 1e-6 && abs(h - 20) < 1e-6, "un quarto di giro: rettangolo ancora dritto")
        } else { check(false, "rettangolo ruotato") }
        mv.tool = .move
        mv.click(at(0, 0))
        check(mv.moveFrom != nil && mv.cancel() && mv.moveFrom == nil, "Esc toglie il punto di partenza")

        // A constraint on the moved entity keeps holding (horizontal), not just the shape.
        let cm = SketchSession(sketch: Sketch(name: "Vincolato"))
        cm.vertexSnap = 1
        cm.tool = .line
        cm.click(at(0, 0)); cm.click(at(10, 0)); cm.click(at(10, 0))
        cm.sketch.constraints = [.init(.horizontal(.segment(cm.shapes[0].id, 0)))]
        cm.tool = .move
        cm.click(at(0, 0)); cm.click(at(0, 20))
        if case let .polyline(pts, _)? = cm.shapes.first?.kind {
            check(near(pts.first, 0, 20) && near(pts.last, 10, 20), "lo spostamento tiene il vincolo orizzontale")
        } else { check(false, "linea spostata") }

        // A sketch pinned by constraints refuses the move and says why.
        let fx = SketchSession(sketch: Sketch(name: "Fisso"))
        fx.tool = .rectangle
        fx.click(at(0, 0)); fx.click(at(10, 10))
        let fxID = fx.shapes[0].id
        fx.sketch.constraints = [.init(.fix(.point(fxID, 0), Vec2(0, 0))),
                                      .init(.fix(.point(fxID, 1), Vec2(10, 0))),
                                      .init(.fix(.point(fxID, 2), Vec2(10, 10)))]
        let fxBefore = fx.shapes
        fx.tool = .move
        fx.click(at(0, 0)); fx.click(at(5, 5))
        check(fx.shapes == fxBefore && fx.notice != nil, "i vincoli che bloccano: niente spostamento, col motivo")

        // Copia/Incolla: the copy gets a fresh ID, lands where asked (or under the cursor), and
        // keeps its construction flag but not the original's constraints.
        let cp = SketchSession(sketch: Sketch(name: "Copia"))
        cp.vertexSnap = 1
        cp.tool = .circle
        cp.click(at(0, 0)); cp.click(at(10, 0))
        check(cp.copySelection() && cp.copiedShapes.count == 1, "cerchio copiato")
        cp.paste(at: Vec2(30, 0))
        check(cp.shapes.count == 2 && cp.shapes.last?.id != cp.shapes.first?.id, "incollato con un ID nuovo")
        if case let .circle(c, r)? = cp.shapes.last?.kind {
            check(abs(c.x - 30) < 1e-6 && abs(r - 10) < 1e-6, "il cerchio incollato è dove richiesto")
        } else { check(false, "cerchio incollato") }
        cp.hover(at(50, 0), screen: nil)
        cp.paste()
        if case let .circle(c, _)? = cp.shapes.last?.kind { check(abs(c.x - 50) < 1e-6, "incolla sotto il cursore") } else { check(false, "incolla al cursore") }
        cp.tool = .point3D
        cp.click(at(60, 0))
        check(!cp.copySelection() && cp.notice != nil, "un punto 3D non si copia nel piano")

        if failures > 0 { fatalError("\(failures) verifiche fallite") }
        print("OK: schizzo — agganci e fine linea")
    }
}
