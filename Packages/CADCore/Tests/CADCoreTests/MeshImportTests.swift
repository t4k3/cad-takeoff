import Compression
import Foundation
import Testing
@testable import CADCore

private let plate = Feature(name: "Piastra", kind: .box(width: 40, depth: 30, height: 5))

@Test func stlRoundTripBecomesAWorkingBody() throws {
    let exported = STLExporter.binary(try PrimitiveKernel.build(plate).mesh)
    let mesh = try MeshImport.stl(exported)
    #expect(mesh.vertices.count == 8 && mesh.triangleCount == 12 && abs(mesh.volume - 6000) < 1e-6)
    let imported = Feature(name: "Piastra STL", kind: .importedMesh(ImportedMesh(mesh: mesh, source: "piastra.stl")))
    // Its top is a real planar face: a hole drilled on it cuts the imported body.
    let hole = Feature(name: "Foro", kind: .hole(HoleSpec(centers: [Vec3(0, 0, 5)], fit: .clearance, size: "M4")), operation: .cut)
    let (bodies, issues) = DesignEvaluator.evaluate(CADDocument(features: [imported, hole]), revision: "r")
    #expect(issues.isEmpty && bodies.count == 1 && MeshValidator.validate(bodies[0].mesh).isWatertight)
    #expect(abs(bodies[0].mesh.volume - (6000 - Profile2D.circle(radius: 2.25, segments: 64).area * 5)) < 1e-3)
    let plain = DesignEvaluator.evaluate(CADDocument(features: [imported]), revision: "r").bodies[0].snapshot
    #expect(plain.faces.count == 6 && plain.faces.allSatisfy { if case .plane = $0.surface { true } else { false } })
    let doc = CADDocument(features: [imported])
    #expect(try CADDocument.decode(doc.encoded()) == doc)
}

@Test func curvedSurfacesAreFreeformRegions() throws {
    let cylinder = try PrimitiveKernel.build(Feature(name: "C", kind: .cylinder(radius: 10, height: 20))).mesh
    let imported = Feature(name: "C", kind: .importedMesh(ImportedMesh(mesh: try MeshImport.stl(STLExporter.binary(cylinder)), source: "c.stl")))
    let snap = DesignEvaluator.evaluate(CADDocument(features: [imported]), revision: "r").bodies[0].snapshot
    // Top, bottom and one smooth wall.
    #expect(snap.faces.count == 3 && snap.faces.filter { $0.surface == .freeform }.count == 1)
}

@Test func asciiStlAndObj() throws {
    let ascii = """
    solid t
    facet normal 0 0 -1
    outer loop
    vertex 0 0 0
    vertex 0 1 0
    vertex 1 0 0
    endloop
    endfacet
    facet normal 0 -1 0
    outer loop
    vertex 0 0 0
    vertex 1 0 0
    vertex 0 0 1
    endloop
    endfacet
    facet normal -1 0 0
    outer loop
    vertex 0 0 0
    vertex 0 0 1
    vertex 0 1 0
    endloop
    endfacet
    facet normal 1 1 1
    outer loop
    vertex 1 0 0
    vertex 0 1 0
    vertex 0 0 1
    endloop
    endfacet
    endsolid t
    """
    let tetra = try MeshImport.stl(Data(ascii.utf8))
    #expect(tetra.vertices.count == 4 && abs(tetra.volume - 1.0 / 6) < 1e-12 && MeshValidator.validate(tetra).isWatertight)
    let cube = """
    v 0 0 0
    v 10 0 0
    v 10 10 0
    v 0 10 0
    v 0 0 10
    v 10 0 10
    v 10 10 10
    v 0 10 10
    f 1 4 3 2
    f 5 6 7 8
    f 1 2 6 5
    f 2 3 7 6
    f 3 4 8 7
    f 4/1 1/1 5/1 8/1
    """
    let mesh = try MeshImport.obj(Data(cube.utf8))
    #expect(mesh.triangleCount == 12 && abs(mesh.volume - 1000) < 1e-9 && MeshValidator.validate(mesh).isWatertight)
}

@Test func threeMFStoredAndDeflated() throws {
    let a = try PrimitiveKernel.build(plate).mesh
    let b = try PrimitiveKernel.build(Feature(name: "C", kind: .cylinder(radius: 5, height: 10), position: Vec3(50, 0, 0))).mesh
    let archive = try ThreeMFExporter.archive(parts: [.init(name: "Piastra", mesh: a), .init(name: "Perno", mesh: b)])
    let parts = try MeshImport.threeMF(archive)
    #expect(parts.map(\.name) == ["Piastra", "Perno"])
    #expect(abs(parts[0].mesh.volume - 6000) < 1e-3 && abs(parts[1].mesh.bounds!.center.x - 50) < 1e-6)
    // A deflated archive in centimetres with a build transform (+1 cm on X).
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="centimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>
    <object id="1" type="model" name="Tetra"><mesh><vertices>
    <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/><vertex x="0" y="0" z="1"/>
    </vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh></object>
    </resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 1 0 0"/></build></model>
    """
    let tetra = try MeshImport.threeMF(deflatedZip(name: "3D/3dmodel.model", Data(xml.utf8)))
    #expect(tetra.count == 1 && abs(tetra[0].mesh.volume - 1000.0 / 6) < 1e-9)
    #expect(abs(tetra[0].mesh.bounds!.min.x - 10) < 1e-9 && abs(tetra[0].mesh.bounds!.max.x - 20) < 1e-9)
}

/// Minimal ZIP with one deflated entry (CRC left zero: the reader does not check it).
private func deflatedZip(name: String, _ content: Data) -> Data {
    var out = Data(count: content.count + 1024)
    let n = out.withUnsafeMutableBytes { dst in
        content.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, content.count + 1024,
                                      src.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
        }
    }
    let body = out.prefix(n)
    var zip = Data()
    func le16(_ v: Int) { zip.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16 & 0xffff) }
    let nameData = Data(name.utf8)
    le32(0x0403_4b50); le16(20); le16(0); le16(8); le16(0); le16(0); le32(0); le32(body.count); le32(content.count)
    le16(nameData.count); le16(0); zip.append(nameData); zip.append(body)
    let dir = zip.count
    le32(0x0201_4b50); le16(20); le16(20); le16(0); le16(8); le16(0); le16(0); le32(0); le32(body.count); le32(content.count)
    le16(nameData.count); le16(0); le16(0); le16(0); le16(0); le32(0); le32(0); zip.append(nameData)
    let dirSize = zip.count - dir
    le32(0x0605_4b50); le16(0); le16(0); le16(1); le16(1); le32(dirSize); le32(dir); le16(0)
    return zip
}
