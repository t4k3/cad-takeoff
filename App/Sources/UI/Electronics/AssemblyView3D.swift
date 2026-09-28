import AppKit
import CADCore
import ElectronicsCore
import RealityKit
import SwiftUI

// MARK: 3D

/// The assembled board in 3D: the same orbit as the CAD viewport (drag, ⇧-drag pans, pinch
/// zooms), a click picks a component (the same selection as the list and the 2D view).
struct AssemblyView3D: View {
    @Environment(CircuitModel.self) private var circuits
    @State private var camera = CameraController()
    @State private var scene = AssemblyScene()
    @State private var art: (id: UUID, value: CAMDrawing)?
    @State private var framed: UUID?
    @State private var last: CGSize?
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        if let state = circuits.assembly, let package = circuits.manufacturing {
            // Read here, in the body: dependencies of the view (T110).
            let pose = camera.pose
            let selection = circuits.camSelection, showExcluded = circuits.showExcluded
            let draft = circuits.alignDraft?.preview
            let picture = art?.id == package.id ? art?.value : nil
            GeometryReader { geo in
                RealityView { content in
                    content.camera = .virtual
                    content.add(scene.root)
                    content.add(scene.cameraEntity)
                } update: { _ in
                    _ = pose
                    scene.update(state, package: package, art: picture, selection: selection, showExcluded: showExcluded, draft: draft)
                    scene.place(eye: camera.eye, target: camera.pose.target, up: camera.basis.up)
                }
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        let previous = last ?? .zero
                        let dx = Float(g.translation.width - previous.width), dy = Float(g.translation.height - previous.height)
                        last = g.translation
                        if NSEvent.modifierFlags.contains(.shift) { camera.pan(dx: dx, dy: dy, viewHeight: Float(geo.size.height)) }
                        else { camera.orbit(dx: dx, dy: dy) }
                    }
                    .onEnded { _ in last = nil })
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    let ray = camera.ray(at: tap.location, in: geo.size)
                    let visible = { (id: UUID) in state.snapshot.instances.first { $0.id == id }.map { $0.fitted || showExcluded } ?? false }
                    circuits.camSelection = scene.mesh?.pick(origin: ray.origin, direction: ray.direction, visible: visible)
                })
                .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in camera.zoom(factor: Float(1 / v.magnification), towards: nil, in: geo.size) })
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        Button { camera.zoom(factor: 1.3, towards: nil, in: geo.size) } label: { Image(systemName: "minus.magnifyingglass") }
                        Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Adatta la scheda alla vista")
                        Button { camera.zoom(factor: 1 / 1.3, towards: nil, in: geo.size) } label: { Image(systemName: "plus.magnifyingglass") }
                    }
                    .buttonStyle(.bordered).padding(12)
                }
                .overlay(alignment: .topLeading) { thicknessNote(state.snapshot).padding(12) }
            }
            .task(id: package.id) {
                if art?.id != package.id { art = (package.id, CAMDrawing(package)) }
                if framed != package.id { framed = package.id; fit(immediate: true) }
            }
        } else if let failure = circuits.assemblyFailure {
            ContentUnavailableView("Scheda assemblata non disponibile", systemImage: "exclamationmark.triangle", description: Text(failure))
        } else {
            ProgressView("Preparo la scheda assemblata…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fit(immediate: Bool = false) {
        guard let mesh = scene.mesh ?? circuits.assembly.map({ AssemblyMesh($0.snapshot, outline: circuits.manufacturing!.bounds) }) else { return }
        let b = BoundingBox(min: Vec3(Double(mesh.minimum.x), Double(mesh.minimum.y), Double(mesh.minimum.z)),
                            max: Vec3(Double(mesh.maximum.x), Double(mesh.maximum.y), Double(mesh.maximum.z)))
        camera.fit(b)
    }

    @ViewBuilder private func thicknessNote(_ s: ManufacturingAssemblySnapshot) -> some View {
        if s.isBoardThicknessAssumed {
            Label("Spessore stimato 1,6 mm", systemImage: "ruler").font(.caption)
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .help("I Gerber non dicono lo spessore: impostalo nel pannello a destra")
        }
    }
}
