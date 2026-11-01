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

/// The drag path asks for the solved shapes only: with `diagnosis: false` the DOF/conflict
/// analysis is skipped (it costs the null basis and one rank per shape) and nothing else changes.
@Test func fastSolveSkipsTheDiagnosisButSolvesTheSame() {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let constraints: [SketchConstraint] = [
        .init(.fix(.point(seg.id, 0), Vec2(0, 0))),
        .init(.horizontal(.segment(seg.id, 0))),
    ]
    let drag: (SketchRef, Vec2) = (.point(seg.id, 1), Vec2(25, 8))
    let full = SketchSolver.solve([seg], constraints, drag: drag)
    let fast = SketchSolver.solve([seg], constraints, drag: drag, diagnosis: false)
    #expect(fast.converged && full.converged)
    #expect(fast.shapes == full.shapes)
    #expect(fast.freedom == 0 && fast.freedomPerShape.isEmpty)
    #expect(fast.redundant.isEmpty && fast.conflicting.isEmpty && fast.fullyConstrained.isEmpty)
    #expect(fast.blocking == full.blocking)
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

// MARK: - Diagnostics, branch locking, axes

@Test func constantSignedDistancesKeepTheirSide() {
    // A point above a line pulled to the other side never crosses the line: the sign of the
    // distance is taken once from the geometry, so the dimension reads as a value.
    let line = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let p = SketchShape(kind: .circle(center: Vec2(5, 3), radius: 1))   // centre is point 0
    var sketch = Sketch(name: "S", shapes: [line, p], constraints: [
        .init(.fix(.point(line.id, 0), Vec2(0, 0))), .init(.fix(.point(line.id, 1), Vec2(10, 0))),
        .init(.offset(.point(p.id, 0), .segment(line.id, 0), 3)),
    ])
    let ok = sketch.solve()
    #expect(ok)
    #expect(sketch.shapes[1].point(0)!.y > 0)
    let i = sketch.constraints.firstIndex { if case .offset = $0.kind { true } else { false } }!
    sketch.constraints[i].kind = sketch.constraints[i].kind.with(value: 6)
    let ok2 = sketch.solve()
    #expect(ok2)
    #expect(near(sketch.shapes[1].point(0)!.y, 6) && sketch.shapes[1].point(0)!.y > 0)
}

@Test func horizontalDistanceKeepsTheDirectionOfTheMove() {
    let a = SketchShape(kind: .polyline([Vec2(0, 0)], closed: false))
    let b = SketchShape(kind: .polyline([Vec2(-5, 2)], closed: false))
    var sketch = Sketch(name: "S", shapes: [a, b], constraints: [
        .init(.fix(.point(a.id, 0), Vec2(0, 0))),
        .init(.horizontalDistance(.point(a.id, 0), .point(b.id, 0), 5)),
    ])
    // Already 5 to the left: exact.
    let ok1 = sketch.solve()
    #expect(ok1)
    var r = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(r.converged && near(sketch.shapes[1].point(0)!.x, -5, 1e-6))
    // Shorter: it stays to the left, it does not jump across.
    sketch.constraints[1].kind = sketch.constraints[1].kind.with(value: 2)
    let ok2 = sketch.solve()
    #expect(ok2)
    r = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(r.converged)
    #expect(near(sketch.shapes[1].point(0)!.x, -2, 1e-6))
}

@Test func angleNear180DoesNotFlip() {
    let a = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let b = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10 * cos(170 * .pi / 180), 10 * sin(170 * .pi / 180))], closed: false))
    var sketch = Sketch(name: "S", shapes: [a, b], constraints: [])
    sketch.constraints = [.init(.angle(.segment(a.id, 0), .segment(b.id, 0), 179))]
    let ok = sketch.solve()
    #expect(ok)
    let (p, q) = sketch.shapes[1].segment(0)!
    let (u, v) = sketch.shapes[0].segment(0)!
    let d1 = v - u, d2 = q - p
    let deg = atan2(d1.cross(d2), (d1.x * d2.x + d1.y * d2.y)) * 180 / .pi
    #expect(near(deg, 179, 1e-4))
}

