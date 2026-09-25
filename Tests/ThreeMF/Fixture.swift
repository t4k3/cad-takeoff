import Foundation
import CADCore

@main struct ThreeMFFixture {
    static func main() throws {
        let parts = [
            ThreeMFPart(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Base rossa & <supporto>",
                        mesh: Primitives.box(width: 40, depth: 30, height: 5), color: PartColor(hex: "#E53935")!),
            ThreeMFPart(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Inserto blu", 
                        mesh: Primitives.box(width: 10, depth: 10, height: 8).translated(by: Vec3(0, 0, 5)), color: PartColor(hex: "#1E88E5")!)
        ]
        try ThreeMFExporter.archive(parts: parts).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
