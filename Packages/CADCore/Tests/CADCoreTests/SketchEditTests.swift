import Foundation
import Testing
@testable import CADCore

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }
private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { (a - b).length < tol }
private func line(_ a: Vec2, _ b: Vec2) -> SketchShape { SketchShape(kind: .polyline([a, b], closed: false)) }

@Test func trimCutsALineBackToTheCrossingAndDropsALoneLine() {
    let h = line(Vec2(-10, 0), Vec2(10, 0)), v = line(Vec2(0, -10), Vec2(0, 10))
    var sketch = Sketch(name: "S", shapes: [h, v])
    // The right arm of the cross goes: the horizontal line now ends at the crossing.
    #expect(sketch.trimPiece(at: Vec2(6, 0.1), tolerance: 1)!.count == 2)
    let r1 = sketch.trim(at: Vec2(6, 0.1), tolerance: 1)
    #expect(r1)
    let left = sketch.shapes.first { $0.id == h.id }!
    #expect(near(left.point(0)!, Vec2(-10, 0)) && near(left.point(1)!, Vec2(0, 0)))
    let r2 = sketch.trim(at: Vec2(50, 50), tolerance: 1)
    #expect(!r2)
    // A line crossing nothing disappears.
    var lone = Sketch(name: "L", shapes: [line(Vec2(0, 0), Vec2(5, 0))])
    let r3 = lone.trim(at: Vec2(2, 0), tolerance: 1)
    #expect(r3 && lone.shapes.isEmpty)
}

@Test func trimOpensARectangleAndKeepsItsOtherDimensions() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    let cut = line(Vec2(20, -5), Vec2(20, 25))
    var sketch = Sketch(name: "S", shapes: [r, cut], constraints: [.init(.length(.segment(r.id, 1), 20))])
    #expect(sketch.faces.count == 2)
    // Top side, right piece: the right half is no longer closed, the left one still is.
    let r4 = sketch.trim(at: Vec2(30, 20), tolerance: 1)
    #expect(r4)
    let faces = sketch.faces
    #expect(faces.count == 1 && near(faces[0].area, 400, 1e-6))
    // The right side kept its length, and the other sides their horizontal/vertical.
    let right = sketch.constraints.first { if case .length = $0.kind { true } else { false } }
    #expect(right != nil)
    if case let .length(.segment(id, j), 20)? = right?.kind, let (a, b) = sketch.shapes.first(where: { $0.id == id })?.segment(j) {
        #expect(near(a.x, 40) && near(b.x, 40))
    } else { Issue.record("length constraint lost") }
    #expect(sketch.constraints.filter { if case .vertical = $0.kind { true } else { false } }.count == 2)
    let ok = sketch.solve()
    #expect(ok)
}

@Test func trimTurnsACircleIntoAnArc() {
    let c = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 10))
    let d = line(Vec2(-15, 0), Vec2(15, 0))
    var sketch = Sketch(name: "S", shapes: [c, d])
    let upper = sketch.trim(at: Vec2(0, 10), tolerance: 1)   // upper half away
    #expect(upper)
    guard case let .arc(_, r, a0, a1) = sketch.shapes.first(where: { $0.id == c.id })?.kind else { Issue.record("no arc"); return }
    #expect(near(r, 10) && near(SketchShape.sweep(a0, a1), .pi, 1e-9))
    #expect(near(sin(a0 + SketchShape.sweep(a0, a1) / 2), -1, 1e-9))   // the lower half is left
    let faces = sketch.faces
    #expect(faces.count == 1 && abs(faces[0].area - .pi * 50) < 0.3)
    // Then the diameter's ends: the half disc stays closed only with the middle kept.
    let r5 = sketch.trim(at: Vec2(13, 0), tolerance: 1)
    let r6 = sketch.trim(at: Vec2(-13, 0), tolerance: 1)
    #expect(r5 && r6)
    #expect(sketch.faces.count == 1)
}

@Test func extendReachesTheNextLineOrArc() {
    let h = line(Vec2(0, 0), Vec2(10, 0)), wall = line(Vec2(30, -10), Vec2(30, 10))
    var sketch = Sketch(name: "S", shapes: [h, wall], constraints: [.init(.length(.segment(h.id, 0), 10)), .init(.horizontal(.segment(h.id, 0)))])
    let r7 = sketch.extend(at: Vec2(9, 0.2), tolerance: 1)
    #expect(r7)
    #expect(near(sketch.shapes[0].point(1)!, Vec2(30, 0)))
    // The length no longer holds and went; horizontal stays.
    #expect(sketch.constraints.count == 1)
    // The other end towards a circle on the left.
    sketch.shapes.append(SketchShape(kind: .circle(center: Vec2(-20, 0), radius: 5)))
    let r8 = sketch.extend(at: Vec2(1, 0.2), tolerance: 1)
    #expect(r8)
    #expect(near(sketch.shapes[0].point(0)!, Vec2(-15, 0)))
    // Nothing to reach: no change.
    var alone = Sketch(name: "A", shapes: [line(Vec2(0, 0), Vec2(1, 0))])
    let r9 = alone.extend(at: Vec2(1, 0), tolerance: 1)
    #expect(!r9)
    // An arc grows along its circle to the line.
    let arc = SketchShape(kind: .arc(center: Vec2(0, 0), radius: 10, start: 0, end: .pi / 4))
    var s2 = Sketch(name: "B", shapes: [arc, line(Vec2(0, 5), Vec2(0, 20))])   // the y axis above: reached at 90°
    let r10 = s2.extend(at: Vec2(7.07, 7.07), tolerance: 1)
    #expect(r10)
    guard case let .arc(_, _, b0, b1) = s2.shapes[0].kind else { Issue.record("no arc"); return }
    #expect(near(b0, 0) && near(b1, .pi / 2, 1e-9))
}