@Test func tangentCircleKeepsInsideOrOutsideBranch() {
    // A small circle inside a big one: the tangency stays internal, it does not jump outside.
    let big = SketchShape(kind: .circle(center: Vec2(0, 0), radius: 10))
    let small = SketchShape(kind: .circle(center: Vec2(6, 0), radius: 4))
    var sketch = Sketch(name: "S", shapes: [big, small], constraints: [
        .init(.fix(.point(big.id, 0), Vec2(0, 0))), .init(.radius(.circle(big.id, 0), 10)),
        .init(.tangent(.circle(big.id, 0), .circle(small.id, 0))),
    ])
    let ok1 = sketch.solve()
    #expect(ok1)
    let d = (sketch.shapes[1].circle(0)!.center - sketch.shapes[0].circle(0)!.center).length
    #expect(near(d, 6, 1e-6))   // 10 − 4, still internal
    // Change the small radius: still internal tangency.
    sketch.constraints.append(.init(.radius(.circle(small.id, 0), 2)))
    let ok2 = sketch.solve()
    #expect(ok2)
    let d2 = (sketch.shapes[1].circle(0)!.center - sketch.shapes[0].circle(0)!.center).length
    #expect(near(d2, 8, 1e-6))
}

@Test func redundantAndConflictingConstraintsAreReported() {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0.2)], closed: false))
    let h1 = SketchConstraint(.horizontal(.segment(seg.id, 0)))
    let h2 = SketchConstraint(.horizontal(.segment(seg.id, 0)))
    let ok = SketchSolver.solve([seg], [h1, h2])
    #expect(ok.converged)
    #expect(ok.redundant == [h2.id])
    #expect(ok.conflicting.isEmpty)

    let v = SketchConstraint(.vertical(.segment(seg.id, 0)))
    let bad = SketchSolver.solve([seg], [h1, v, .init(.length(.segment(seg.id, 0), 10))])
    #expect(!bad.converged)
    #expect(!bad.conflicting.isEmpty)
    let diag = SketchSolver.diagnose([seg], [h1, v, .init(.length(.segment(seg.id, 0), 10))])
    #expect(!diag.converged)   // horizontal, vertical and 10 mm cannot hold together
}

@Test func overConstrainedAddIsRejectedAndReferenceDoesNotDrive() {
    let seg = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let h = SketchConstraint(.horizontal(.segment(seg.id, 0)))
    #expect(SketchSolver.check([seg], [h], adding: .init(.horizontal(.segment(seg.id, 0)))) == .redundant)
    #expect(SketchSolver.check([seg], [h], adding: .init(.length(.segment(seg.id, 0), 12))) == .ok)
    #expect(SketchSolver.check([seg], [h, .init(.length(.segment(seg.id, 0), 10))],
                               adding: .init(.vertical(.segment(seg.id, 0)))) == .infeasible)

    // A reference dimension is measured, not solved: the sketch does not move.
    let before = seg
    let ref = SketchConstraint(.length(.segment(seg.id, 0), 99), isReference: true)
    let r = SketchSolver.solve([seg], [ref])
    #expect(r.converged && r.shapes[0] == before)
    #expect(SketchSolver.residual(ref.kind, [seg.id: seg]).first! .isFinite)
}

