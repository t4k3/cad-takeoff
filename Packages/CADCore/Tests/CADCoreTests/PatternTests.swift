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

// MARK: Split

@Test func splitWithAPlane() {
    let block = Feature(name: "Blocco", kind: .box(width: 40, depth: 30, height: 20))
    func split(_ spec: SplitSpec, _ extra: [Feature] = []) -> ([DesignEvaluator.Body], [DesignEvaluator.Issue]) {
        DesignEvaluator.evaluate(CADDocument(features: [block] + extra + [Feature(name: "Dividi", kind: .split(spec))]), revision: "r")
    }
    let (both, i1) = split(SplitSpec(body: block.id, plane: .xy, offset: 8))
    #expect(i1.isEmpty && both.count == 2)
    #expect(abs(both[0].mesh.volume - 40 * 30 * 8) < 1e-6 && abs(both[1].mesh.volume - 40 * 30 * 12) < 1e-6)
    #expect(both.allSatisfy { MeshValidator.validate($0.mesh).isWatertight })
    let (top, _) = split(SplitSpec(body: block.id, plane: .yz, offset: 5, keep: .positive))
    #expect(top.count == 1 && abs(top[0].mesh.volume - 15 * 30 * 20) < 1e-6)
    let (_, outside) = split(SplitSpec(body: block.id, plane: .xy, offset: 50))
    #expect(outside.contains { $0.message.contains("non attraversa") })
    // A drilled block splits through the hole: both halves stay closed.
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 20)], fit: .manual, diameter: 8)), operation: .cut)
    let (drilled, i4) = split(SplitSpec(body: block.id, plane: .xz, offset: 0), [hole])
    #expect(i4.isEmpty && drilled.count == 2 && drilled.allSatisfy { MeshValidator.validate($0.mesh).isWatertight })
}

/// A pattern of a feature repeats its operation: a row of holes, a ring of cuts, a mirrored cut.
@Test func patternsOfFeaturesRepeatTheirOperation() throws {
    let plate = Feature(name: "Piastra", kind: .box(width: 100, depth: 40, height: 6))
    let base = DesignEvaluator.evaluate(CADDocument(features: [plate]), revision: "p").bodies[0].mesh.volume
    // One cut cylinder r3, then three more copies 20 mm apart along X.
    let cut = Feature(name: "Foro", kind: .cylinder(radius: 3, height: 10), position: Vec3(-30, 0, -2), operation: .cut)
    var row = PatternSpec(body: cut.id, kind: .rectangular)
    row.countX = 4; row.spacingX = 20; row.countY = 1
    let one = DesignEvaluator.evaluate(CADDocument(features: [plate, cut]), revision: "a").bodies[0].mesh.volume
    let result = DesignEvaluator.evaluate(CADDocument(features: [plate, cut, Feature(name: "Serie", kind: .pattern(row))]), revision: "b")
    #expect(result.issues.isEmpty && result.bodies.count == 1)
    let m = result.bodies[0].mesh
    #expect(MeshValidator.validate(m).isWatertight)
    #expect(abs((base - m.volume) - 4 * (base - one)) < 1e-6)
    // Mirrored about YZ: the hole at x = -30 appears at +30.
    var mirror = PatternSpec(body: cut.id, kind: .mirror)
    mirror.plane = .yz; mirror.offset = 0
    let mirrored = DesignEvaluator.evaluate(CADDocument(features: [plate, cut, Feature(name: "Specchio", kind: .pattern(mirror))]), revision: "c")
    #expect(abs((base - mirrored.bodies[0].mesh.volume) - 2 * (base - one)) < 1e-6)
    // A hole feature in a circular pattern: six around the centre.
    let disc = Feature(name: "Disco", kind: .cylinder(radius: 30, height: 5))
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(20, 0, 5)], size: "M4", diameter: 4.5)))
    var ring = PatternSpec(body: hole.id, kind: .circular)
    ring.count = 6; ring.angle = 360; ring.center = .zero
    let discVol = DesignEvaluator.evaluate(CADDocument(features: [disc]), revision: "d").bodies[0].mesh.volume
    let oneHole = DesignEvaluator.evaluate(CADDocument(features: [disc, hole]), revision: "e").bodies[0].mesh.volume
    let six = DesignEvaluator.evaluate(CADDocument(features: [disc, hole, Feature(name: "Serie", kind: .pattern(ring))]), revision: "f")
    #expect(six.issues.isEmpty && MeshValidator.validate(six.bodies[0].mesh).isWatertight)
    #expect(abs((discVol - six.bodies[0].mesh.volume) - 6 * (discVol - oneHole)) < 1e-3)
}