@Test func offsetGrowsClosedShapesAndFollowsAFilletedChain() throws {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    var sketch = Sketch(name: "S", shapes: [r])
    let out = try sketch.offset(r.id, distance: 2, toward: Vec2(50, 50))
    guard case let .rectangle(c, w, h)? = sketch.shapes.first(where: { $0.id == out[0] })?.kind else { Issue.record("no rectangle"); return }
    #expect(near(c, Vec2(-2, -2)) && near(w, 44) && near(h, 24))
    let inward = try sketch.offset(r.id, distance: 2, toward: Vec2(20, 10))
    #expect(sketch.shapes.first { $0.id == inward[0] }!.area == 36 * 16)
    #expect(throws: SketchEditError.self) { try sketch.offset(r.id, distance: 30, toward: Vec2(20, 10)) }

    // A rectangle with a rounded corner: the chain (lines + arc) offset inwards stays closed.
    var rounded = Sketch(name: "R", shapes: [r])
    try rounded.fillet(r.id, vertex: 2, radius: 5)
    let arcID = rounded.shapes.first { if case .arc = $0.kind { true } else { false } }!.id
    let made = try rounded.offset(arcID, distance: 2, toward: Vec2(20, 10))
    #expect(made.count == 2)
    let faces = rounded.faces
    #expect(faces.count == 2)
    let inner = faces.first { $0.holes.isEmpty }!
    let expected = 36.0 * 16 - (9 - .pi * 9 / 4)   // inner fillet radius 3
    #expect(abs(inner.area - expected) < 0.3)
    let ok = rounded.solve()
    #expect(ok)

    // An open L: the corner of the offset lines meets again.
    let l = SketchShape(kind: .polyline([Vec2(0, 20), Vec2(0, 0), Vec2(30, 0)], closed: false))
    var open = Sketch(name: "L", shapes: [l])
    let o = try open.offset(l.id, distance: 3, toward: Vec2(10, 10))
    guard case let .polyline(p, false)? = open.shapes.first(where: { $0.id == o[0] })?.kind else { Issue.record("no polyline"); return }
    #expect(near(p[0], Vec2(3, 20)) && near(p[1], Vec2(3, 3)) && near(p[2], Vec2(30, 3)))
}

@Test func mirroredShapesFollowTheOriginal() throws {
    let axis = SketchShape(kind: .polyline([Vec2(0, -50), Vec2(0, 50)], closed: false), isConstruction: true)
    let l = SketchShape(kind: .polyline([Vec2(5, 0), Vec2(25, 0), Vec2(25, 10)], closed: false))
    let arc = SketchShape(kind: .arc(center: Vec2(10, 20), radius: 4, start: 0, end: .pi / 2))
    var sketch = Sketch(name: "S", shapes: [axis, l, arc], constraints: [.init(.fix(.point(axis.id, 0), Vec2(0, -50))), .init(.vertical(.segment(axis.id, 0)))])
    let copies = try sketch.mirror([l.id, arc.id], about: .segment(axis.id, 0))
    #expect(copies.count == 2)
    let m = sketch.shapes.first { $0.id == copies[0] }!
    #expect(near(m.point(1)!, Vec2(-25, 0)) && near(m.point(2)!, Vec2(-25, 10)))
    let ma = sketch.shapes.first { $0.id == copies[1] }!
    #expect(near(ma.point(0)!, Vec2(-10, 20)) && near(ma.point(1)!, Vec2(-10, 24)) && near(ma.point(2)!, Vec2(-14, 20)))
    let first = sketch.solve()
    #expect(first)
    // The original gets a length: the copy follows.
    sketch.constraints.append(.init(.length(.segment(l.id, 0), 40)))
    let ok = sketch.solve()
    #expect(ok)
    let o = sketch.shapes.first { $0.id == l.id }!, c = sketch.shapes.first { $0.id == copies[0] }!
    #expect(near(c.point(1)!.x, -o.point(1)!.x, 1e-6) && near(c.point(1)!.y, o.point(1)!.y, 1e-6))
    #expect(near((o.point(1)! - o.point(0)!).length, 40, 1e-6))
    #expect(throws: SketchEditError.self) { try sketch.mirror([l.id], about: .point(l.id, 0)) }
}