@Test func freedomIsReportedPerShapeAndAxesAreFixedGeometry() {
    let r = SketchShape(kind: .rectangle(corner: Vec2(10, 10), width: 30, height: 20))
    let base = SketchConstraint(.length(.segment(r.id, 0), 50))
    let result = SketchSolver.solve([r], [base])
    #expect(result.converged && result.freedomPerShape[r.id] == 3)   // width pinned, corner and height free

    // A point joined to the origin and to the X axis stops moving.
    let seg = SketchShape(kind: .polyline([Vec2(0.4, 0.3), Vec2(10, 2)], closed: false))
    let pinned = SketchConstraint(.coincident(.point(seg.id, 0), .origin))
    let onAxis = SketchConstraint(.pointOnLine(.point(seg.id, 1), .axisX))
    var sketch = Sketch(name: "S", shapes: [seg], constraints: [pinned, onAxis])
    let ok = sketch.solve()
    #expect(ok)
    #expect(near(sketch.shapes[0].point(0)!.x, 0) && near(sketch.shapes[0].point(0)!.y, 0))
    #expect(near(sketch.shapes[0].point(1)!.y, 0))
    // The origin and the axes survive the re-solve instead of being dropped as deleted shapes.
    #expect(sketch.constraints.count == 2)
}

@Test func colinearSmoothAndPointOnArc() {
    let l1 = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let l2 = SketchShape(kind: .polyline([Vec2(10, 0), Vec2(20, 0.5)], closed: false))
    let arc = SketchShape(kind: .arc(center: Vec2(10, 0), radius: 5, start: 0, end: .pi))
    let point = SketchShape(kind: .polyline([Vec2(20, 2)], closed: false))
    let got = SketchSolver.solve([l1, l2, arc, point], [
        .init(.colinear(.segment(l1.id, 0), .segment(l2.id, 0))),
        .init(.smooth(.segment(l1.id, 0), .segment(l2.id, 0))),
        .init(.pointOnArc(.point(point.id, 0), .circle(arc.id, 0))),
    ])
    #expect(got.converged)
    let d = got.shapes[3].point(0)! - got.shapes[2].circle(0)!.center
    #expect(near(d.length, got.shapes[2].circle(0)!.radius, 1e-6))
}

// MARK: - Origin and axes as constraint references (T122)

@Test func lineParallelToAxisAndPointOnTheOtherAxis() {
    let line = SketchShape(kind: .polyline([Vec2(-5, 3), Vec2(12, 6)], closed: false))
    let p = SketchShape(kind: .polyline([Vec2(7, 2)], closed: false))
    var sketch = Sketch(name: "Assi", shapes: [line, p], constraints: [
        .init(.parallel(.axisX, .segment(line.id, 0))),
        .init(.pointOnLine(.point(p.id, 0), .axisY)),
    ])
    let ok = sketch.solve()
    #expect(ok)
    let (u, v) = sketch.shapes[0].segment(0)!
    #expect(near(u.y, v.y))
    #expect(near(sketch.shapes[1].point(0)!.x, 0))
    let result = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(result.conflicting.isEmpty && result.redundant.isEmpty)
}

@Test func pointCoincidentWithOriginAndSignedDistanceToAxis() {
    let a = SketchShape(kind: .polyline([Vec2(4, -3)], closed: false))
    let b = SketchShape(kind: .polyline([Vec2(1, -3)], closed: false))
    var sketch = Sketch(name: "Origine", shapes: [a, b], constraints: [
        .init(.coincident(.point(a.id, 0), .origin)),
        .init(.distance(.point(b.id, 0), .axisX, 8)),
    ])
    let ok = sketch.solve()
    #expect(ok)
    #expect(near(sketch.shapes[0].point(0)!.x, 0) && near(sketch.shapes[0].point(0)!.y, 0))
    // The signed distance keeps the side the point was on (below the axis, −8 mm).
    #expect(near(sketch.shapes[1].point(0)!.y, -8))
}

@Test func axisConstraintIsAcceptedByCheck() {
    let line = SketchShape(kind: .polyline([Vec2(0, 5), Vec2(10, 5)], closed: false))
    let axis = SketchConstraint(.parallel(.axisX, .segment(line.id, 0)))
    if case .ok = SketchSolver.check([line], [], adding: axis) { } else {
        Issue.record("parallel to the X axis should be accepted")
    }
}

// MARK: - A rectangle is four lines for constraints and fillets (T122)

