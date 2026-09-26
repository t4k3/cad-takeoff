import CADCore
import MetalKit
import simd

/// Draws grid, axes and bodies. Bodies come from the kernel snapshot (B-rep faces/edges
/// with stable IDs, T76); GPU buffers are cached per feature and rebuilt only when it changes.
@MainActor
final class ViewportRenderer: NSObject, MTKViewDelegate {
    enum DisplayStyle: String, CaseIterable, Identifiable {
        case shadedEdges = "Ombreggiato con spigoli"
        case shaded = "Ombreggiato"
        case wireframe = "Fil di ferro"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .shadedEdges: "cube.fill"
            case .shaded: "circle.lefthalf.filled"
            case .wireframe: "cube"
            }
        }
    }

    struct Body {
        var feature: Feature
        var snapshot: BodySnapshot
        var triangles: MTLBuffer?
        var triangleVertexCount: Int
        var edges: MTLBuffer?
        var edgeVertexCount: Int
        var bounds: BoundingBox?

        var triangleCount: Int { snapshot.triangles.count / 3 }
        func triangle(_ i: Int) -> (Vec3, Vec3, Vec3) {
            let t = snapshot.triangles, p = snapshot.positions
            return (p[Int(t[i * 3])], p[Int(t[i * 3 + 1])], p[Int(t[i * 3 + 2])])
        }
        /// Selection face of a triangle (stable FaceID from the kernel).
        func face(ofTriangle i: Int) -> FaceInfo? {
            guard i < snapshot.triangleFace.count else { return nil }
            let f = Int(snapshot.triangleFace[i])
            return f < snapshot.faces.count ? snapshot.faces[f] : nil
        }
        func face(_ id: FaceID) -> FaceInfo? { snapshot.faces.first { $0.id == id } }
        func edge(_ id: EdgeID) -> EdgeInfo? { snapshot.edges.first { $0.id == id } }
        func triangles(of face: FaceID) -> [Int] {
            guard let f = snapshot.faces.firstIndex(where: { $0.id == face }) else { return [] }
            return snapshot.triangleFace.indices.filter { Int(snapshot.triangleFace[$0]) == f }
        }
    }

    private struct MeshVertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }
    private struct LineVertex { var position: SIMD4<Float>; var color: SIMD4<Float> }
    private struct FrameUniforms { var viewProjection: simd_float4x4; var eye: SIMD4<Float>; var lightDir: SIMD4<Float> }
    private struct DrawUniforms { var color: SIMD4<Float> }

    let camera: CameraController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthReadOnly: MTLDepthStencilState
    /// Overlays (sketch) are always visible, even behind bodies.
    private let depthAlways: MTLDepthStencilState
    private var grid: (buffer: MTLBuffer, count: Int)?

    private(set) var bodies: [Feature.ID: Body] = [:]
    private var order: [Feature.ID] = []
    var selection: Feature.ID?
    var hovered: Feature.ID?
    var style: DisplayStyle = .shadedEdges
    /// Extra line geometry drawn on top (sketch preview, print bed…), in world mm.
    var overlayLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    /// Face/edge highlights (depth-tested, pulled slightly towards the camera).
    var highlightTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    var highlightLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []

    private weak var view: MTKView?

    /// Wakes the (paused) render loop, e.g. after a camera animation starts.
    func requestRedraw() {
        view?.needsDisplay = true
    }

    init?(view: MTKView, camera: CameraController) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.code, options: nil) else { return nil }
        self.device = device
        self.queue = queue
        self.camera = camera

        func pipeline(_ vertex: String, _ fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let mesh = pipeline("meshVertex", "meshFragment", blend: false),
              let line = pipeline("lineVertex", "lineFragment", blend: true),
              let edge = pipeline("lineVertex", "edgeFragment", blend: true) else { return nil }
        meshPipeline = mesh; linePipeline = line; edgePipeline = edge

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .lessEqual
        dr.isDepthWriteEnabled = false
        let da = MTLDepthStencilDescriptor()
        da.depthCompareFunction = .always
        da.isDepthWriteEnabled = false
        guard let w = device.makeDepthStencilState(descriptor: dw),
              let r = device.makeDepthStencilState(descriptor: dr),
              let a = device.makeDepthStencilState(descriptor: da) else { return nil }
        depthWrite = w; depthReadOnly = r; depthAlways = a
        super.init()
        self.view = view
        camera.onAnimationFrame = { [weak self] in self?.requestRedraw() }
        grid = makeGrid(extent: 200, step: 10, major: 50)
    }

    // MARK: Scene updates

    /// Bodies = the snapshot's valid bodies (hidden and invalid features are absent).
    func update(features: [Feature], snapshot: DesignSnapshot) {
        let byID = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Feature.ID: Body] = [:]
        order = []
        for body in snapshot.bodies {
            guard let f = byID[body.bodyID] else { continue }
            order.append(f.id)
            if var cached = bodies[f.id], cached.feature == f, cached.snapshot.positions == body.positions,
               cached.snapshot.triangles == body.triangles {
                cached.snapshot = body          // same geometry, newer revision
                next[f.id] = cached
            } else {
                next[f.id] = makeBody(f, body)
            }
        }
        bodies = next
    }

    /// Bounds of the visible bodies (for Fit / Home).
    var sceneBounds: BoundingBox? {
        let boxes = order.compactMap { bodies[$0] }.compactMap(\.bounds)
        guard var b = boxes.first else { return nil }
        for o in boxes.dropFirst() {
            b.min = Vec3(min(b.min.x, o.min.x), min(b.min.y, o.min.y), min(b.min.z, o.min.z))
            b.max = Vec3(max(b.max.x, o.max.x), max(b.max.y, o.max.y), max(b.max.z, o.max.z))
        }
        return b
    }

    var visibleBodies: [Body] { order.compactMap { bodies[$0] } }

    private func makeBody(_ f: Feature, _ snap: BodySnapshot) -> Body {
        func v4(_ v: Vec3, _ w: Float) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), w) }
        let tris = snap.triangles.map { i in
            MeshVertex(position: v4(snap.positions[Int(i)], 1), normal: v4(snap.normals[Int(i)], 0))
        }
        // Real B-rep edges only (no tessellation lines on curved faces).
        let color = SIMD4<Float>(0.05, 0.06, 0.08, 1)
        var lines: [LineVertex] = []
        for e in snap.edges {
            for (a, b) in zip(e.polyline, e.polyline.dropFirst()) {
                lines.append(LineVertex(position: v4(a, 1), color: color))
                lines.append(LineVertex(position: v4(b, 1), color: color))
            }
        }
        var bounds: BoundingBox?
        if let first = snap.positions.first {
            var lo = first, hi = first
            for p in snap.positions {
                lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
            }
            bounds = BoundingBox(min: lo, max: hi)
        }
        return Body(feature: f, snapshot: snap, triangles: buffer(tris), triangleVertexCount: tris.count,
                    edges: buffer(lines), edgeVertexCount: lines.count, bounds: bounds)
    }

    private func makeGrid(extent: Float, step: Float, major: Float) -> (MTLBuffer, Int)? {
        var v: [LineVertex] = []
        let minor = SIMD4<Float>(0.5, 0.55, 0.6, 0.22), majorC = SIMD4<Float>(0.5, 0.55, 0.6, 0.5)
        var t = -extent
        while t <= extent + 0.001 {
            let c = abs(t.truncatingRemainder(dividingBy: major)) < 0.001 ? majorC : minor
            if abs(t) > 0.001 {
                v += [LineVertex(position: SIMD4(t, -extent, 0, 1), color: c), LineVertex(position: SIMD4(t, extent, 0, 1), color: c)]
                v += [LineVertex(position: SIMD4(-extent, t, 0, 1), color: c), LineVertex(position: SIMD4(extent, t, 0, 1), color: c)]
            }
            t += step
        }
        // Axes: X red, Y green (full length), Z blue (up only).
        let red = SIMD4<Float>(0.92, 0.3, 0.3, 0.9), green = SIMD4<Float>(0.35, 0.8, 0.35, 0.9), blue = SIMD4<Float>(0.35, 0.55, 1, 0.9)
        v += [LineVertex(position: SIMD4(-extent, 0, 0, 1), color: red), LineVertex(position: SIMD4(extent, 0, 0, 1), color: red)]
        v += [LineVertex(position: SIMD4(0, -extent, 0, 1), color: green), LineVertex(position: SIMD4(0, extent, 0, 1), color: green)]
        v += [LineVertex(position: SIMD4(0, 0, 0, 1), color: blue), LineVertex(position: SIMD4(0, 0, extent / 4, 1), color: blue)]
        guard let b = buffer(v) else { return nil }
        return (b, v.count)
    }

    private func buffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }

        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let eye = camera.eye
        let right = simd_normalize(simd_cross(camera.forward, SIMD3(0, 0, 1) + SIMD3(0, 0.001, 0)))
        let light = simd_normalize(-camera.forward + right * 0.5 + SIMD3(0, 0, 0.8))
        var frame = FrameUniforms(viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
                                  eye: SIMD4(eye, camera.pose.distance * 3 + 150), lightDir: SIMD4(light, 0))
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)

        // Bodies first (push fills back slightly so edges win the depth test).
        let bodies = visibleBodies
        if style != .wireframe {
            enc.setRenderPipelineState(meshPipeline)
            enc.setDepthStencilState(depthWrite)
            enc.setDepthBias(1, slopeScale: 1.5, clamp: 0.01)
            for b in bodies {
                guard let buf = b.triangles else { continue }
                var draw = DrawUniforms(color: color(for: b.feature))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.triangleVertexCount)
            }
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if style != .shaded || selection != nil || hovered != nil {
            enc.setRenderPipelineState(edgePipeline)
            enc.setDepthStencilState(depthReadOnly)
            for b in bodies {
                guard let buf = b.edges else { continue }
                if style == .shaded, b.feature.id != selection, b.feature.id != hovered { continue }
                var tint = DrawUniforms(color: edgeTint(for: b.feature.id))
                enc.setFragmentBytes(&tint, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: b.edgeVertexCount)
            }
        }
        // Grid after bodies with depth test: hidden where a body covers it.
        if let grid {
            enc.setRenderPipelineState(linePipeline)
            enc.setDepthStencilState(depthReadOnly)
            enc.setVertexBuffer(grid.buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: grid.count)
        }
        if !highlightTriangles.isEmpty || !highlightLines.isEmpty {
            var none = DrawUniforms(color: .zero)
            enc.setFragmentBytes(&none, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setRenderPipelineState(edgePipeline)
            enc.setDepthStencilState(depthReadOnly)
            enc.setDepthBias(-4, slopeScale: -2, clamp: 0.01)
            let tris = highlightTriangles.flatMap { [LineVertex(position: SIMD4($0.0, 1), color: $0.3),
                                                     LineVertex(position: SIMD4($0.1, 1), color: $0.3),
                                                     LineVertex(position: SIMD4($0.2, 1), color: $0.3)] }
            if let buf = buffer(tris) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: tris.count)
            }
            let lines = highlightLines.flatMap { [LineVertex(position: SIMD4($0.0, 1), color: $0.2),
                                                  LineVertex(position: SIMD4($0.1, 1), color: $0.2)] }
            if let buf = buffer(lines) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
            }
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if !overlayLines.isEmpty {
            let v = overlayLines.flatMap { [LineVertex(position: SIMD4($0.0, 1), color: $0.2), LineVertex(position: SIMD4($0.1, 1), color: $0.2)] }
            if let buf = buffer(v) {
                var none = DrawUniforms(color: .zero)
                enc.setFragmentBytes(&none, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setRenderPipelineState(edgePipeline)
                enc.setDepthStencilState(depthAlways)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: v.count)
            }
        }
        enc.endEncoding()
        command.present(drawable)
        command.commit()
    }

    /// Edge colour override: accent for the selection, light accent on hover, else baked (a = 0).
    private func edgeTint(for id: Feature.ID) -> SIMD4<Float> {
        if id == selection { return SIMD4(Theme.Palette.bodySelected, 1) }
        if id == hovered { return SIMD4(Theme.Palette.bodySelected * 0.8 + 0.2, 0.9) }
        return .zero
    }

    /// True part colour always; selection = strong orange rim + slight lift, hover = soft rim.
    private func color(for f: Feature) -> SIMD4<Float> {
        let base = f.color.simd
        if f.id == selection { return SIMD4(base, 0.5) }
        if f.id == hovered { return SIMD4(simd_mix(base, SIMD3(repeating: 1), SIMD3(repeating: 0.2)), 0.3) }
        return SIMD4(base, 0)
    }
}
