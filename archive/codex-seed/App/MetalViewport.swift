import SwiftUI
import MetalKit
import simd
import CADCore

struct MetalViewport: NSViewRepresentable {
    let mesh: Mesh
    let resetID: UUID

    final class Coordinator {
        var renderer: MeshRenderer?
        var lastReset: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> OrbitView {
        let view = OrbitView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.055, green: 0.07, blue: 0.095, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        do {
            let renderer = try MeshRenderer(view: view)
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let label = NSTextField(wrappingLabelWithString: "Vista 3D non disponibile: \(error.localizedDescription)")
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
            ])
        }
        return view
    }
    func updateNSView(_ view: OrbitView, context: Context) {
        context.coordinator.renderer?.update(mesh)
        if context.coordinator.lastReset != resetID {
            view.yaw = -.pi / 5; view.pitch = .pi / 3; view.zoom = 0.85
            context.coordinator.lastReset = resetID
        }
        view.needsDisplay = true
    }
}

final class OrbitView: MTKView {
    var yaw: Float = -.pi / 5
    var pitch: Float = .pi / 3
    var zoom: Float = 0.85
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {
        yaw += Float(event.deltaX) * 0.01
        pitch = min(.pi, max(0, pitch + Float(event.deltaY) * 0.01))
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        zoom = min(4, max(0.15, zoom * exp(Float(event.scrollingDeltaY) * 0.01)))
        needsDisplay = true
    }
}

@MainActor
final class MeshRenderer: NSObject, @preconcurrency MTKViewDelegate {
    private struct GPUVertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }
    private struct Uniforms { var mvp: simd_float4x4; var rotation: simd_float4x4 }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var buffer: MTLBuffer?
    private var vertexCount = 0

    init(view: MTKView) throws {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "cadVertex"),
              let fragment = library.makeFunction(name: "cadFragment") else {
            throw CADError.invalid("Metal o shader non disponibili.")
        }
        self.device = device; self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw CADError.invalid("Depth buffer non disponibile.")
        }
        depth = state
        super.init()
    }

    func update(_ mesh: Mesh) {
        guard let first = mesh.vertices.first else { buffer = nil; vertexCount = 0; return }
        var low = SIMD3(first.x, first.y, first.z), high = low
        for p in mesh.vertices { let v = SIMD3(p.x,p.y,p.z); low = simd_min(low,v); high = simd_max(high,v) }
        let center = (low+high)/2, radius = max(simd_length(high-low)/2, 1e-6)
        var vertices: [GPUVertex] = []
        for t in mesh.triangles {
            let a = mesh.vertices[t.a], b = mesh.vertices[t.b], c = mesh.vertices[t.c]
            let n = (b-a).cross(c-a).normalized
            for p in [a,b,c] {
                let v = (SIMD3(p.x,p.y,p.z)-center)/radius
                vertices.append(GPUVertex(position: SIMD4(Float(v.x),Float(v.y),Float(v.z),1),
                                          normal: SIMD4(Float(n.x),Float(n.y),Float(n.z),0)))
            }
        }
        buffer = vertices.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count)
        }
        vertexCount = buffer == nil ? 0 : vertices.count
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let view = view as? OrbitView, let buffer,
              view.drawableSize.height > 0, view.drawableSize.width > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Float(view.drawableSize.width/view.drawableSize.height)
        let rotation = simd_float4x4(simd_quatf(angle: -view.pitch, axis: SIMD3(1,0,0)))
            * simd_float4x4(simd_quatf(angle: view.yaw, axis: SIMD3(0,0,1)))
        // Orthographic CAD view. Negative depth scale places the viewer on positive camera Z.
        let projection = simd_float4x4(columns: (
            SIMD4(view.zoom / max(aspect,1),0,0,0), SIMD4(0,view.zoom * min(aspect,1),0,0),
            SIMD4(0,0,-0.2,0), SIMD4(0,0,0.5,1)))
        var uniforms = Uniforms(mvp: projection * rotation, rotation: rotation)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