@Test func rectangleSidesTakeConstraintsAndCornersFillet() {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 20, height: 10))
    var sketch = Sketch(name: "Rect", shapes: [rect], constraints: [])
    // Four pickable sides and four corners, plus the centre.
    #expect(rect.segmentCount == 4 && rect.pointCount == 5)
    #expect(rect.segment(0)?.1 == Vec2(20, 0))
    // A dimension drives one side only (the bottom one), like a line entity.
    sketch.constraints.append(.init(.length(.segment(rect.id, 0), 24)))
    let ok = sketch.solve()
    #expect(ok)
    #expect(near(sketch.shapes[0].point(1)!.x, 24))
    // A corner fillet turns the rectangle into its outline with an arc, still four sides numbered alike.
    let freedomBefore = SketchSolver.solve(sketch.shapes, sketch.constraints).freedom
    do { _ = try sketch.fillet(rect.id, vertex: 2, radius: 3) } catch { Issue.record("fillet: \(error)") }
    let filleted = sketch.solve()
    #expect(filleted)
    #expect(sketch.shapes.count == 2)
    let kind = sketch.shapes[0].kind
    if case let .polyline(p, closed) = kind { #expect(!closed && p.count == 5) } else { Issue.record("not exploded: \(kind)") }
    // The rounded corner takes away no freedom, and nothing has become redundant.
    let freedomAfter = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(freedomAfter.freedom == freedomBefore && freedomAfter.redundant.isEmpty)
}

@Test func rectangleCornerCoincidesWithTheOrigin() {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(10, 10), width: 9, height: 7))
    var sketch = Sketch(name: "Rect", shapes: [rect], constraints: [
        .init(.coincident(.point(rect.id, 0), .origin)),
    ])
    let ok = sketch.solve()
    #expect(ok)
    #expect(near(sketch.shapes[0].point(0)!.x, 0) && near(sketch.shapes[0].point(0)!.y, 0))
    // Only the corner asked for moved: the rectangle keeps its 9 x 7 size.
    #expect(near(length(sketch.shapes[0], 0), 9) && near(length(sketch.shapes[0], 1), 7))
}

@Test func shapesAlreadyOwnTheirInternalRelations() {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(3, 4), width: 10, height: 6))
    for candidate in [
        SketchConstraint(.parallel(.segment(rect.id, 0), .segment(rect.id, 2))),
        SketchConstraint(.perpendicular(.segment(rect.id, 0), .segment(rect.id, 1))),
        SketchConstraint(.equal(.segment(rect.id, 0), .segment(rect.id, 2))),
        SketchConstraint(.horizontal(.segment(rect.id, 0))),
        SketchConstraint(.vertical(.segment(rect.id, 1))),
    ] {
        #expect(SketchSolver.check([rect], [], adding: candidate) == .redundant)
    }
    // A regular polygon's sides are already equal.
    let poly = SketchShape(kind: .polygon(center: Vec2(0, 0), radius: 8, sides: 6, rotation: 0, circumscribed: false))
    let equalSides = SketchConstraint(.equal(.segment(poly.id, 0), .segment(poly.id, 1)))
    #expect(SketchSolver.check([poly], [], adding: equalSides) == .redundant)
}

@Test func rectangleKeepsItsTwoSizesAfterACornerIsFixed() {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(12, 9), width: 9, height: 7))
    var sketch = Sketch(name: "Rect", shapes: [rect], constraints: [.init(.coincident(.point(rect.id, 0), .origin))])
    let ok = sketch.solve()
    #expect(ok)
    // A rectangle is corner + width + height: fixing the corner leaves two freedoms, the sizes.
    let result = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(result.freedom == 2 && (result.freedomPerShape[rect.id] ?? -1) == 2)
    // Two dimensions on the sides define it completely, as in Fusion.
    sketch.constraints.append(.init(.length(.segment(rect.id, 0), 9)))
    sketch.constraints.append(.init(.length(.segment(rect.id, 1), 7)))
    let ok2 = sketch.solve()
    #expect(ok2)
    let done = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(done.freedom == 0 && done.fullyConstrained.contains(rect.id))
}

