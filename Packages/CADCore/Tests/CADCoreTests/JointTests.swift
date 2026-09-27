import Foundation
import Testing
@testable import CADCore

private func box(_ m: Mesh) -> (Vec3, Vec3) {
    let v = m.vertices
    return (Vec3(v.map(\.x).min()!, v.map(\.y).min()!, v.map(\.z).min()!), Vec3(v.map(\.x).max()!, v.map(\.y).max()!, v.map(\.z).max()!))
}
private func near(_ a: Vec3, _ b: Vec3, _ tol: Double = 1e-6) -> Bool { (a - b).length < tol }

@Test func jointsPlaceTurnAndSlideParts() throws {
    let pin = Feature(name: "Perno", kind: .box(width: 4, depth: 4, height: 20))   // local origin: bottom centre
    func placed(_ spec: JointSpec, _ extra: [Feature] = []) -> DesignEvaluator.Body {
        let r = DesignEvaluator.evaluate(CADDocument(features: extra + [pin, Feature(name: "G", kind: .joint(spec))]), revision: UUID().uuidString)
        #expect(r.issues.isEmpty, "\(r.issues.map(\.message))")
        return r.bodies.first { $0.id == pin.id }!
    }
    var spec = JointSpec(kind: .revolute, moving: pin.id, movingOrigin: .zero, movingAxis: Vec3(0, 0, 1),
                         fixed: nil, fixedOrigin: Vec3(10, 0, 5), fixedAxis: Vec3(0, 0, 1))
    var (lo, hi) = box(placed(spec).mesh)
    #expect(near(lo, Vec3(8, -2, 5)) && near(hi, Vec3(12, 2, 25)))
    // Flipped: it hangs down from the point.
    spec.flip = true
    (lo, hi) = box(placed(spec).mesh)
    #expect(near(lo, Vec3(8, -2, -15)) && near(hi, Vec3(12, 2, 5)))
    // Sliding 3 mm along the axis (a revolute ignores the offset).
    spec.flip = false; spec.offset = 3
    #expect(near(box(placed(spec).mesh).0, Vec3(8, -2, 5)))
    spec.kind = .slider
    #expect(near(box(placed(spec).mesh).0, Vec3(8, -2, 8)))
    // Turning a long part 90° about Z: it now runs along Y.
    let bar = Feature(name: "Barra", kind: .box(width: 40, depth: 4, height: 4))
    let turn = JointSpec(kind: .revolute, moving: bar.id, movingOrigin: .zero, movingAxis: Vec3(0, 0, 1), fixed: nil,
                         fixedOrigin: .zero, fixedAxis: Vec3(0, 0, 1), angle: 90)
    let r = DesignEvaluator.evaluate(CADDocument(features: [bar, Feature(name: "G", kind: .joint(turn))]), revision: "t")
    let (blo, bhi) = box(r.bodies[0].mesh)
    #expect(abs((bhi.y - blo.y) - 40) < 1e-6 && abs((bhi.x - blo.x) - 4) < 1e-6)
}

@Test func aJoinedPartFollowsItsPartner() throws {
    // A plate with a hole at (10, 0), then moved 50 along Y; the pin is joined to the hole.
    let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 20, height: 5))
    let move = Feature(name: "Sposta", kind: .move(MoveSpec(bodies: [plate.id], translation: Vec3(0, 50, 0))))
    let pin = Feature(name: "Perno", kind: .cylinder(radius: 2, height: 20), position: Vec3(-100, 0, 0))
    let joint = Feature(name: "G", kind: .joint(JointSpec(kind: .revolute, moving: pin.id, movingOrigin: Vec3(-100, 0, 0), movingAxis: Vec3(0, 0, 1),
                                                          fixed: plate.id, fixedOrigin: Vec3(10, 0, 5), fixedAxis: Vec3(0, 0, 1))))
    let r = DesignEvaluator.evaluate(CADDocument(features: [plate, move, pin, joint]), revision: "j")
    #expect(r.issues.isEmpty)
    let (lo, hi) = box(r.bodies.first { $0.id == pin.id }!.mesh)
    #expect(abs((lo.x + hi.x) / 2 - 10) < 1e-6 && abs((lo.y + hi.y) / 2 - 50) < 1e-6 && abs(lo.z - 5) < 1e-9)
    // Saved and read back; a joint to a missing part is an issue.
    let doc = CADDocument(features: [plate, pin, joint])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
    #expect(!DesignEvaluator.evaluate(CADDocument(features: [pin, joint]), revision: "k").issues.isEmpty)
}

@Test func jointGripsComeFromRimsAndFaces() throws {
    let shaft = Feature(name: "Albero", kind: .cylinder(radius: 5, height: 20), position: Vec3(10, 0, 0))
    let body = DesignEvaluator.evaluate(CADDocument(features: [shaft]), revision: "g").bodies[0]
    let rims = body.snapshot.edges.compactMap(JointFrame.from(edge:))
    #expect(rims.count == 2)
    #expect(rims.contains { ($0.origin - Vec3(10, 0, 20)).length < 1e-6 && abs(abs($0.axis.z) - 1) < 1e-9 })
    let top = body.snapshot.faces.first { if case let .plane(_, n) = $0.surface { n.z > 0.5 } else { false } }!
    let frame = JointFrame.from(face: top.id, in: body.snapshot)!
    #expect((frame.origin - Vec3(10, 0, 20)).length < 1e-6 && frame.axis.z > 0.999)
    let wall = body.snapshot.faces.first { if case .cylinder = $0.surface { true } else { false } }!
    let axis = JointFrame.from(face: wall.id, in: body.snapshot)!
    #expect(abs(axis.origin.x - 10) < 1e-6 && abs(axis.origin.y) < 1e-6 && abs(abs(axis.axis.z) - 1) < 1e-9)
    // Own coordinates of a component come back through the inverse placement.
    let ref = ComponentRef(path: "x.ftk", rotation: Vec3(0, 0, 90))
    let place = ref.placement(position: Vec3(5, 0, 0))
    let p = Vec3(1, 2, 3)
    #expect((place.inverse.point(place.point(p)) - p).length < 1e-12)
}
