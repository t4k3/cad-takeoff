import Foundation
import Testing
@testable import CADCore

private let cube = Feature(name: "Cubo", kind: .box(width: 10, depth: 10, height: 10), position: Vec3(10, 0, 0))

private func run(_ spec: PatternSpec, extra: [Feature] = []) -> ([DesignEvaluator.Body], [DesignEvaluator.Issue]) {
    DesignEvaluator.evaluate(CADDocument(features: [cube] + extra + [Feature(name: "Serie", kind: .pattern(spec))]), revision: "r")
}

@Test func rectangularAndCircularPatterns() {
    let (grid, i1) = run(PatternSpec(body: cube.id, kind: .rectangular, countX: 3, spacingX: 20, countY: 2, spacingY: 25))
    #expect(i1.isEmpty && grid.count == 2 && abs(grid[1].mesh.volume - 5000) < 1e-9)
    #expect(MeshValidator.validate(grid[1].mesh).isWatertight && abs(grid[1].mesh.bounds!.max.x - 55) < 1e-9 && abs(grid[1].mesh.bounds!.max.y - 30) < 1e-9)
    // Axis 30 mm from the cube's centre: the six copies do not touch.
    let (ring, i2) = run(PatternSpec(body: cube.id, kind: .circular, count: 6, angle: 360, center: Vec3(-20, 0, 0)))
    #expect(i2.isEmpty && abs(ring[1].mesh.volume - 5000) < 1e-9)
    // The copy at 180° sits on the other side of the axis.
    #expect(abs(ring[1].mesh.bounds!.min.x + 55) < 1e-9)
}

@Test func mirrorKeepsSolidsOutwardAndCanJoin() {
    let (m, issues) = run(PatternSpec(body: cube.id, kind: .mirror, plane: .yz, offset: 0))
    #expect(issues.isEmpty && m.count == 2 && abs(m[1].mesh.volume - 1000) < 1e-9)     // positive: not inside-out
    #expect(MeshValidator.validate(m[1].mesh).isWatertight && abs(m[1].mesh.bounds!.max.x + 5) < 1e-9)
    // Mirror about the cube's own face (x = 5), joined: one body of 2000 mm³.
    let (j, _) = run(PatternSpec(body: cube.id, kind: .mirror, plane: .yz, offset: 5, join: true))
    #expect(j.count == 1 && abs(j[0].mesh.volume - 2000) < 1e-6 && MeshValidator.validate(j[0].mesh).isWatertight)
}

@Test func overlappingCopiesAreUnitedAndMissingSourceReported() {
    let (dense, _) = run(PatternSpec(body: cube.id, kind: .rectangular, countX: 3, spacingX: 5))
    // Copies at +5 and +10 overlap each other: 15 mm long block, not 2 × 1000.
    #expect(dense.count == 2 && abs(dense[1].mesh.volume - 1500) < 1e-6 && MeshValidator.validate(dense[1].mesh).isWatertight)
    let (_, issues) = run(PatternSpec(body: UUID(), kind: .mirror))
    #expect(issues.contains { $0.message.contains("non esiste") })
    let saved = CADDocument(features: [cube, Feature(name: "S", kind: .pattern(PatternSpec(body: cube.id, kind: .circular, count: 4, angle: 90)))])
    #expect(try! CADDocument.decode(saved.encoded()) == saved)
}