@Test func rectangleAsFourConstrainedLinesHasFourFreedoms() {
    var sketch = Sketch(name: "Rect")
    let lines = sketch.addRectangle(corner: Vec2(0, 0), width: 10, height: 6)
    #expect(lines.count == 4 && sketch.shapes.count == 4)
    // Four H/V relations and four corner coincidences: 12 equations on 16 parameters.
    #expect(sketch.constraints.count == 8)
    let drawn = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(drawn.freedom == 4)
    // Pinning a corner to the origin leaves the two sizes, as a rectangle shape does.
    sketch.constraints.append(.init(.coincident(.point(lines[0], 0), .origin)))
    let ok = sketch.solve()
    #expect(ok)
    let pinned = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(pinned.freedom == 2)
    // The sides stay joined and keep the sizes they were drawn with.
    for i in 0..<4 {
        guard let line = sketch.shapes.first(where: { $0.id == lines[i] }),
              let nextLine = sketch.shapes.first(where: { $0.id == lines[(i + 1) % 4] }),
              let end = line.point(1), let start = nextLine.point(0) else { continue }
        #expect(near(end.x, start.x, 1e-5) && near(end.y, start.y, 1e-5))
    }
    #expect(near(length(sketch.shapes[0], 0), 10) && near(length(sketch.shapes[1], 0), 6))
}

@Test func crossLineFilletTrimsBothLinesAndAddsATangentArc() throws {
    let a = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let b = SketchShape(kind: .polyline([Vec2(10, 0), Vec2(10, 10)], closed: false))
    var sketch = Sketch(name: "Corner", shapes: [a, b], constraints: [
        .init(.coincident(.point(a.id, 1), .point(b.id, 0))),
    ])
    let before = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(before.freedom == 6)
    let arcID = try sketch.fillet(a.id, vertex: 1, b.id, vertex: 0, radius: 2)
    let ok = sketch.solve()
    #expect(ok)
    // Both lines end 2 mm from the old corner, joined by a 2 mm radius arc centred at (8, 2).
    guard let lineA = sketch.shapes.first(where: { $0.id == a.id }),
          let lineB = sketch.shapes.first(where: { $0.id == b.id }),
          let arc = sketch.shapes.first(where: { $0.id == arcID }),
          let t1 = lineA.point(1), let t2 = lineB.point(0),
          let circle = arc.circle(0) else {
        Issue.record("missing fillet pieces")
        return
    }
    #expect(near(t1.x, 8, 1e-5) && near(t1.y, 0, 1e-5))
    #expect(near(t2.x, 10, 1e-5) && near(t2.y, 2, 1e-5))
    #expect(near(circle.center.x, 8, 1e-5) && near(circle.center.y, 2, 1e-5) && near(circle.radius, 2))
    // The relation that joined the old corner is gone, and both trimmed lines stay tangent to
    // the arc.
    func distance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let d = b - a
        return abs(d.cross(p - a)) / (d.x * d.x + d.y * d.y).squareRoot()
    }
    #expect(near(distance(circle.center, lineA.point(0)!, t1), 2, 1e-5))
    #expect(near(distance(circle.center, t2, lineB.point(1)!), 2, 1e-5))
    // The fillet adds no freedom: tangency is written at the arc's end point, whose row does not
    // vanish at the touch point (with the distance form it did, and two freedoms appeared).
    let after = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(before.freedom == 6 && after.freedom == 6)
    #expect(after.redundant.isEmpty)
}

