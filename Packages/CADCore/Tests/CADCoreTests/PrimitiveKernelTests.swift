import Foundation
import Testing
@testable import CADCore

@Suite struct PrimitiveKernelTests {
    @Test func boxHasExplicitClosedTopologyAndMeasures() throws {
        let feature = Feature(name: "Box", kind: .box(width: 40, depth: 30, height: 5), position: Vec3(7, 8, 9))
        let body = try PrimitiveKernel.build(feature)
        try body.validate()
        #expect(body.vertices.count == 8)
        #expect(body.edges.count == 12)
        #expect(body.faces.count == 6)
        #expect(body.halfEdges.count == 24)
        #expect(MeshValidator.validate(body.mesh).isWatertight)
        #expect(abs(body.mesh.volume - 6000) < 1e-8)
        #expect(body.mesh.bounds == feature.buildMesh().bounds)
        let snapshot = body.snapshot(revision: "r1")
        #expect(snapshot.faces.count == 6 && snapshot.edges.count == 12)
        #expect(snapshot.triangleFace.count == 12)
        #expect(snapshot.faces[0].area == 1200 && snapshot.faces[1].area == 1200)
        #expect(snapshot.edges.map(\.length).sorted() == [Double](repeating: 5, count: 4) + [Double](repeating: 30, count: 4) + [Double](repeating: 40, count: 4))
        #expect(snapshot.faces[1].surface == .plane(origin: Vec3(-13, -7, 14), normal: Vec3(0, 0, 1)))
        try checkSnapshot(snapshot, body: body)
    }

    @Test func cylinderSeparatesFacetsFromSemanticFaces() throws {
        let feature = Feature(name: "Pin", kind: .cylinder(radius: 10, height: 20), position: Vec3(3, -7, 13))
        let body = try PrimitiveKernel.build(feature)
        let snapshot = body.snapshot(revision: "cylinder")
        #expect(body.vertices.count == 128 && body.faces.count == 66 && body.edges.count == 192)
        #expect(snapshot.faces.count == 3 && snapshot.edges.count == 2)
        #expect(snapshot.faces[2].topologyFaceIDs.count == 64)
        #expect(snapshot.faces[2].surface == .cylinder(axisOrigin: feature.position, axisDirection: Vec3(0, 0, 1), radius: 10))
        let perimeter = 2 * 64.0 * 10 * sin(.pi / 64)
        #expect(abs(snapshot.faces[2].area - perimeter * 20) < 1e-8)
        #expect(abs(body.maximumSurfaceDeviation - 10 * (1 - cos(.pi / 64))) < 1e-14)
        // Default 64 facets are NOT a universal 0.01 mm precision guarantee.
        #expect(body.maximumSurfaceDeviation > 0.01)
        for edge in snapshot.edges {
            #expect(edge.polyline.count == 65 && edge.polyline.first == edge.polyline.last)
            #expect(edge.topologyEdgeIDs.count == 64)
            #expect(abs(edge.length - perimeter) < 1e-8)
        }
        #expect(abs(body.mesh.volume - feature.buildMesh().volume) < 1e-8)
        #expect(MeshValidator.validate(body.mesh).isWatertight)
        try checkSnapshot(snapshot, body: body)
    }

    @Test func primitiveIDsSurviveDimensionsTranslationAndReopen() throws {
        var feature = Feature(name: "Originale", kind: .box(width: 40, depth: 30, height: 5))
        let before = try PrimitiveKernel.build(feature)
        feature.kind = .box(width: 12, depth: 19, height: 7)
        feature.position = Vec3(100, 2, -40)
        feature.name = "Rinominato"; feature.color = PartColor(hex: "#FF0000")!
        let changed = try PrimitiveKernel.build(feature)
        #expect(before.faces.map(\.id) == changed.faces.map(\.id))
        #expect(before.edges.map(\.id) == changed.edges.map(\.id))
        #expect(before.vertices.map(\.id) == changed.vertices.map(\.id))
        let reopened = try CADDocument.decode(CADDocument(features: [feature]).encoded()).features[0]
        #expect(try PrimitiveKernel.build(reopened).snapshot(revision: "same") == changed.snapshot(revision: "same"))
        var other = feature; other.id = UUID()
        #expect(try Set(PrimitiveKernel.build(other).faces.map(\.id)).isDisjoint(with: Set(changed.faces.map(\.id))))
        feature.kind = .cylinder(radius: 4, height: 9)
        #expect(try Set(PrimitiveKernel.build(feature).faces.map(\.id)).isDisjoint(with: Set(changed.faces.map(\.id))))
    }

    @Test func cylinderSelectionIDsSurviveTessellationChanges() throws {
        let feature = Feature(name: "C", kind: .cylinder(radius: 7, height: 11))
        let coarse = try PrimitiveKernel.build(feature, cylinderSegments: 16).snapshot(revision: "a")
        let fine = try PrimitiveKernel.build(feature, cylinderSegments: 128).snapshot(revision: "b")
        #expect(coarse.faces.map(\.id) == fine.faces.map(\.id))
        #expect(coarse.edges.map(\.id) == fine.edges.map(\.id))
        #expect(fine.maximumSurfaceDeviation < coarse.maximumSurfaceDeviation)
        #expect(Set(coarse.faces[2].topologyFaceIDs).isDisjoint(with: Set(fine.faces[2].topologyFaceIDs)))
    }

