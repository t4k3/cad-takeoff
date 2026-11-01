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
    private struct FrameUniforms { var viewProjection: simd_float4x4; var eye: SIMD4<Float>; var lightDir: SIMD4<Float>; var clip: SIMD4<Float> }
    private struct DrawUniforms { var color: SIMD4<Float> }
    private struct TextInstance { var origin: SIMD2<Float>; var size: SIMD2<Float>; var uv: SIMD4<Float>; var color: SIMD4<Float> }
    private struct LabelBackgroundInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var fill: SIMD4<Float>
        var border: SIMD4<Float>
        var params: SIMD4<Float>
    }
    private struct PickUniforms { var viewProjection: simd_float4x4; var rayOrigin: SIMD4<Float>; var rayDirection: SIMD4<Float> }
    private struct PickDraw { var feature: UInt32 }

    /// Nearest surface under a ray, found by the GPU (identity pass, T148).
    struct PickHit {
        var featureID: Feature.ID
        var triangle: Int
        var distance: Float
        var point: SIMD3<Float>
    }

    /// An on-canvas label: a constraint symbol or a dimension value, drawn by the renderer
    /// through the text atlas (screen points, top-left origin, centre of the box).
    struct Label {
        var text: String
        var center: CGPoint
        var style: LabelText.Style
        var textColor: SIMD4<Float>
        var fill: SIMD4<Float>
        var border: SIMD4<Float>
        /// Reference dimensions: dashed border.
        var dashed: Bool
    }

    /// CPU-writable buffer reused frame after frame. Three slots rotate, so the GPU still reading
    /// the previous frames never sees the CPU overwrite its vertices (no allocation per frame).
    private final class BufferRing {
        private struct Slot {
            var buffer: MTLBuffer?
            var capacity = 0
        }
        private let device: MTLDevice
        private var slots = [Slot(), Slot(), Slot()]
        private var next = 0

        init(device: MTLDevice) { self.device = device }

        func write<T>(_ items: [T]) -> (buffer: MTLBuffer, count: Int)? {
            guard !items.isEmpty else { return nil }
            let i = next
            next = (next + 1) % slots.count
            let bytes = items.count * MemoryLayout<T>.stride
            if slots[i].buffer == nil || slots[i].capacity < bytes {
                slots[i].capacity = max(bytes, 4 * bytes, 256)
                slots[i].buffer = device.makeBuffer(length: slots[i].capacity, options: .storageModeShared)
            }
            guard let b = slots[i].buffer else { return nil }
            items.withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            return (b, items.count)
        }
    }


    let camera: CameraController
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let thickPipeline: MTLRenderPipelineState
    private let gizmoPipeline: MTLRenderPipelineState
    private let labelTextPipeline: MTLRenderPipelineState
    private let labelBackgroundPipeline: MTLRenderPipelineState
    private let pickPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthReadOnly: MTLDepthStencilState
    /// Overlays (sketch) are always visible, even behind bodies.
    private let depthAlways: MTLDepthStencilState
    private var grid: (buffer: MTLBuffer, count: Int)?
    /// Vertex data that changes every frame (highlights, sketch overlays, gizmos). One ring per
    /// draw call site, so two calls in the same frame never share a buffer.
    private let highlightTriangleBuffers: BufferRing
    private let highlightLineBuffers: BufferRing
    private let overlayLineBuffers: BufferRing
    private let gizmoBuffers: BufferRing
    private let labelTextBuffers: BufferRing
    private let labelBackgroundBuffers: BufferRing
    /// Rasterized runs shared by every label (one texture, no SwiftUI Text per label).
    private let labelAtlas: TextAtlas

    private(set) var bodies: [Feature.ID: Body] = [:]
    private var order: [Feature.ID] = []
    /// 1×1 identity pass for picking (T148), and the pick-only vertex buffers of bodies that
    /// have no drawing buffer (the pre-command reference bodies).
    private var pickTargets: (ids: MTLTexture, distance: MTLTexture, depth: MTLTexture)?
    private var pickMeshes: [Feature.ID: (revision: String, buffer: MTLBuffer, count: Int)] = [:]
    var selection: Feature.ID?
    var hovered: Feature.ID?
    var style: DisplayStyle = .shadedEdges
    /// Extra line geometry drawn on top (sketch preview, print bed…), in world mm.
    var overlayLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    /// Face/edge highlights (depth-tested, pulled slightly towards the camera).
    var highlightTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    var highlightLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    /// Solid on-canvas handles (drag arrows): triangles as (position, normal), one colour each.
    var gizmos: [GizmoMesh] = []
    /// Section plane (Ispeziona › Sezione): bodies with dot(p, xyz) > w are cut away; zero = off.
    var section: SIMD4<Float> = .zero
    /// On-canvas labels for the frame (sketch constraints and dimensions). Asked again at every
    /// draw, so they follow the camera without a SwiftUI pass per label.
    var labelProvider: (@MainActor () -> [Label])?

    private weak var view: MTKView?

    /// Wakes the (paused) render loop, e.g. after a camera animation starts.
    func requestRedraw() {
        view?.needsDisplay = true
    }

    init?(view: MTKView, camera: CameraController) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let atlas = TextAtlas(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.camera = camera
        self.labelAtlas = atlas
        self.highlightTriangleBuffers = BufferRing(device: device)
        self.highlightLineBuffers = BufferRing(device: device)
        self.overlayLineBuffers = BufferRing(device: device)
        self.gizmoBuffers = BufferRing(device: device)
        self.labelTextBuffers = BufferRing(device: device)
        self.labelBackgroundBuffers = BufferRing(device: device)

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
              let edge = pipeline("lineVertex", "edgeFragment", blend: true),
              let gizmo = pipeline("gizmoVertex", "meshFragment", blend: false),
              let thick = pipeline("thickLineVertex", "edgeFragment", blend: true),
              let labelText = pipeline("textVertex", "textFragment", blend: true),
              let labelBackground = pipeline("labelBackgroundVertex", "labelBackgroundFragment", blend: true) else { return nil }
        meshPipeline = mesh; linePipeline = line; edgePipeline = edge; gizmoPipeline = gizmo; thickPipeline = thick
        labelTextPipeline = labelText; labelBackgroundPipeline = labelBackground

        // Picking draws one pixel to a small identity target (no MSAA, no blending): the colour
        // attachments carry the body/triangle index and the ray parameter, the depth buffer
        // decides which surface is in front.
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "pickVertex")
        pd.fragmentFunction = library.makeFunction(name: "pickFragment")
        pd.colorAttachments[0].pixelFormat = .rgba32Uint
        pd.colorAttachments[1].pixelFormat = .r32Float
        pd.depthAttachmentPixelFormat = .depth32Float
        pd.rasterSampleCount = 1
        guard let pick = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        pickPipeline = pick

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

    private func meshVertices(_ snap: BodySnapshot) -> [MeshVertex] {
        func v4(_ v: Vec3, _ w: Float) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), w) }
        return snap.triangles.map { i in
            MeshVertex(position: v4(snap.positions[Int(i)], 1), normal: v4(snap.normals[Int(i)], 0))
        }
    }

    private func makeBody(_ f: Feature, _ snap: BodySnapshot) -> Body {
        func v4(_ v: Vec3, _ w: Float) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), w) }
        let tris = meshVertices(snap)
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

    // MARK: Picking (T148)

    /// Nearest surface under a ray: one pixel of an identity pass drawn with only depth, then
    /// read back. Works on any body list (also the reference bodies used while a command preview
    /// is on), so hover and clicks never scan triangles on the CPU.
    func pick(_ ray: Ray, in bodies: [Body]) -> PickHit? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0, !bodies.isEmpty else { return nil }
        let targets: (ids: MTLTexture, distance: MTLTexture, depth: MTLTexture)
        if let pickTargets { targets = pickTargets } else if let made = makePickTargets() { targets = made } else { return nil }
        let aspect = Float(view.bounds.width / view.bounds.height)
        let ndc = camera.ndc(of: ray, aspect: aspect)
        // Translation in clip space: the click ray becomes the centre of the 1×1 target.
        let shift = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                           SIMD4(-ndc.x, -ndc.y, 0, 1)))
        var uniforms = PickUniforms(viewProjection: shift * camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
                                    rayOrigin: SIMD4(ray.origin, 0),
                                    rayDirection: SIMD4(simd_normalize(ray.direction), 0))
        guard let command = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.ids
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = targets.distance
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[1].storeAction = .store
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pickPipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<PickUniforms>.stride, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<PickUniforms>.stride, index: 1)
        for (i, body) in bodies.enumerated() {
            guard let (buf, count) = pickVertices(of: body) else { continue }
            var draw = PickDraw(feature: UInt32(i))
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setFragmentBytes(&draw, length: MemoryLayout<PickDraw>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        enc.endEncoding()
        command.commit()
        command.waitUntilCompleted()

        var ids = SIMD4<UInt32>(repeating: 0)
        targets.ids.getBytes(&ids, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        guard ids.z != 0, Int(ids.x) < bodies.count else { return nil }
        var distance: Float = 0
        targets.distance.getBytes(&distance, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // Past the camera (orthographic rays can see behind it): not a hit.
        guard distance > 1e-4 else { return nil }
        let body = bodies[Int(ids.x)]
        guard Int(ids.y) < body.snapshot.triangles.count / 3 else { return nil }
        return PickHit(featureID: body.feature.id, triangle: Int(ids.y), distance: distance,
                       point: ray.origin + simd_normalize(ray.direction) * distance)
    }

    /// The drawing buffer of a body, or one built (and cached) from its snapshot for the
    /// reference bodies, which the renderer itself never draws.
    private func pickVertices(of body: Body) -> (MTLBuffer, Int)? {
        if let buf = body.triangles { return (buf, body.triangleVertexCount) }
        if let c = pickMeshes[body.feature.id], c.revision == body.snapshot.revision { return (c.buffer, c.count) }
        let v = meshVertices(body.snapshot)
        guard let buf = buffer(v) else { return nil }
        pickMeshes[body.feature.id] = (body.snapshot.revision, buf, v.count)
        return (buf, v.count)
    }

    private func makePickTargets() -> (ids: MTLTexture, distance: MTLTexture, depth: MTLTexture)? {
        func texture(_ format: MTLPixelFormat, _ storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        guard let ids = texture(.rgba32Uint, .shared),
              let distance = texture(.r32Float, .shared),
              let depth = texture(.depth32Float, .private) else { return nil }
        let targets = (ids, distance, depth)
        pickTargets = targets
        return targets
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
        let right = camera.basis.right
        let light = simd_normalize(-camera.forward + right * 0.5 + SIMD3(0, 0, 0.8))
        var frame = FrameUniforms(viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
                                  eye: SIMD4(eye, camera.pose.distance * 3 + 150), lightDir: SIMD4(light, 0), clip: section)
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
            if !highlightTriangles.isEmpty {
                let tris = highlightTriangles.flatMap { [LineVertex(position: SIMD4($0.0, 1), color: $0.3),
                                                          LineVertex(position: SIMD4($0.1, 1), color: $0.3),
                                                          LineVertex(position: SIMD4($0.2, 1), color: $0.3)] }
                if let (buf, count) = highlightTriangleBuffers.write(tris) {
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
                }
            }
            drawThick(highlightLines, width: 2, view: view, encoder: enc, buffers: highlightLineBuffers)   // the colour marks it, not the width
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if !overlayLines.isEmpty {
            var none = DrawUniforms(color: .zero)
            enc.setFragmentBytes(&none, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setDepthStencilState(depthAlways)
            drawThick(overlayLines, width: 1.5, view: view, encoder: enc, buffers: overlayLineBuffers)
        }
        if !gizmos.isEmpty {
            enc.setRenderPipelineState(gizmoPipeline)
            enc.setDepthStencilState(depthWrite)
            // All handles in one buffer, drawn one range at a time (the colour changes per handle).
            var v: [MeshVertex] = []
            var ranges: [(offset: Int, count: Int, color: SIMD4<Float>)] = []
            for g in gizmos {
                let start = v.count
                for (p, n) in g.vertices { v.append(MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n, 0))) }
                ranges.append((start, v.count - start, g.color))
            }
            if let (buf, _) = gizmoBuffers.write(v) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                for r in ranges where r.count > 0 {
                    var draw = DrawUniforms(color: r.color)
                    enc.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: r.offset, vertexCount: r.count)
                }
            }
        }
        if let labels = labelProvider?(), !labels.isEmpty {
            drawLabels(labels, view: view, encoder: enc)
        }
        enc.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private struct ThickVertex { var position: SIMD4<Float>; var other: SIMD4<Float>; var color: SIMD4<Float>; var params: SIMD4<Float> }

    /// On-canvas labels over the whole scene: a rounded box per label (antialiased border, dashed
    /// for reference dimensions) and a quad per run sampled from the shared text atlas, both in
    /// screen points with the origin at the top-left.
    private func drawLabels(_ labels: [Label], view: MTKView, encoder enc: MTLRenderCommandEncoder) {
        let scale = view.drawableSize.width / max(view.bounds.width, 1)
        var boxes: [LabelBackgroundInstance] = [], runs: [TextInstance] = []
        boxes.reserveCapacity(labels.count)
        runs.reserveCapacity(labels.count)
        for label in labels {
            let box = LabelText.boxSize(label.text, label.style)
            let origin = SIMD2<Float>(Float(label.center.x - box.width / 2), Float(label.center.y - box.height / 2))
            boxes.append(LabelBackgroundInstance(origin: origin,
                                                 size: SIMD2(Float(box.width), Float(box.height)),
                                                 fill: label.fill, border: label.border,
                                                 params: SIMD4(label.style.cornerRadius, 1, label.dashed ? 4.5 : 0, 0)))
            guard let q = labelAtlas.quad(label.text, style: label.style, center: label.center,
                                          color: label.textColor, scale: scale) else { continue }
            runs.append(TextInstance(origin: q.origin, size: q.size, uv: q.uv, color: q.color))
        }
        var viewport = SIMD2<Float>(Float(max(view.bounds.width, 1)), Float(max(view.bounds.height, 1)))
        enc.setDepthStencilState(depthAlways)
        if let (buf, count) = labelBackgroundBuffers.write(boxes) {
            enc.setRenderPipelineState(labelBackgroundPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        if let (buf, count) = labelTextBuffers.write(runs), let texture = labelAtlas.metalTexture {
            enc.setRenderPipelineState(labelTextPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
    }

    /// Lines `width` points wide (screen space), as two triangles per segment.
    private func drawThick(_ lines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)], width: Float, view: MTKView,
                           encoder enc: MTLRenderCommandEncoder, buffers: BufferRing) {
        guard !lines.isEmpty else { return }
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let px = width * scale
        var v: [ThickVertex] = []
        v.reserveCapacity(lines.count * 6)
        for (a, b, c) in lines {
            let pa = SIMD4(a, 1), pb = SIMD4(b, 1)
            func at(_ p: SIMD4<Float>, _ o: SIMD4<Float>, _ side: Float) -> ThickVertex {
                ThickVertex(position: p, other: o, color: c, params: SIMD4(side, px, 0, 0))
            }
            // At B the direction is reversed: its side −1 is A's side +1.
            v += [at(pa, pb, 1), at(pa, pb, -1), at(pb, pa, -1), at(pa, pb, -1), at(pb, pa, 1), at(pb, pa, -1)]
        }
        guard let (buf, count) = buffers.write(v) else { return }
        var viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        enc.setRenderPipelineState(thickPipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
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
        // Selected: tinted towards the accent with a strong rim, clearly apart from the rest.
        if f.id == selection { return SIMD4(simd_mix(base, Theme.Palette.bodySelected, SIMD3(repeating: 0.45)), 0.9) }
        if f.id == hovered { return SIMD4(simd_mix(base, Theme.Palette.bodySelected, SIMD3(repeating: 0.15)), 0.45) }
        return SIMD4(base, 0)
    }
}

/// A solid handle drawn over the scene (see `gizmoVertex`).
struct GizmoMesh {
    var vertices: [(SIMD3<Float>, SIMD3<Float>)]
    /// rgb + rim strength.
    var color: SIMD4<Float>
}