@Test func reopeningAFilletRewritesItsTangencyToTheArcEnd() throws {
    let a = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(10, 0)], closed: false))
    let b = SketchShape(kind: .polyline([Vec2(10, 0), Vec2(10, 10)], closed: false))
    var sketch = Sketch(name: "Corner", shapes: [a, b], constraints: [
        .init(.coincident(.point(a.id, 1), .point(b.id, 0))),
    ])
    let arcID = try sketch.fillet(a.id, vertex: 1, b.id, vertex: 0, radius: 2)
    // Save the tangency in the old wording (side · circle of the arc), as earlier documents did.
    for k in sketch.constraints.indices {
        if case let .tangent(side, .point(id, _)) = sketch.constraints[k].kind, id == arcID {
            sketch.constraints[k].kind = .tangent(side, .circle(id, 0))
        }
    }
    let reopened = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(sketch))
    #expect(reopened.constraints.contains { c in
        if case let .tangent(_, .point(id, _)) = c.kind { id == arcID } else { false }
    })
    // And the reopened fillet still reports the six freedoms of two lines joined at a corner.
    #expect(SketchSolver.solve(reopened.shapes, reopened.constraints).freedom == 6)
}

/// A background analysis stops a long solve: the result is non-converged and the sketch is
/// returned exactly as it came in, so a stale analysis can never move anything.
@Test func aCancelledSolveLeavesShapesAndConstraintsUntouched() {
    let line = SketchShape(kind: .polyline([Vec2(0, 0), Vec2(40, 5)], closed: false))
    var sketch = Sketch(name: "S", shapes: [line], constraints: [.init(.horizontal(.segment(line.id, 0)))])
    let solved = sketch.solve()
    #expect(solved)
    let r = SketchSolver.solve(sketch.shapes, sketch.constraints, isCancelled: { true })
    #expect(!r.converged)
    #expect(r.shapes == sketch.shapes)
    #expect(r.constraints == sketch.constraints)
}

/// Ten fully constrained lines that share nothing: ten independent clusters, large enough to be
/// solved at the same time. The aggregated result must be the same, in the same order, every time
/// and equal to what each line gives when it is solved alone.
@Test func independentClustersAreSolvedTogetherAndAggregatedInOrder() {
    let (shapes, constraints) = tenIndependentLines()
    let sketch = Sketch(name: "Dieci linee", shapes: shapes, constraints: constraints)
    let r = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(r.converged)
    #expect(r.freedom == 0)
    #expect(r.fullyConstrained == Set(shapes.map(\.id)))

    let again = SketchSolver.solve(sketch.shapes, sketch.constraints)
    #expect(again.converged == r.converged && again.freedom == r.freedom && again.error == r.error)
    #expect(again.shapes.map(\.parameters) == r.shapes.map(\.parameters))
    #expect(again.redundant == r.redundant && again.conflicting == r.conflicting)

    for line in shapes {
        let own = constraints.filter { c in c.kind.refs.contains { $0.shapeID == line.id } }
        let alone = SketchSolver.solve([line], own)
        let together = r.shapes.first { $0.id == line.id }!
        #expect(alone.converged)
        #expect(alone.freedomPerShape[line.id] == 0)
        for (a, b) in zip(alone.shapes[0].parameters, together.parameters) { #expect(near(a, b)) }
    }
}

/// The same many-cluster sketch, cancelled while the clusters are being solved: no cluster may
/// land half-solved, so the whole result is discarded and the sketch comes back untouched.
@Test func aCancelledParallelSolveLeavesEveryClusterUntouched() {
    let (shapes, constraints) = tenIndependentLines()
    let r = SketchSolver.solve(shapes, constraints, isCancelled: { true })
    #expect(!r.converged)
    #expect(r.shapes == shapes)
    #expect(r.constraints == constraints)
}

private func tenIndependentLines() -> (shapes: [SketchShape], constraints: [SketchConstraint]) {
    var shapes: [SketchShape] = []
    var constraints: [SketchConstraint] = []
    for i in 0..<10 {
        let x = Double(i) * 20
        let line = SketchShape(kind: .polyline([Vec2(x, 0), Vec2(x + 15, 3)], closed: false))
        shapes.append(line)
        constraints.append(.init(.fix(.point(line.id, 0), Vec2(x, 0))))
        constraints.append(.init(.horizontal(.segment(line.id, 0))))
        constraints.append(.init(.length(.segment(line.id, 0), 10)))
    }
    return (shapes, constraints)
}

// MARK: - All the corners of a rectangle or a polygon

@Test func filletAllCornersRoundsEveryCornerOfARectangle() throws {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 20, height: 10))
    var sketch = Sketch(name: "S", shapes: [rect])
    let arcs = try sketch.filletAllCorners(rect.id, radius: 2)
    #expect(arcs.count == 4)
    #expect(sketch.shapes.count == 8)   // four sides and four arcs
    let solved = sketch.solve()
    #expect(solved)
    let round = sketch.shapes.compactMap { $0.circle(0) }
    #expect(round.count == 4)
    for c in round { #expect(near(c.radius, 2, 1e-6)) }
    #expect(sketch.faces.count == 1)
    let quarterLoss = 4 - Double.pi * 4 / 4
    #expect(abs(sketch.faces[0].area - (200 - 4 * quarterLoss)) < 0.2)
}

