import CADCore
import MetalKit
import simd

/// Draws grid, axes and bodies. GPU buffers are cached per feature and rebuilt
/// only when that feature changes.
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
        var mesh: Mesh
        var triangles: MTLBuffer?
        var triangleVertexCount: Int
        var edges: MTLBuffer?
        var edgeVertexCount: Int
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

    func update(features: [Feature]) {
        order = features.map(\.id)
        let alive = Set(order)
        bodies = bodies.filter { alive.contains($0.key) }
        for f in features where bodies[f.id]?.feature != f {
            bodies[f.id] = makeBody(f)
        }
    }

    /// Bounds of the visible bodies (for Fit / Home).
    var sceneBounds: BoundingBox? {
        let boxes = order.compactMap { bodies[$0] }.filter(\.feature.isVisible).compactMap(\.mesh.bounds)
        guard var b = boxes.first else { return nil }
        for o in boxes.dropFirst() {
            b.min = Vec3(min(b.min.x, o.min.x), min(b.min.y, o.min.y), min(b.min.z, o.min.z))
            b.max = Vec3(max(b.max.x, o.max.x), max(b.max.y, o.max.y), max(b.max.z, o.max.z))
        }
        return b
    }

    var visibleBodies: [Body] { order.compactMap { bodies[$0] }.filter(\.feature.isVisible) }

    private func makeBody(_ f: Feature) -> Body {
        let mesh = f.buildMesh()
        var tris: [MeshVertex] = []
        tris.reserveCapacity(mesh.triangleCount * 3)
        for i in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(i)
            let n = mesh.normal(ofTriangle: i)
            let nn = SIMD4(Float(n.x), Float(n.y), Float(n.z), 0)
            for v in [a, b, c] { tris.append(MeshVertex(position: SIMD4(Float(v.x), Float(v.y), Float(v.z), 1), normal: nn)) }
        }
        let edges = featureEdges(mesh)
        return Body(feature: f, mesh: mesh, triangles: buffer(tris), triangleVertexCount: tris.count,
                    edges: buffer(edges), edgeVertexCount: edges.count)
    }

    /// Crease edges (dihedral angle > 25°) and open boundaries: the CAD "edge" look.
    private func featureEdges(_ mesh: Mesh) -> [LineVertex] {
        struct Key: Hashable { let a: Vec3; let b: Vec3 }
        var faces: [Key: [Vec3]] = [:]
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let n = mesh.normal(ofTriangle: t)
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let k = (p.x, p.y, p.z) < (q.x, q.y, q.z) ? Key(a: p, b: q) : Key(a: q, b: p)
                faces[k, default: []].append(n)
            }
        }
        let color = SIMD4<Float>(0.05, 0.06, 0.08, 1)
        var out: [LineVertex] = []
        for (k, normals) in faces where normals.count != 2 || normals[0].dot(normals[1]) < cos(25 * .pi / 180) {
            out.append(LineVertex(position: SIMD4(Float(k.a.x), Float(k.a.y), Float(k.a.z), 1), color: color))
            out.append(LineVertex(position: SIMD4(Float(k.b.x), Float(k.b.y), Float(k.b.z), 1), color: color))
        }
        return out
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
                var draw = DrawUniforms(color: color(for: b.feature.id))
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.triangleVertexCount)
            }
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if style != .shaded {
            enc.setRenderPipelineState(edgePipeline)
            enc.setDepthStencilState(depthReadOnly)
            for b in bodies {
                guard let buf = b.edges else { continue }
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
        if !overlayLines.isEmpty {
            let v = overlayLines.flatMap { [LineVertex(position: SIMD4($0.0, 1), color: $0.2), LineVertex(position: SIMD4($0.1, 1), color: $0.2)] }
            if let buf = buffer(v) {
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

    private func color(for id: Feature.ID) -> SIMD4<Float> {
        if id == selection { return SIMD4(Theme.Palette.bodySelected, 0.6) }
        if id == hovered { return SIMD4(Theme.Palette.bodyHover, 0.25) }
        return SIMD4(Theme.Palette.body, 0)
    }
}
