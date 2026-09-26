import Foundation
import Testing
@testable import CADCore

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> (points: [Vec2], closed: Bool) {
    ([Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)], true)
}
private func circle(_ cx: Double, _ cy: Double, _ r: Double) -> (points: [Vec2], closed: Bool) {
    (Profile2D.circle(radius: r, center: Vec2(cx, cy)).points, true)
}
private func areas(_ faces: [SketchFace]) -> [Double] { faces.map(\.area).sorted() }
private func near(_ a: [Double], _ b: [Double], _ tol: Double = 1e-6) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < tol } }

@Test func overlappingRectanglesMakeThreeFaces() {
    let faces = SketchArrangement.faces([rect(0, 0, 20, 10), rect(10, 5, 20, 10)])
    #expect(near(areas(faces), [50, 150, 150]))
}

@Test func nestedCirclesMakePlateRingAndDisc() {
    let big = circle(0, 0, 30), small = circle(0, 0, 10)
    let faces = SketchArrangement.faces([rect(-50, -50, 100, 100), big, small])
    let ring = Profile2D(points: big.points).area - Profile2D(points: small.points).area
    #expect(near(areas(faces), [Profile2D(points: small.points).area, ring, 10_000 - Profile2D(points: big.points).area]))
    #expect(faces.first { abs($0.area - ring) < 1e-6 }?.holes.count == 1)
    // Seeds pick faces; ring + disc merge into the full disc.
    let curves = [rect(-50, -50, 100, 100), big, small]
    let merged = SketchArrangement.merged(faces, seeds: [Vec2(20, 0), Vec2(0, 0)], curves: curves)
    #expect(merged.count == 1 && merged[0].holes.isEmpty && abs(merged[0].area - Profile2D(points: big.points).area) < 1e-6)
    let plate = SketchArrangement.merged(faces, seeds: [Vec2(45, 45)], curves: curves)
    #expect(plate.count == 1 && plate[0].holes.count == 1)
}

@Test func lineAcrossCircleSplitsIt() {
    let c = circle(0, 0, 10)
    let faces = SketchArrangement.faces([c, ([Vec2(-20, 0), Vec2(20, 0)], false)])
    let half = Profile2D(points: c.points).area / 2
    #expect(near(areas(faces), [half, half], 1e-6))
}

@Test func openLinesClosingOnEachOtherMakeAFace() {
    let faces = SketchArrangement.faces([([Vec2(0, 0), Vec2(10, 0)], false), ([Vec2(10, 0), Vec2(0, 10)], false), ([Vec2(0, 10), Vec2(0, 0)], false),
                                         ([Vec2(3, 3), Vec2(5, 2)], false)])   // a loose line inside changes nothing
    #expect(near(areas(faces), [50]))
    let seedInside = faces[0].seed
    #expect(SketchArrangement.Graph.inside(seedInside, faces[0].outline))
}
