import CADCore
import SceneKit
import SwiftUI

/// 3D viewport. CADCore is Z-up (mm); SceneKit is Y-up, so the model root is rotated -90° on X.
struct ViewportView: NSViewRepresentable {
    var document: CADDocument
    var selection: Feature.ID?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        view.showsStatistics = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard let root = view.scene?.rootNode.childNode(withName: "model", recursively: false) else { return }
        root.childNodes.forEach { $0.removeFromParentNode() }
        for f in document.features where f.isVisible {
            let node = SCNNode(geometry: Self.geometry(from: f.buildMesh(), selected: f.id == selection))
            node.name = f.id.uuidString
            root.addChildNode(node)
        }
    }

    // MARK: Scene

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()
        let model = SCNNode()
        model.name = "model"
        model.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(model)
        scene.rootNode.addChildNode(grid(size: 200, step: 10))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 10_000
        camera.position = SCNVector3(120, 110, 160)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        scene.rootNode.addChildNode(key)
        return scene
    }

    /// Print-bed style grid on the XZ plane of SceneKit (= XY plane of CADCore).
    private static func grid(size: Double, step: Double) -> SCNNode {
        var verts: [SCNVector3] = []
        let h = size / 2
        var t = -h
        while t <= h + 1e-9 {
            verts += [SCNVector3(t, 0, -h), SCNVector3(t, 0, h), SCNVector3(-h, 0, t), SCNVector3(h, 0, t)]
            t += step
        }
        let src = SCNGeometrySource(vertices: verts)
        let el = SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .line)
        let geo = SCNGeometry(sources: [src], elements: [el])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 1, alpha: 0.18)
        mat.lightingModel = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    /// Flat-shaded geometry: vertices are un-shared so each triangle gets its own normal.
    private static func geometry(from mesh: Mesh, selected: Bool) -> SCNGeometry {
        var verts: [SCNVector3] = []
        var normals: [SCNVector3] = []
        verts.reserveCapacity(mesh.triangleCount * 3)
        for i in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(i)
            let n = mesh.normal(ofTriangle: i)
            for v in [a, b, c] {
                verts.append(SCNVector3(v.x, v.y, v.z))
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
        }
        let el = SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals)],
                              elements: [el])
        let mat = SCNMaterial()
        mat.lightingModel = .blinn
        mat.diffuse.contents = selected ? NSColor.systemOrange : NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
        mat.specular.contents = NSColor(white: 0.3, alpha: 1)
        geo.materials = [mat]
        return geo
    }
}
