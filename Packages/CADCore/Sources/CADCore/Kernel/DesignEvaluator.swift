import Foundation

/// Runs the active history in order and produces the bodies of the design (phase 3, T84).
/// A `newBody` feature starts a body; `join`, `cut`, `intersect` modify the bodies they touch.
/// Bodies never touched by a boolean keep the kernel's exact snapshot (same face/edge IDs).
public enum DesignEvaluator {
    public struct Body: Sendable {
        /// ID of the feature that created the body (name, colour and visibility come from it).
        public let id: UUID
        public let source: Feature
        /// Features that modified the body after its creation, in order.
        public let modifiedBy: [UUID]
        public let mesh: Mesh
        public let snapshot: BodySnapshot
        public var isVisible: Bool { source.isVisible }
    }

    public struct Issue: Sendable, Equatable {
        public let featureID: UUID
        public let message: String
    }

    public static func evaluate(_ doc: CADDocument, revision: String) -> (bodies: [Body], issues: [Issue]) {
        struct Work { var source: Feature; var snapshot: BodySnapshot; var solid: CSGSolid?; var mesh: Mesh; var modifiedBy: [UUID] }
        var bodies: [Work] = []
        var issues: [Issue] = []
        // A damaged file with the same ID twice: exclude every copy, never guess which one is meant.
        let counts = Dictionary(grouping: doc.activeFeatures, by: \.id).mapValues(\.count)
        var reported = Set<UUID>()
        for feature in doc.activeFeatures {
            guard counts[feature.id] == 1 else {
                if reported.insert(feature.id).inserted {
                    issues.append(.init(featureID: feature.id, message: "Identificatore di parte duplicato nel documento."))
                }
                continue
            }
            let brep: BRepBody
            do { brep = try PrimitiveKernel.build(feature) } catch {
                issues.append(.init(featureID: feature.id, message: error.localizedDescription)); continue
            }
            let snap = brep.snapshot(revision: revision)
            guard feature.operation != .newBody else {
                bodies.append(Work(source: feature, snapshot: snap, solid: nil, mesh: brep.mesh, modifiedBy: []))
                continue
            }
            let tool = CSGSolid(snap)
            let toolBox = bounds(snap)
            let touched = bodies.indices.filter { overlaps(bounds(bodies[$0].snapshot), toolBox) }
            switch feature.operation {
            case .newBody:
                break
            case .join:
                guard let first = touched.first else {
                    // Touches nothing: behaves like a new body (as in Fusion).
                    bodies.append(Work(source: feature, snapshot: snap, solid: nil, mesh: brep.mesh, modifiedBy: []))
                    continue
                }
                var solid = solidOf(bodies[first]).union(tool)
                for other in touched.dropFirst() { solid = solid.union(solidOf(bodies[other])) }
                bodies[first] = rebuilt(bodies[first], solid, by: feature.id, revision: revision)
                for other in touched.dropFirst().reversed() { bodies.remove(at: other) }
            case .cut, .intersect:
                if touched.isEmpty {
                    issues.append(.init(featureID: feature.id, message: feature.operation == .cut
                        ? "Taglio senza effetto: non tocca nessun corpo." : "Intersezione senza effetto: non tocca nessun corpo."))
                }
                for i in touched.reversed() {
                    let before = solidOf(bodies[i])
                    let solid = feature.operation == .cut ? before.subtracting(tool) : before.intersecting(tool)
                    if solid.isEmpty { bodies.remove(at: i) } else { bodies[i] = rebuilt(bodies[i], solid, by: feature.id, revision: revision) }
                }
            }
        }
        let out = bodies.map { Body(id: $0.source.id, source: $0.source, modifiedBy: $0.modifiedBy, mesh: $0.mesh, snapshot: $0.snapshot) }
        return (out, issues)

        func solidOf(_ w: Work) -> CSGSolid { w.solid ?? CSGSolid(w.snapshot) }
        func rebuilt(_ w: Work, _ solid: CSGSolid, by id: UUID, revision: String) -> Work {
            let (mesh, triFace) = solid.triangulated()
            return Work(source: w.source, snapshot: snapshot(of: solid, mesh: mesh, triangleFace: triFace, bodyID: w.source.id, revision: revision),
                        solid: solid, mesh: mesh, modifiedBy: w.modifiedBy + [id])
        }
    }

    // MARK: Snapshot of a boolean result

