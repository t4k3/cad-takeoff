import Foundation
import Testing
@testable import CADCore

private let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 40, height: 10))
private func ngon(_ d: Double, _ n: Int = 64) -> Double { Profile2D.circle(radius: d / 2, segments: n).area }

private func drilled(_ spec: HoleSpec) -> (Mesh, [DesignEvaluator.Issue], BodySnapshot?) {
    let hole = Feature(name: "Foro", kind: .hole(spec), operation: .cut)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [plate, hole]), revision: "r")
    return (bodies.first?.mesh ?? Mesh(), issues, bodies.first?.snapshot)
}

@Test func throughClearanceHoleM4() {
    let spec = HoleSpec(centers: [Vec3(0, 0, 10)], fit: .clearance, size: "M4")
    #expect(spec.boreDiameter == 4.5)
    let (mesh, issues, snap) = drilled(spec)
    #expect(issues.isEmpty && MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - (16000 - ngon(4.5) * 10)) < 1e-3)
    let wall = snap?.faces.first { if case let .cylinder(_, _, r) = $0.surface { abs(r - 2.25) < 1e-9 } else { false } }
    #expect(wall != nil, "hole wall selectable as Ø4.5 cylinder")
}

@Test func blindHoleWithDepthAndFourCenters() {
    let pts = [Vec3(-10, -10, 10), Vec3(10, -10, 10), Vec3(10, 10, 10), Vec3(-10, 10, 10)]
    let spec = HoleSpec(centers: pts, fit: .heatInsert, size: "M3", depth: 6)
    let (mesh, _, _) = drilled(spec)
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - (16000 - 4 * ngon(4.0) * 6)) < 1e-3)
}

@Test func counterboreM3() {
    let spec = HoleSpec(centers: [Vec3(0, 0, 10)], style: .counterbore, fit: .clearance, size: "M3")
    let (mesh, _, _) = drilled(spec)
    #expect(MeshValidator.validate(mesh).isWatertight)
    let expected = 16000 - ngon(6.5) * 3.3 - ngon(3.4) * (10 - 3.3)
    #expect(abs(mesh.volume - expected) < 1e-3)
}

@Test func countersinkM5HasConicalFace() {
    let spec = HoleSpec(centers: [Vec3(0, 0, 10)], style: .countersink, fit: .clearance, size: "M5")
    let (mesh, _, snap) = drilled(spec)
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(mesh.volume < 16000 - ngon(5.5) * 10)
    let cone = snap?.faces.first { if case .cone = $0.surface { true } else { false } }
    #expect(cone != nil)
}

@Test func holeOnSideFaceAlongX() {
    // Horizontal hole drilled from the +X face.
    let spec = HoleSpec(centers: [Vec3(20, 0, 5)], direction: Vec3(-1, 0, 0), fit: .manual, size: nil, diameter: 3, depth: 15)
    let (mesh, _, _) = drilled(spec)
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - (16000 - ngon(3) * 15)) < 1e-3)
}

@Test func modeledThreadIsReportedAsNotYetAvailable() {
    let (_, issues, _) = drilled(HoleSpec(centers: [Vec3(0, 0, 10)], fit: .modeledThread, size: "M6", depth: 8))
    #expect(issues.count == 1 && issues[0].message.contains("non ancora disponibile"))
}

@Test func throughHoleOnTallPartStaysClosed() {
    let tall = Feature(name: "T", kind: .box(width: 30, depth: 30, height: 60))
    let hole = Feature(name: "H", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 60)], fit: .clearance, size: "M5")), operation: .cut)
    let (b, _) = DesignEvaluator.evaluate(CADDocument(features: [tall, hole]), revision: "r")
    #expect(MeshValidator.validate(b[0].mesh).isWatertight)
    #expect(abs(b[0].mesh.volume - (54000 - ngon(5.5) * 60)) < 1e-2)
}

@Test func holeSpecValidationAndPersistence() throws {
    var spec = HoleSpec(centers: [Vec3(0, 0, 0)], fit: .tapped, size: "M8")
    #expect(spec.boreDiameter == 6.8 && spec.summary.contains("M8"))
    try spec.validate()
    spec.size = "M7"
    #expect(throws: KernelError.self) { try spec.validate() }
    spec.size = "M8"
    spec.centers = [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(0, 0, 0)]
    #expect(throws: KernelError.self) { try spec.validate() }
    let f = Feature(name: "F", kind: .hole(HoleSpec(centers: [Vec3(1, 2, 3)])), operation: .cut)
    let doc = CADDocument(features: [plate, f])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}

@Test func throughHolesAcrossSizesAndThicknessesStayClosed() {
    for h in [3.0, 25.0, 60.0] {
        for size in ["M2", "M5", "M12"] {
            for style in HoleSpec.Style.allCases {
                let part = Feature(name: "P", kind: .box(width: 50, depth: 50, height: h))
                let spec = HoleSpec(centers: [Vec3(3, -2, h)], style: style, fit: .clearance, size: size)
                let hole = Feature(name: "H", kind: .hole(spec), operation: .cut)
                let (b, issues) = DesignEvaluator.evaluate(CADDocument(features: [part, hole]), revision: "r")
                let r = MeshValidator.validate(b[0].mesh)
                #expect(issues.isEmpty && r.isWatertight, "h=\(h) \(size) \(style): bordi \(r.boundaryEdges) nm \(r.nonManifoldEdges)")
            }
        }
    }
}
