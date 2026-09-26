import Foundation
import Testing
@testable import CADCore

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }
private func length(_ s: SketchShape, _ i: Int) -> Double {
    let (a, b) = s.segment(i)!
    return ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
}

/// An L bracket drawn roughly, then constrained: horizontal/vertical sides, a fixed corner and four
/// dimensions make it fully defined; changing a dimension moves only what it must.
@Test func lBracketIsFullyConstrainedAndFollowsItsDimensions() throws {
    let rough = [Vec2(0.3, -0.2), Vec2(41, 0.5), Vec2(40.2, 3.4), Vec2(2.8, 2.9), Vec2(3.1, 21), Vec2(-0.4, 19.6)]
    let l = SketchShape(kind: .polyline(rough, closed: true))
    let id = l.id
    var cs: [SketchConstraint] = []
    for i in [0, 2, 4] { cs.append(.init(.horizontal(.segment(id, i)))) }
    for i in [1, 3, 5] { cs.append(.init(.vertical(.segment(id, i)))) }
    cs.append(.init(.fix(.point(id, 0), Vec2(0, 0))))
    cs.append(.init(.length(.segment(id, 0), 40)))       // base
    cs.append(.init(.length(.segment(id, 5), 20)))       // height
    cs.append(.init(.length(.segment(id, 1), 3)))        // base thickness
    cs.append(.init(.length(.segment(id, 4), 3)))        // upright thickness
    var sketch = Sketch(name: "Staffa", shapes: [l], constraints: cs)
    let ok1 = sketch.solve()
    #expect(ok1)
    let s = sketch.shapes[0]
    #expect(near(length(s, 0), 40) && near(length(s, 5), 20) && near(length(s, 1), 3) && near(length(s, 4), 3))
    #expect(near(s.point(0)!.x, 0) && near(s.point(0)!.y, 0) && near(s.point(1)!.y, 0))
    let result = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(result.freedom == 0 && result.fullyConstrained.contains(id))

    // Base 40 → 60: the far end moves, the corner and the other dimensions stay.
    let i = sketch.constraints.firstIndex { if case .length(.segment(_, 0), _) = $0.kind { true } else { false } }!
    sketch.constraints[i].kind = sketch.constraints[i].kind.with(value: 60)
    let ok2 = sketch.solve()
    #expect(ok2)
    let t = sketch.shapes[0]
    #expect(near(length(t, 0), 60) && near(length(t, 5), 20) && near(t.point(1)!.x, 60) && near(t.point(0)!.x, 0))
    // A closed profile still: the extrusion follows (4 sides at right angles, area 60·3 + 3·17).
    #expect(near(abs(t.profile!.area), 60 * 3 + 3 * 17, 1e-6))
}

@Test func underConstrainedSketchMovesAsLittleAsPossible() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(10, 10), width: 30, height: 20))
    let c = SketchShape(kind: .circle(center: Vec2(100, 100), radius: 5))
    var sketch = Sketch(name: "S", shapes: [r, c], constraints: [.init(.length(.segment(r.id, 0), 50))])
    let ok3 = sketch.solve()
    #expect(ok3)
    let s = sketch.shapes[0]
    #expect(near(length(s, 0), 50) && near(length(s, 1), 20, 1e-3))
    #expect(sketch.shapes[1] == c)   // untouched shape, untouched
    let result = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(result.freedom == 3 && !result.fullyConstrained.contains(r.id))
}

