import Foundation
import Testing
@testable import CADCore

private func bodies(_ features: [Feature]) -> (bodies: [DesignEvaluator.Body], issues: [DesignEvaluator.Issue]) {
    DesignEvaluator.evaluate(CADDocument(features: features), revision: UUID().uuidString)
}

@Test func combineJoinsCutsAndIntersectsBodies() throws {
    // Two boxes 20³ overlapping by half: target at the origin, tool moved 10 along X.
    let target = Feature(name: "A", kind: .box(width: 20, depth: 20, height: 20))
    var tool = Feature(name: "B", kind: .box(width: 20, depth: 20, height: 20))
    tool.position = Vec3(10, 0, 0)
    for (op, volume) in [(CombineSpec.Operation.join, 12_000.0), (.cut, 4_000), (.intersect, 4_000)] {
        let combine = Feature(name: "Combina", kind: .combine(CombineSpec(target: target.id, tools: [tool.id], operation: op)))
        let r = bodies([target, tool, combine])
        #expect(r.issues.isEmpty, "\(r.issues)")
        #expect(r.bodies.count == 1 && r.bodies[0].id == target.id, "\(op): the tool is gone")
        #expect(abs(r.bodies[0].mesh.volume - volume) < 1e-6, "\(op): \(r.bodies[0].mesh.volume)")
        #expect(MeshValidator.validate(r.bodies[0].mesh).isWatertight)
    }
    // Keep tools: the tool stays as it was.
    let kept = Feature(name: "Combina", kind: .combine(CombineSpec(target: target.id, tools: [tool.id], operation: .cut, keepTools: true)))
    let r = bodies([target, tool, kept])
    #expect(r.bodies.count == 2 && abs(r.bodies.first { $0.id == tool.id }!.mesh.volume - 8_000) < 1e-6)
}

@Test func combineReportsMissingBodiesAndEmptyResults() throws {
    let target = Feature(name: "A", kind: .box(width: 10, depth: 10, height: 10))
    let missing = Feature(name: "Combina", kind: .combine(CombineSpec(target: target.id, tools: [UUID()], operation: .join)))
    let r = bodies([target, missing])
    #expect(r.issues.contains { $0.message.contains("strumento non esistono") } && r.bodies.count == 1)
    // Cutting the whole target away: nothing left, said.
    var big = Feature(name: "B", kind: .box(width: 40, depth: 40, height: 40))
    big.position = Vec3(0, 0, -10)
    let all = Feature(name: "Combina", kind: .combine(CombineSpec(target: target.id, tools: [big.id], operation: .cut)))
    let r2 = bodies([target, big, all])
    #expect(r2.bodies.isEmpty && r2.issues.contains { $0.message.contains("non resta niente") })
    // The same body as target and tool: refused.
    let own = Feature(name: "Combina", kind: .combine(CombineSpec(target: target.id, tools: [target.id])))
    #expect(bodies([target, own]).issues.contains { $0.message.contains("obiettivo non può") })
}
