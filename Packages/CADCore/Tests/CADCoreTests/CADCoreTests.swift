import Foundation
import Testing
@testable import CADCore

@Test func boxIsWatertightWithCorrectVolume() {
    let box = Primitives.box(width: 10, depth: 20, height: 30)
    let report = MeshValidator.validate(box)
    #expect(report.isWatertight)
    #expect(abs(report.volume - 6000) < 1e-6)
    #expect(box.triangleCount == 12)
}

@Test func cylinderVolumeApproachesAnalytic() {
    let cyl = Primitives.cylinder(radius: 5, height: 10, segments: 256)
    let analytic = Double.pi * 25 * 10
    #expect(MeshValidator.validate(cyl).isWatertight)
    #expect(abs(cyl.volume - analytic) / analytic < 0.001)
}

@Test func concaveProfileExtrudes() {
    // L-shape, given clockwise to check re-orientation
    let l = Profile2D(points: [Vec2(0, 0), Vec2(0, 20), Vec2(10, 20), Vec2(10, 10), Vec2(20, 10), Vec2(20, 0)].reversed())
    #expect(abs(l.area - 300) < 1e-9)
    let mesh = Operations.extrude(l, height: 5)
    #expect(MeshValidator.validate(mesh).isWatertight)
    #expect(abs(mesh.volume - 1500) < 1e-6)
}

@Test func binarySTLLayout() {
    let box = Primitives.box(width: 1, depth: 1, height: 1)
    let data = STLExporter.binary(box)
    #expect(data.count == 84 + 12 * 50)
    let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(UInt32(littleEndian: count) == 12)
}

@Test func asciiSTLHasFacets() {
    let s = STLExporter.ascii(Primitives.box(width: 1, depth: 1, height: 1), name: "cube")
    #expect(s.hasPrefix("solid cube"))
    #expect(s.components(separatedBy: "facet normal").count - 1 == 12)
}

@Test func documentRoundTrip() throws {
    let doc = CADDocument(features: [
        Feature(name: "Box", kind: .box(width: 10, depth: 10, height: 10)),
        Feature(name: "Pin", kind: .cylinder(radius: 2, height: 15), position: Vec3(20, 0, 0)),
    ])
    let back = try CADDocument.decode(doc.encoded())
    #expect(back == doc)
    #expect(back.buildMesh().triangleCount == doc.buildMesh().triangleCount)
}
