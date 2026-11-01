import Foundation
import Testing
@testable import CADCore

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

private let curve = SketchShape(kind: .bezier(start: Vec2(0, 0), control1: Vec2(2, 10),
                                              control2: Vec2(8, 10), end: Vec2(10, 0)))

/// Parameters, named points and sampling of a cubic Bezier.
@Test func bezierParametersAndSampling() {
    #expect(curve.parameters == [0, 0, 2, 10, 8, 10, 10, 0])
    #expect(curve.pointCount == 4)
    #expect(curve.segmentCount == 0)
    #expect(curve.point(0) == Vec2(0, 0))
    #expect(curve.point(1) == Vec2(2, 10))
    #expect(curve.point(2) == Vec2(8, 10))
    #expect(curve.point(3) == Vec2(10, 0))
    #expect(curve.point(4) == nil)
    #expect(!curve.isClosed)
    #expect(curve.profile == nil)
    #expect(curve.outline.count == SketchShape.bezierSegments + 1)
    #expect(curve.outline.first == Vec2(0, 0))
    #expect(curve.outline.last == Vec2(10, 0))
    #expect(SketchShape.bezier(0.5, start: Vec2(0, 0), control1: Vec2(2, 10),
                               control2: Vec2(8, 10), end: Vec2(10, 0)) == Vec2(5, 7.5))
    #expect(curve.prims.count == SketchShape.bezierSegments)
    #expect(curve.with(parameters: curve.parameters).kind == curve.kind)
}

/// The nearest-point parameter: 0 at the start, 1 at the end, and only for curves.
@Test func bezierParameterSearch() {
    #expect(curve.bezierParameter(nearest: Vec2(-1, 0)).map { near($0, 0, 0.02) } == true)
    #expect(curve.bezierParameter(nearest: Vec2(11, 0)).map { near($0, 1, 0.02) } == true)
    let mid = SketchShape.bezier(0.5, start: Vec2(0, 0), control1: Vec2(2, 10),
                                 control2: Vec2(8, 10), end: Vec2(10, 0))
    #expect(curve.bezierParameter(nearest: mid).map { near($0, 0.5, 0.02) } == true)
    #expect(SketchShape(kind: .circle(center: Vec2(0, 0), radius: 5)).bezierParameter(nearest: Vec2(0, 0)) == nil)
}

/// A point constrained on the curve lands on it, and the solve reports the curve parameter.
@Test func pointOnBezierMovesThePointOntoTheCurve() {
    let point = SketchShape(kind: .polyline([Vec2(5, 20)], closed: false))
    let ref = SketchRef.circle(curve.id, 0)
    let constraint = SketchConstraint(.pointOnBezier(.point(point.id, 0), ref, t: 0.5))
    let result = SketchSolver.solve([curve, point], [constraint])
    #expect(result.converged)
    let solvedPoint = result.shapes.first { $0.id == point.id }!
    let solvedCurve = result.shapes.first { $0.id == curve.id }!
    let q = solvedPoint.point(0)!
    let solved = result.constraints[0].kind
    guard case let .pointOnBezier(_, _, t) = solved else { Issue.record("vincolo perso"); return }
    guard case let .bezier(p0, c1, c2, p3) = solvedCurve.kind else { Issue.record("curva persa"); return }
    let onCurve = SketchShape.bezier(t, start: p0, control1: c1, control2: c2, end: p3)
    #expect((q - onCurve).length < 1e-6)
    #expect((0...1).contains(t))
    // 8 curve parameters + 2 point parameters + 1 curve parameter: two rows, so nine freedoms.
    #expect(result.freedom == 9)
}

/// A line end constrained to the curve with tangency: it lands there and runs along it.
@Test func lineTangentToBezier() {
    let line = SketchShape(kind: .polyline([Vec2(-4, 8), Vec2(4, 8)], closed: false))
    let ref = SketchRef.circle(curve.id, 0)
    let constraint = SketchConstraint(.bezierLineTangent(.point(line.id, 1), .segment(line.id, 0), ref, t: 0.5))
    let result = SketchSolver.solve([curve, line], [constraint])
    #expect(result.converged)
    let solvedLine = result.shapes.first { $0.id == line.id }!
    let solvedCurve = result.shapes.first { $0.id == curve.id }!
    guard case let .bezier(p0, c1, c2, p3) = solvedCurve.kind,
          case let .bezierLineTangent(_, _, _, t) = result.constraints[0].kind else {
        Issue.record("forma o parametro persi")
        return
    }
    let end = solvedLine.point(1)!
    let onCurve = SketchShape.bezier(t, start: p0, control1: c1, control2: c2, end: p3)
    let tangent = SketchShape.bezierTangent(t, start: p0, control1: c1, control2: c2, end: p3)
    let direction = end - solvedLine.point(0)!
    let sine = direction.cross(tangent) / (direction.length * tangent.length)
    #expect((end - onCurve).length < 1e-6)
    #expect(abs(sine) < 1e-6)
    // 8 curve + 4 line + 1 curve parameter: three rows, ten freedoms left.
    #expect(result.freedom == 10)
}

/// `Sketch.solve` writes the solved curve parameter back into the constraint.
@Test func sketchSolveStoresTheCurveParameter() {
    let point = SketchShape(kind: .polyline([Vec2(10, 10)], closed: false))
    var sketch = Sketch(name: "Bezier", shapes: [curve, point],
                        constraints: [.init(.pointOnBezier(.point(point.id, 0), .circle(curve.id, 0), t: 0.5))])
    let solved = sketch.solve()
    #expect(solved)
    guard case let .pointOnBezier(_, _, t) = sketch.constraints[0].kind else { Issue.record("vincolo perso"); return }
    let solvedPoint = sketch.shapes.first { $0.id == point.id }!.point(0)!
    guard case let .bezier(p0, c1, c2, p3) = sketch.shapes.first(where: { $0.id == curve.id })!.kind else {
        Issue.record("curva persa")
        return
    }
    #expect((solvedPoint - SketchShape.bezier(t, start: p0, control1: c1, control2: c2, end: p3)).length < 1e-6)
}

/// The curve survives a JSON round trip (with the constraint and its parameter).
@Test func bezierCodableRoundTrip() throws {
    let point = SketchShape(kind: .polyline([Vec2(1, 1)], closed: false))
    let sketch = Sketch(name: "Bezier", shapes: [curve, point],
                        constraints: [.init(.bezierLinePerpendicular(.point(point.id, 0), .segment(point.id, 0),
                                                                     .circle(curve.id, 0), t: 0.25))])
    let data = try JSONEncoder().encode(sketch)
    let back = try JSONDecoder().decode(Sketch.self, from: data)
    #expect(back == sketch)
}