@Test func tangentConcentricEqualAndPointOnCircle() {
    let line = SketchShape(kind: .polyline([Vec2(-20, 12), Vec2(20, 11)], closed: false))
    let big = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 9))
    let small = SketchShape(kind: .circle(center: Vec2(0.5, -0.3), radius: 4))
    let other = SketchShape(kind: .circle(center: Vec2(30, 0), radius: 6))
    var sketch = Sketch(name: "S", shapes: [line, big, small, other], constraints: [
        .init(.horizontal(.segment(line.id, 0))),
        .init(.tangent(.segment(line.id, 0), .circle(big.id, 0))),
        .init(.concentric(.circle(small.id, 0), .circle(big.id, 0))),
        .init(.equal(.circle(other.id, 0), .circle(small.id, 0))),
        .init(.radius(.circle(big.id, 0), 10)),
        .init(.pointOnCircle(.point(line.id, 1), .circle(other.id, 0))),
    ])
    let ok4 = sketch.solve()
    #expect(ok4)
    let (a, b) = sketch.shapes[0].segment(0)!
    let bc = sketch.shapes[1].circle(0)!, sc = sketch.shapes[2].circle(0)!, oc = sketch.shapes[3].circle(0)!
    #expect(near(a.y, b.y) && near(abs(a.y - bc.center.y), 10) && near(bc.radius, 10))
    #expect(near(sc.center.x, bc.center.x) && near(sc.center.y, bc.center.y) && near(oc.radius, sc.radius))
    #expect(near(((b.x - oc.center.x) * (b.x - oc.center.x) + (b.y - oc.center.y) * (b.y - oc.center.y)).squareRoot(), oc.radius))
}

@Test func conflictingConstraintsLeaveTheSketchAsItWas() {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 3)], closed: false))
    var sketch = Sketch(name: "S", shapes: [seg], constraints: [
        .init(.horizontal(.segment(seg.id, 0))), .init(.vertical(.segment(seg.id, 0))), .init(.length(.segment(seg.id, 0), 10)),
    ])
    let before = sketch.shapes
    let ok5 = sketch.solve()
    #expect(!ok5)
    #expect(sketch.shapes == before)
}

@Test func dragFollowsTheMouseWithinTheConstraints() {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    var sketch = Sketch(name: "S", shapes: [seg], constraints: [
        .init(.fix(.point(seg.id, 0), Vec2(0, 0))), .init(.horizontal(.segment(seg.id, 0))),
    ])
    // The free end pulled to (25, 8): it slides along the horizontal to x = 25, y stays 0.
    let ok6 = sketch.solve(drag: (.point(seg.id, 1), Vec2(25, 8)))
    #expect(ok6)
    let p = sketch.shapes[0].point(1)!
    #expect(near(p.x, 25, 1e-4) && near(p.y, 0))
    // Unconstrained end of a free segment: exactly under the mouse.
    var free = Sketch(name: "F", shapes: [seg])
    let ok7 = free.solve(drag: (.point(seg.id, 1), Vec2(7, 7)))
    #expect(ok7)
    #expect(near(free.shapes[0].point(1)!.x, 7) && near(free.shapes[0].point(1)!.y, 7) && near(free.shapes[0].point(0)!.x, 0))
}

@Test func constraintsAreSavedAndOldSketchesStillOpen() throws {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let sketch = Sketch(name: "S", shapes: [seg], constraints: [.init(.length(.segment(seg.id, 0), 10), expression: "lato")])
    let doc = CADDocument(sketches: [sketch])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    let old = #"{"id":"0AC686C5-9730-4A6C-B8C3-CF6CDD16C927","name":"Vecchio","plane":{"origin":{"x":0,"y":0,"z":0},"xAxis":{"x":1,"y":0,"z":0},"yAxis":{"x":0,"y":1,"z":0}},"shapes":[],"isVisible":true}"#
    #expect(try JSONDecoder().decode(Sketch.self, from: Data(old.utf8)).constraints.isEmpty)
    // Deleting a shape drops its constraints.
    var s = sketch
    s.shapes = []
    let okS = s.solve()
    #expect(okS && s.constraints.isEmpty)
}