@Test func chamferAllCornersCutsEveryCornerOfARectangle() throws {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 20, height: 10))
    var sketch = Sketch(name: "S", shapes: [rect])
    let cuts = try sketch.chamferAllCorners(rect.id, distance: 2)
    #expect(cuts.count == 4)
    #expect(sketch.shapes.count == 8)   // four sides and four chamfer lines
    let solved = sketch.solve()
    #expect(solved)
    for id in cuts {
        let line = sketch.shapes.first { $0.id == id }!
        #expect(line.pointCount == 2 && near((line.point(0)! - line.point(1)!).length, 2 * 2.0.squareRoot()))
    }
    #expect(sketch.faces.count == 1)
    #expect(abs(sketch.faces[0].area - 192) < 1e-6)   // 200 - 4 triangles of 2 × 2 / 2
}

@Test func filletAllCornersRoundsEveryVertexOfAPolygon() throws {
    let hex = SketchShape(kind: .polygon(center: Vec2(0, 0), radius: 5, sides: 6, rotation: 0, circumscribed: false))
    var sketch = Sketch(name: "S", shapes: [hex])
    let arcs = try sketch.filletAllCorners(hex.id, radius: 1)
    #expect(arcs.count == 6)
    #expect(sketch.shapes.count == 12)   // six sides and six arcs
    let solved = sketch.solve()
    #expect(solved)
    let round = sketch.shapes.compactMap { $0.circle(0) }
    #expect(round.count == 6)
    for c in round { #expect(near(c.radius, 1, 1e-6)) }
    #expect(sketch.faces.count == 1)
}

@Test func filletAllCornersLeavesTheSketchAsItWasWhenTheRadiusIsTooBig() {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 10, height: 6))
    var sketch = Sketch(name: "S", shapes: [rect])
    do {
        _ = try sketch.filletAllCorners(rect.id, radius: 10)
        Issue.record("a radius larger than the sides should throw")
    } catch is SketchEditError {
        // Expected: nothing of the failed operation may stay in the sketch.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(sketch.shapes.count == 1)
    if case let .rectangle(corner, width, height) = sketch.shapes[0].kind {
        #expect(corner == Vec2(0, 0) && width == 10 && height == 6)
    } else {
        Issue.record("the rectangle was modified")
    }
}

@Test func filletAllCornersKeepsTheConstraintsOfTheCornersOnTheNewLines() throws {
    let rect = SketchShape(kind: .rectangle(corner: Vec2(0, 0), width: 20, height: 10))
    var sketch = Sketch(name: "S", shapes: [rect], constraints: [
        .init(.fix(.point(rect.id, 1), Vec2(20, 0))),
    ])
    _ = try sketch.filletAllCorners(rect.id, radius: 2)
    // The fixed corner is now an end of one of the sides, not a lost constraint.
    #expect(sketch.constraints.contains { c in
        if case let .fix(.point(id, _), p) = c.kind {
            return p == Vec2(20, 0) && sketch.shapes.contains { $0.id == id }
        }
        return false
    })
    #expect(sketch.faces.count == 1)
}
