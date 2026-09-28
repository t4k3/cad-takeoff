import AppKit
import ElectronicsCore
import RealityKit
import SwiftUI

/// The entities of the assembled board, rebuilt when the assembly changes; selection, excluded
/// parts and the component being aligned only restyle or swap what is there.
@MainActor
final class AssemblyScene {
    let root = Entity()
    let cameraEntity = Entity()
    /// What the entities were built from: the assembly, and whether the board picture was ready
    /// (it can arrive after the assembly: then the board is rebuilt with it, T111).
    private var built: (key: CircuitModel.AssemblyKey, pictured: Bool)?
    private var components: [UUID: [(entity: ModelEntity, look: AssemblyMesh.Look)]] = [:]
    private var draftShown: ManufacturingAssemblyInstance?
    private(set) var mesh: AssemblyMesh?
    private var styled: (UUID?, Bool)?
    private var thickness: Float = 1.6

    init() {
        // Engine frame Z up → RealityKit Y up.
        root.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        cameraEntity.components.set(PerspectiveCameraComponent(near: 0.5, far: 50_000, fieldOfViewInDegrees: 35))
        // A headlight: it shines where the camera looks (a light's −Z, like the camera's), a little
        // from above-left so edges and heights read.
        let sun = DirectionalLight()
        sun.light.intensity = 8000
        sun.orientation = simd_quatf(angle: 0.25, axis: [1, 0, 0]) * simd_quatf(angle: -0.2, axis: [0, 1, 0])
        cameraEntity.addChild(sun)
    }

    static func world(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.z, -v.y) }

    /// The camera where the CAD camera controller says (engine frame, Z up).
    func place(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) {
        cameraEntity.look(at: Self.world(target), from: Self.world(eye), upVector: Self.world(up), relativeTo: nil)
    }

    func update(_ state: CircuitModel.AssemblyState, package: ManufacturingPackage, art: CAMDrawing?,
                selection: UUID?, showExcluded: Bool, draft: ManufacturingAssemblyInstance?) {
        if built.map({ $0.key != state.key || $0.pictured != (art != nil) }) ?? true {
            built = (state.key, art != nil)
            root.children.removeAll()
            components = [:]; draftShown = nil; styled = nil
            thickness = Float(state.snapshot.boardThickness)
            let mesh = AssemblyMesh(state.snapshot, outline: package.bounds)
            self.mesh = mesh
            var pictures: [BoardSide: CGImage] = [:]
            if let art {
                let base = mesh.batches.first { $0.look == .boardTop }?.positions ?? []
                for side in [BoardSide.top, .bottom] { pictures[side] = BoardPicture.render(art, bounds: package.bounds, base: base, side: side) }
            }
            for batch in mesh.batches {
                guard let entity = Self.entity(batch, pictures: pictures) else { continue }
                root.addChild(entity)
                if let id = batch.component { components[id, default: []].append((entity, batch.look)) }
            }
        }
        // The component being aligned: its previewed parts in place of the saved ones.
        if draftShown != draft {
            if let old = draftShown, let saved = state.snapshot.instances.first(where: { $0.id == old.id }) { replace(saved) }
            if let draft { replace(draft) }
            draftShown = draft
            styled = nil
        }
        if styled.map({ $0.0 != selection || $0.1 != showExcluded }) ?? true {
            styled = (selection, showExcluded)
            for instance in state.snapshot.instances {
                for (entity, look) in components[instance.id] ?? [] {
                    entity.isEnabled = instance.fitted || showExcluded
                    if instance.fitted { entity.components.remove(OpacityComponent.self) }
                    else { entity.components.set(OpacityComponent(opacity: 0.3)) }
                    entity.model?.materials = [Self.material(look, selected: instance.id == selection)]
                }
            }
        }
    }

    private func replace(_ instance: ManufacturingAssemblyInstance) {
        for (entity, _) in components[instance.id] ?? [] { entity.removeFromParent() }
        let batches = AssemblyMesh.batches(instance, thickness: thickness)
        mesh?.replace(instance.id, with: batches)
        components[instance.id] = batches.compactMap { batch in
            guard let e = Self.entity(batch, pictures: [:]) else { return nil }
            root.addChild(e)
            return (e, batch.look)
        }
    }

    /// The board's top or bottom face carries the finished-board picture (tests).
    var boardIsPictured: Bool {
        root.children.compactMap { $0 as? ModelEntity }.contains { e in
            (e.model?.materials.first as? SimpleMaterial)?.color.texture != nil
        }
    }

    private static func entity(_ batch: AssemblyMesh.Batch, pictures: [BoardSide: CGImage]) -> ModelEntity? {
        var d = MeshDescriptor(name: "b")
        d.positions = MeshBuffers.Positions(batch.positions)
        d.normals = MeshBuffers.Normals(batch.normals)
        if batch.uvs.count == batch.positions.count { d.textureCoordinates = MeshBuffers.TextureCoordinates(batch.uvs) }
        d.primitives = .triangles((0..<UInt32(batch.positions.count)).map { $0 })
        guard let mesh = try? MeshResource.generate(from: [d]) else { return nil }
        var material: any RealityKit.Material = Self.material(batch.look, selected: false)
        let side: BoardSide? = batch.look == .boardTop ? .top : batch.look == .boardBottom ? .bottom : nil
        if let side, let image = pictures[side], let texture = try? TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
            var m = SimpleMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.roughness = 0.6
            material = m
        }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    static func material(_ look: AssemblyMesh.Look, selected: Bool) -> any RealityKit.Material {
        let colour: NSColor, metal: Bool
        switch look {
        case .boardTop, .boardBottom: colour = NSColor(CAMDrawing.maskGreen); metal = false
        case .boardEdge: colour = NSColor(AssemblyLook.colour(.substrate)); metal = false
        case .part(let m): colour = NSColor(AssemblyLook.colour(m)); metal = m == .metal
        case .missing: return UnlitMaterial(color: .systemRed)
        }
        let tint = selected ? (colour.blended(withFraction: 0.55, of: NSColor(Theme.Palette.accent)) ?? colour) : colour
        return SimpleMaterial(color: tint, roughness: metal ? 0.3 : 0.7, isMetallic: metal)
    }
}
