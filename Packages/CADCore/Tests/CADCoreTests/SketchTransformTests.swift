import Foundation
import Testing
@testable import CADCore

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { (a - b).length < tol }
private func line(_ a: Vec2, _ b: Vec2) -> SketchShape { SketchShape(kind: .polyline([a, b], closed: false)) }

@Test func translatingMovesEveryKindOfEntity() {
    let l = line(Vec2(0, 0), Vec2(10, 0))
    let c = SketchShape(kind: .circle(center: Vec2(5, 5), radius: 2))
    let slot = SketchShape(kind: .slot(start: Vec2(0, 0), end: Vec2(10, 0), width: 4))
    let arc = SketchShape(kind: .arc(center: Vec2(0, 0), radius: 3, start: 0, end: .pi / 2))
    let bez = SketchShape(kind: .bezier(start: Vec2(0, 0), control1: Vec2(5, 8), control2: Vec2(10, 8), end: Vec2(15, 0)))
    let delta = Vec2(3, -4)
    let moved = { (s: SketchShape) in s.transformed(rotating: 0, around: Vec2(0, 0), moving: delta) }
    #expect(near(moved(l).point(0)!, Vec2(3, -4)))
    if case let .circle(center, r) = moved(c).kind { #expect(near(center, Vec2(8, 1)) && r == 2) } else { Issue.record("cerchio") }
    if case let .slot(a, b, w) = moved(slot).kind { #expect(near(a, Vec2(3, -4)) && near(b, Vec2(13, -4)) && w == 4) } else { Issue.record("asola") }
    if case let .arc(center, _, a0, a1) = moved(arc).kind { #expect(near(center, Vec2(3, -4)) && a0 == 0 && a1 == .pi / 2) } else { Issue.record("arco") }
    if case let .bezier(p0, c1, c2, p3) = moved(bez).kind {
        #expect(near(p0, Vec2(3, -4)) && near(c1, Vec2(8, 4)) && near(c2, Vec2(13, 4)) && near(p3, Vec2(18, -4)))
    } else { Issue.record("bezier") }
}

@Test func quarterTurnsKeepRectanglesAxisAligned() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    let turned = r.transformed(rotating: .pi / 2, around: Vec2(0, 0), moving: Vec2(0, 0))
    guard case let .rectangle(corner, w, h) = turned.kind else { Issue.record("ancora rettangolo"); return }
    #expect(near(corner, Vec2(-20, 0)))
    #expect(abs(w - 20) < 1e-9 && abs(h - 40) < 1e-9)
}

@Test func otherAnglesTurnARectangleIntoAProfile() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    let turned = r.transformed(rotating: .pi / 6, around: Vec2(0, 0), moving: Vec2(0, 0))
    guard case let .polyline(points, closed) = turned.kind else { Issue.record("polilinea"); return }
    #expect(closed && points.count == 4)
    // The corners go round by 30°: the far one lands at (40 cos 30°, 40 sin 30°).
    #expect(near(points[1], Vec2(40 * cos(.pi / 6), 40 * sin(.pi / 6))))
    #expect(abs(turned.area - r.area) < 1e-9)
}

@Test func rotatingAPolygonTurnsItsRotationAndCentre() {
    let p = SketchShape(kind: .polygon(center: Vec2(10, 0), radius: 5, sides: 6, rotation: 0.2, circumscribed: false))
    let turned = p.transformed(rotating: .pi / 2, around: Vec2(0, 0), moving: Vec2(0, 0))
    if case let .polygon(center, radius, sides, rotation, circ) = turned.kind {
        #expect(near(center, Vec2(0, 10)) && radius == 5 && sides == 6 && !circ)
        #expect(abs(rotation - (0.2 + .pi / 2)) < 1e-9)
    } else { Issue.record("poligono") }
}

@Test func transformKeepsTheFlagsAndLeaves3DAlone() {
    let l = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false), isConstruction: true)
    let moved = l.transformed(rotating: 0, around: Vec2(0, 0), moving: Vec2(0, 5))
    #expect(moved.isConstruction)
    let p3 = SketchShape(kind: .point3D(position: Vec3(1, 2, 3)))
    #expect(p3.transformed(rotating: .pi, around: Vec2(0, 0), moving: Vec2(9, 9)) == p3)
}

@Test func movingALineKeepsItsHorizontalConstraint() {
    let l = line(Vec2(0, 0), Vec2(10, 0))
    var sketch = Sketch(name: "S", shapes: [l], constraints: [.init(.horizontal(.segment(l.id, 0)))])
    let ok = sketch.transform([l.id], rotating: 0, around: Vec2(0, 0), moving: Vec2(4, 6))
    #expect(ok)
    guard let (a, b) = sketch.shapes.first?.segment(0) else { Issue.record("linea sparita"); return }
    #expect(near(a, Vec2(4, 6)) && near(b, Vec2(14, 6)))
}

@Test func aFullyConstrainedSketchRefusesTheMove() {
    let l = line(Vec2(0, 0), Vec2(10, 0))
    var sketch = Sketch(name: "S", shapes: [l],
                        constraints: [.init(.fix(.point(l.id, 0), Vec2(0, 0))),
                                      .init(.fix(.point(l.id, 1), Vec2(10, 0)))])
    let before = sketch
    let ok = sketch.transform([l.id], rotating: 0, around: Vec2(0, 0), moving: Vec2(5, 5))
    #expect(!ok && sketch.shapes == before.shapes)
}

@Test func insertCopiesTheShapeWithANewIdentityAndWithoutConstraints() {
    let circle = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 5), isConstruction: true)
    var sketch = Sketch(name: "S", shapes: [circle],
                        constraints: [.init(.radius(.circle(circle.id, 0), 5))])
    let copy = sketch.insert(copies: sketch.shapes, moving: Vec2(20, 0))
    #expect(copy.count == 1 && copy[0] != circle.id && sketch.shapes.count == 2)
    guard let c = sketch.shapes.last, case let .circle(center, radius) = c.kind else { Issue.record("copia"); return }
    #expect(near(center, Vec2(20, 0)) && radius == 5 && c.isConstruction)
    #expect(sketch.constraints.count == 1)
}