    /// Renderer/selection data for a CSG result: faces keep the IDs and exact surfaces of the
    /// faces they came from; edges are the boundaries between different faces.
    static func snapshot(of solid: CSGSolid, mesh: Mesh, triangleFace: [Int], bodyID: UUID, revision: String) -> BodySnapshot {
        // Faces actually present, in first-use order.
        var faceOrder: [Int] = [], faceSlot: [Int: Int] = [:]
        for f in triangleFace where faceSlot[f] == nil { faceSlot[f] = faceOrder.count; faceOrder.append(f) }
        var areas = [Double](repeating: 0, count: faceOrder.count)
        var positions: [Vec3] = [], normals: [Vec3] = [], tris: [UInt32] = [], triFace: [UInt32] = []
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let slot = faceSlot[triangleFace[t]]!
            let face = solid.faces[triangleFace[t]]
            areas[slot] += (b - a).cross(c - a).length / 2
            let flat = (b - a).cross(c - a).normalized
            for v in [a, b, c] {
                tris.append(UInt32(positions.count))
                positions.append(v)
                normals.append(smoothNormal(face, at: v) ?? flat)
            }
            triFace.append(UInt32(slot))
        }
        let infos = faceOrder.enumerated().map { slot, f -> FaceInfo in
            let face = solid.faces[f]
            return FaceInfo(id: face.flipped ? FaceID(rawValue: face.id.rawValue + "/inv") : face.id,
                            surface: surface(face), area: areas[slot], topologyFaceIDs: [])
        }
        let edges = boundaryEdges(mesh: mesh, triangleFace: triangleFace.map { faceSlot[$0]! }, faces: infos, bodyID: bodyID)
        return BodySnapshot(bodyID: bodyID, revision: revision, positions: positions, normals: normals, triangles: tris,
                            triangleFace: triFace, triangleTopologyFace: triFace.map { infos[Int($0)].id },
                            faces: infos, edges: edges, maximumSurfaceDeviation: 0)
    }

    private static func surface(_ f: CSGFace) -> SurfaceDescriptor {
        switch f.surface {
        case let .plane(o, n): .plane(origin: o, normal: f.flipped ? -n : n)
        case .cylinder: f.surface
        }
    }

    private static func smoothNormal(_ f: CSGFace, at p: Vec3) -> Vec3? {
        guard case let .cylinder(o, axis, _) = f.surface else { return nil }
        let d = p - o
        let radial = (d - axis * d.dot(axis)).normalized
        return f.flipped ? -radial : radial
    }

    /// Edges between triangles of different faces, chained into polylines per face pair.
    private static func boundaryEdges(mesh: Mesh, triangleFace: [Int], faces: [FaceInfo], bodyID: UUID) -> [EdgeInfo] {
        struct Key: Hashable { let a: UInt32, b: UInt32 }
        var owners: [Key: [Int]] = [:]
        for t in 0..<mesh.triangleCount {
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                owners[Key(a: min(a, b), b: max(a, b)), default: []].append(t)
            }
        }
        var byPair: [[Int]: [(UInt32, UInt32)]] = [:]
        for (k, ts) in owners {
            let fs = Set(ts.map { triangleFace[$0] })
            guard fs.count > 1 else { continue }
            // Coplanar faces from different features (e.g. a rib joined flush with a plate) read
            // as one surface: no visible edge between them.
            if fs.count == 2, case let .plane(o1, n1)? = faces[safe: fs.first!]?.surface,
               case let .plane(o2, n2)? = faces[safe: fs.dropFirst().first!]?.surface,
               n1.dot(n2) > 1 - 1e-9, abs((o2 - o1).dot(n1)) < 1e-6 { continue }
            byPair[fs.sorted(), default: []].append((k.a, k.b))
        }
        var edges: [EdgeInfo] = []
        for (pair, segments) in byPair.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            for (n, chain) in chains(segments).enumerated() {
                let ids = pair.map { faces[$0].id }
                let id = EdgeID(rawValue: ids.map(\.rawValue).joined(separator: "|") + "#\(n)")
                edges.append(EdgeInfo(id: id, polyline: chain.map { mesh.vertices[Int($0)] }, isSharp: true,
                                      faces: ids, topologyEdgeIDs: []))
            }
        }
        return edges
    }

    /// Orders segments into connected polylines (closed loops repeat the first point).
    private static func chains(_ segments: [(UInt32, UInt32)]) -> [[UInt32]] {
        var adjacency: [UInt32: [UInt32]] = [:]
        for (a, b) in segments { adjacency[a, default: []].append(b); adjacency[b, default: []].append(a) }
        var used = Set<[UInt32]>()
        func mark(_ a: UInt32, _ b: UInt32) { used.insert([min(a, b), max(a, b)]) }
        func isUsed(_ a: UInt32, _ b: UInt32) -> Bool { used.contains([min(a, b), max(a, b)]) }
        var out: [[UInt32]] = []
        // Start from chain ends first (open chains), then remaining loops.
        let starts = adjacency.keys.sorted { (adjacency[$0]!.count == 1 ? 0 : 1, $0) < (adjacency[$1]!.count == 1 ? 0 : 1, $1) }
        for s in starts {
            for n in adjacency[s]! where !isUsed(s, n) {
                var chain = [s, n]; mark(s, n)
                var cur = n
                while let next = adjacency[cur]?.first(where: { !isUsed(cur, $0) }) {
                    chain.append(next); mark(cur, next); cur = next
                }
                out.append(chain)
            }
        }
        return out
    }

    private static func bounds(_ s: BodySnapshot) -> BoundingBox? {
        guard var lo = s.positions.first else { return nil }
        var hi = lo
        for p in s.positions {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return BoundingBox(min: lo, max: hi)
    }

    private static func overlaps(_ a: BoundingBox?, _ b: BoundingBox?) -> Bool {
        guard let a, let b else { return false }
        let e = 1e-6
        return a.min.x <= b.max.x + e && b.min.x <= a.max.x + e && a.min.y <= b.max.y + e
            && b.min.y <= a.max.y + e && a.min.z <= b.max.z + e && b.min.z <= a.max.z + e
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