    @Test func concaveProfileHasFullCapsAndConservativeIdentity() throws {
        let p = Profile2D(points: [Vec2(0, 0), Vec2(20, 0), Vec2(20, 10), Vec2(10, 10), Vec2(10, 20), Vec2(0, 20)])
        var feature = Feature(name: "L", kind: .extrude(profile: p, height: 5))
        let body = try PrimitiveKernel.build(feature)
        #expect(body.faces.count == 8 && body.edges.count == 18)
        #expect(abs(body.mesh.volume - 1500) < 1e-8)
        #expect(body.snapshot(revision: "L").faces[1].area == 300)
        #expect(MeshValidator.validate(body.mesh).isWatertight)
        feature.kind = .extrude(profile: p, height: 12)
        #expect(try PrimitiveKernel.build(feature).edges.map(\.id) == body.edges.map(\.id))
        var points = p.points; points[1].x = 21
        feature.kind = .extrude(profile: Profile2D(points: points), height: 12)
        let edited = try PrimitiveKernel.build(feature)
        #expect(edited.faces[0].id == body.faces[0].id && edited.faces[1].id == body.faces[1].id)
        #expect(Set(edited.edges.map(\.id)).isDisjoint(with: Set(body.edges.map(\.id))))
        // Rotation of the same contour must not silently rebind side index zero.
        feature.kind = .extrude(profile: Profile2D(points: Array(p.points.dropFirst()) + [p.points[0]]), height: 5)
        #expect(try Set(PrimitiveKernel.build(feature).edges.map(\.id)).isDisjoint(with: Set(body.edges.map(\.id))))
        try checkSnapshot(body.snapshot(revision: "L"), body: body)
    }

    @Test func invalidParametersAndProfilesFailWithoutPartialGeometry() throws {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 0.001, 100_001] {
            #expect(throws: KernelError.self) { try PrimitiveKernel.build(Feature(name: "bad", kind: .box(width: value, depth: 10, height: 10))) }
            #expect(throws: KernelError.self) { try PrimitiveKernel.build(Feature(name: "bad", kind: .cylinder(radius: 10, height: value))) }
        }
        for segments in [Int.min, 0, 2, 513, Int.max] {
            #expect(throws: KernelError.self) { try PrimitiveKernel.build(Feature(name: "bad", kind: .cylinder(radius: 2, height: 3)), cylinderSegments: segments) }
        }
        let badProfiles: [[Vec2]] = [[], [Vec2(0, 0), Vec2(1, 1)],
            [Vec2(0, 0), Vec2(10, 10), Vec2(0, 10), Vec2(10, 0)],
            [Vec2(0, 0), Vec2(5, 0), Vec2(10, 0), Vec2(0, 10)],
            [Vec2(0, 0), Vec2(10, 0), Vec2(10, 0), Vec2(0, 10)],
            [Vec2(0, 0), Vec2(10, 0), Vec2(.nan, 10)],
            // Non-adjacent vertex touching another edge.
            [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(5, 0), Vec2(0, 10)],
            Profile2D.circle(radius: 20, segments: 129).points]
        for points in badProfiles {
            #expect(throws: KernelError.self) { try PrimitiveKernel.build(Feature(name: "bad", kind: .extrude(profile: Profile2D(points: points), height: 5))) }
        }
        #expect(throws: KernelError.self) { try PrimitiveKernel.build(Feature(name: "bad", kind: .box(width: 1, depth: 1, height: 1), position: Vec3(.nan, 0, 0))) }
    }

    @Test func boundedGeneratedCorpusPreservesVolumeAndIncidence() throws {
        // Deterministic radial polygons: simple, with both convex and concave corners.
        for sample in 0..<80 {
            let n = 3 + sample % 14, height = 0.5 + Double(sample)
            let points = (0..<n).map { i -> Vec2 in
                let angle = Double(i) * 2 * .pi / Double(n)
                let radius = 10 + Double((i * 7 + sample * 3) % 11)
                return Vec2(radius * cos(angle), radius * sin(angle))
            }
            let profile = Profile2D(points: points)
            let body = try PrimitiveKernel.build(Feature(name: "Corpus", kind: .extrude(profile: profile, height: height), position: Vec3(1000, -400, 120)))
            try body.validate()
            #expect(MeshValidator.validate(body.mesh).isWatertight)
            #expect(abs(body.mesh.volume - profile.area * height) < 1e-5)
            try checkSnapshot(body.snapshot(revision: "corpus"), body: body)
        }
    }

    @Test func smallestDimensionsAndLargeTranslationStayValid() throws {
        for kind: Feature.Kind in [.box(width: 0.01, depth: 0.01, height: 0.01), .cylinder(radius: 0.01, height: 0.01)] {
            let body = try PrimitiveKernel.build(Feature(name: "Small", kind: kind, position: Vec3(100_000, -100_000, 100_000)))
            try body.validate()
            #expect(body.snapshot(revision: "small").positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        }
    }

    private func checkSnapshot(_ s: BodySnapshot, body: BRepBody) throws {
        #expect(s.positions.count == s.normals.count)
        #expect(s.triangles.count % 3 == 0 && s.triangleFace.count == s.triangles.count / 3)
        #expect(s.triangleTopologyFace.count == s.triangleFace.count)
        #expect(s.triangles.allSatisfy { Int($0) < s.positions.count })
        #expect(s.triangleFace.allSatisfy { Int($0) < s.faces.count })
        #expect(s.normals.allSatisfy { abs($0.length - 1) < 1e-8 })
        let faces = Set(s.faces.map(\.id))
        #expect(s.edges.allSatisfy { $0.faces.count == 2 && Set($0.faces).count == 2 && $0.faces.allSatisfy { faces.contains($0) } })
        for (t, topology) in s.triangleTopologyFace.enumerated() {
            #expect(s.faces[Int(s.triangleFace[t])].topologyFaceIDs.contains(topology))
        }
        let renderMesh = Mesh(vertices: s.positions, indices: s.triangles)
        #expect(abs(renderMesh.volume - body.mesh.volume) < 1e-5)
    }
}