@Test func filletRoundsARectangleCornerIntoAProfile() throws {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    var sketch = Sketch(name: "S", shapes: [r])
    let arcID = try sketch.fillet(r.id, vertex: 2, radius: 5)
    let ok = sketch.solve()
    #expect(ok)
    // One face: the rectangle with the corner cut by a quarter round (tessellated arc).
    let faces = sketch.faces
    #expect(faces.count == 1)
    let quarterLoss = 25 - Double.pi * 25 / 4
    #expect(abs(faces[0].area - (800 - quarterLoss)) < 0.05)
    // The arc is tangent to both sides and carries its radius dimension.
    let arc = sketch.shapes.first { $0.id == arcID }!
    #expect(arc.circle(0)!.radius == 5)
    #expect(sketch.constraints.contains { if case .radius = $0.kind { true } else { false } })
    #expect(sketch.constraints.filter { if case .tangent = $0.kind { true } else { false } }.count == 2)
    // All four corners: still one face, each corner rounded.
    for _ in 0..<3 {
        // Next sharp corner: an inner vertex of any polyline whose sides are perpendicular.
        var found: (UUID, Int)?
        for poly in sketch.shapes {
            guard case let .polyline(p, _) = poly.kind, p.count >= 3 else { continue }
            if let j = (1..<(p.count - 1)).first(where: { j in
                let a = p[j - 1] - p[j], b = p[j + 1] - p[j]
                return abs(a.x * b.x + a.y * b.y) < 1e-9
            }) { found = (poly.id, j); break }
        }
        guard let (id, corner) = found else { break }
        try sketch.fillet(id, vertex: corner, radius: 5)
    }
    let four = sketch.faces
    #expect(four.count == 1 && abs(four[0].area - (800 - 4 * quarterLoss)) < 0.2)
    #expect(throws: SketchEditError.self) { var s = Sketch(name: "T", shapes: [SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 4, height: 4))]); try s.fillet(s.shapes[0].id, vertex: 0, radius: 10) }
}

/// A filleted rectangle stays a rectangle: its sides keep H/V, so changing the radius only moves the
/// tangent points; the constraints of an L drawn as a polyline follow the new numbering.
@Test func filletKeepsTheSidesStraightWhenTheRadiusChanges() throws {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    var sketch = Sketch(name: "S", shapes: [r])
    try sketch.fillet(r.id, vertex: 0, radius: 3)
    let i = sketch.constraints.firstIndex { if case .radius = $0.kind { true } else { false } }!
    sketch.constraints[i].kind = sketch.constraints[i].kind.with(value: 6)
    let ok = sketch.solve(after: sketch.constraints[i].id)
    #expect(ok)
    let poly = sketch.shapes.first { $0.id == r.id }!
    for j in 0..<poly.segmentCount {
        let (a, b) = poly.segment(j)!
        #expect(near(a.x, b.x, 1e-6) || near(a.y, b.y, 1e-6))
    }
    let quarterLoss = 36 - Double.pi * 36 / 4
    #expect(abs(sketch.faces[0].area - (800 - quarterLoss)) < 0.2)

    // Open L with H/V and a length on the far side: the length survives on the second half.
    let l = SketchShape(kind: .polyline([Vec2(0, 20), Vec2(0, 0), Vec2(30, 0), Vec2(30, 10)], closed: false))
    var s2 = Sketch(name: "L", shapes: [l], constraints: [
        .init(.vertical(.segment(l.id, 0))), .init(.horizontal(.segment(l.id, 1))), .init(.vertical(.segment(l.id, 2))),
        .init(.length(.segment(l.id, 2), 10)), .init(.length(.segment(l.id, 1), 30)),
    ])
    try s2.fillet(l.id, vertex: 1, radius: 4)
    #expect(s2.shapes.count == 3)
    #expect(!s2.constraints.contains { if case .length(_, 30) = $0.kind { true } else { false } })   // trimmed side
    let second = s2.shapes.first { $0.id != l.id && $0.circle(0) == nil }!
    #expect(s2.constraints.contains { $0.kind == .length(.segment(second.id, 1), 10) })
    #expect(s2.constraints.contains { $0.kind == .vertical(.segment(second.id, 1)) })
    let ok2 = s2.solve()
    #expect(ok2)
}

@Test func chamferCutsACornerWithALine() throws {
    let r = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 40, height: 20))
    var sketch = Sketch(name: "S", shapes: [r])
    let line = try sketch.chamfer(r.id, vertex: 2, distance: 4)
    let ok = sketch.solve()
    #expect(ok)
    let c = sketch.shapes.first { $0.id == line }!
    #expect(c.pointCount == 2 && (c.point(0)! - c.point(1)!).length > 5.6 && (c.point(0)! - c.point(1)!).length < 5.7)
    #expect(sketch.faces.count == 1 && abs(sketch.faces[0].area - (800 - 8)) < 1e-6)
    #expect(!sketch.constraints.contains { if case .tangent = $0.kind { true } else { false } })
    #expect(throws: SketchEditError.self) { var s = sketch; try s.chamfer(r.id, vertex: 1, distance: 50) }
}
