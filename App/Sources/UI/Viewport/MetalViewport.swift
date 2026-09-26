import CADCore
import MetalKit
import SwiftUI

/// SwiftUI wrapper of the Metal viewport. Pure presentation: reads features and
/// selection, reports clicks/hover through callbacks.
struct MetalViewport: NSViewRepresentable {
    var features: [Feature]
    /// Kernel geometry for these features (same revision).
    var snapshot: DesignSnapshot
    var selection: Feature.ID?
    var hovered: Feature.ID?
    var style: ViewportRenderer.DisplayStyle
    var camera: CameraController
    var overlayLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    var highlightTriangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    var highlightLines: [(SIMD3<Float>, SIMD3<Float>, SIMD4<Float>)] = []
    var gizmos: [GizmoMesh] = []
    var onClick: (CGPoint, Ray, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var onHover: (CGPoint?, Ray?) -> Void = { _, _ in }
    /// Mouse down on a draggable handle: return true to take the drag (no orbit, no click).
    var onDragBegin: (Ray) -> Bool = { _ in false }
    var onDragMove: (Ray) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    /// Single-letter shortcuts, only while the viewport has keyboard focus (never while typing elsewhere).
    var onKey: (String) -> Bool = { _ in false }
    /// Receives the renderer once, so overlays (fit, picking) can query scene data.
    var onReady: (ViewportRenderer) -> Void = { _ in }

    func makeNSView(context: Context) -> CADMetalView {
        let view = CADMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.camera = camera
        if let renderer = ViewportRenderer(view: view, camera: camera) {
            view.renderer = renderer
            view.delegate = renderer
            onReady(renderer)
        }
        return view
    }

    func updateNSView(_ view: CADMetalView, context: Context) {
        view.onClick = onClick
        view.onHover = onHover
        view.onKey = onKey
        view.onDragBegin = onDragBegin
        view.onDragMove = onDragMove
        view.onDragEnd = onDragEnd
        guard let r = view.renderer else { return }
        r.update(features: features, snapshot: snapshot)
        r.selection = selection
        r.hovered = hovered
        r.style = style
        r.overlayLines = overlayLines
        r.highlightTriangles = highlightTriangles
        r.highlightLines = highlightLines
        r.gizmos = gizmos
        view.redraw()
    }
}

/// MTKView with CAD navigation:
/// drag = orbit · shift/right/middle-drag = pan · wheel or pinch = zoom to cursor
/// trackpad two-finger scroll = pan (shift = orbit).
final class CADMetalView: MTKView {
    var camera: CameraController!
    var renderer: ViewportRenderer?
    var onClick: (CGPoint, Ray, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var onHover: (CGPoint?, Ray?) -> Void = { _, _ in }
    var onKey: (String) -> Bool = { _ in false }
    var onDragBegin: (Ray) -> Bool = { _ in false }
    var onDragMove: (Ray) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    private var dragStart: CGPoint?
    private var isDragging = false
    /// A handle took this drag.
    private var handleDrag = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func redraw() {
        needsDisplay = true
    }

    /// Point in view coordinates with origin at the top-left.
    private func topLeft(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = topLeft(event)
        isDragging = false
        handleDrag = onDragBegin(camera.ray(at: dragStart!, in: bounds.size))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = topLeft(event)
        if handleDrag {
            onDragMove(camera.ray(at: p, in: bounds.size))
            return
        }
        if !isDragging, hypot(p.x - start.x, p.y - start.y) < 3 { return }
        isDragging = true
        if event.modifierFlags.contains(.shift) {
            camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        } else {
            camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; isDragging = false; handleDrag = false }
        if handleDrag { onDragEnd(); return }
        guard !isDragging else { return }
        let p = topLeft(event)
        onClick(p, camera.ray(at: p, in: bounds.size), event.modifierFlags)
    }

    override func rightMouseDragged(with event: NSEvent) { panDrag(event) }
    override func otherMouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY)); redraw()
        } else { panDrag(event) }
    }

    private func panDrag(_ event: NSEvent) {
        camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        redraw()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = topLeft(event)
        onHover(p, camera.ray(at: p, in: bounds.size))
    }

    override func mouseExited(with event: NSEvent) { onHover(nil, nil) }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, let chars = event.charactersIgnoringModifiers?.lowercased(), onKey(chars) { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let p = topLeft(event)
        if event.hasPreciseScrollingDeltas {
            // Trackpad: two-finger scroll pans; with shift it orbits.
            if event.modifierFlags.contains(.shift) {
                camera.orbit(dx: Float(-event.scrollingDeltaX), dy: Float(-event.scrollingDeltaY))
            } else {
                camera.pan(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY), viewHeight: Float(bounds.height))
            }
        } else {
            camera.zoom(factor: pow(0.9, Float(event.scrollingDeltaY)), towards: p, in: bounds.size)
        }
        redraw()
    }

    override func magnify(with event: NSEvent) {
        camera.zoom(factor: Float(1 / (1 + event.magnification)), towards: topLeft(event), in: bounds.size)
        redraw()
    }
}
