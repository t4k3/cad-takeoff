import Foundation
import Testing
@testable import CADCore

private let part = CADDocument(features: [Feature(name: "Blocco", kind: .box(width: 20, depth: 10, height: 5))])

@Test func assemblyPlacesTwoInstancesOfAPart() throws {
    let a = Feature(name: "Blocco A", kind: .component(ComponentRef(path: "Progetto/Blocco.ftk")))
    let b = Feature(name: "Blocco B", kind: .component(ComponentRef(path: "Progetto/Blocco.ftk", rotation: Vec3(0, 0, 90))),
                    position: Vec3(50, 0, 0))
    let assembly = CADDocument(features: [a, b])
    let (bodies, issues) = DesignEvaluator.evaluate(assembly, revision: "r") { $0 == "Progetto/Blocco.ftk" ? part : nil }
    #expect(issues.isEmpty && bodies.count == 2)
    #expect(bodies.allSatisfy { abs($0.mesh.volume - 1000) < 1e-9 && MeshValidator.validate($0.mesh).isWatertight })
    // Rotated 90° about Z: 20 along Y, 10 along X, around x = 50.
    let box = bodies[1].mesh.bounds!
    #expect(abs(box.size.x - 10) < 1e-9 && abs(box.size.y - 20) < 1e-9 && abs(box.center.x - 50) < 1e-9)
    // Faces stay selectable, with the part's surfaces moved into place.
    #expect(bodies[1].snapshot.faces.contains { if case let .plane(_, n) = $0.surface { abs(n.x - 1) < 1e-9 } else { false } })
    #expect(try CADDocument.decode(assembly.encoded()) == assembly)
}

@Test func missingCircularAndNestedComponents() {
    let lost = CADDocument(features: [Feature(name: "X", kind: .component(ComponentRef(path: "nope.ftk")))])
    #expect(DesignEvaluator.evaluate(lost, revision: "r") { _ in nil }.issues.first?.message.contains("non trovato") == true)
    let loop = CADDocument(features: [Feature(name: "Io", kind: .component(ComponentRef(path: "loop.ftk")))])
    let circular = DesignEvaluator.evaluate(loop, revision: "r") { _ in loop }
    #expect(circular.issues.contains { $0.message.contains("circolare") })
    let sub = CADDocument(features: [Feature(name: "B1", kind: .component(ComponentRef(path: "b.ftk"))),
                                     Feature(name: "B2", kind: .component(ComponentRef(path: "b.ftk")), position: Vec3(0, 30, 0))])
    let top = CADDocument(features: [Feature(name: "Sotto", kind: .component(ComponentRef(path: "sub.ftk")), position: Vec3(0, 0, 10))])
    let (bodies, issues) = DesignEvaluator.evaluate(top, revision: "r") { $0 == "sub.ftk" ? sub : ($0 == "b.ftk" ? part : nil) }
    #expect(issues.isEmpty && bodies.count == 1 && abs(bodies[0].mesh.volume - 2000) < 1e-9)
    #expect(abs(bodies[0].mesh.bounds!.min.z - 10) < 1e-9)
}
