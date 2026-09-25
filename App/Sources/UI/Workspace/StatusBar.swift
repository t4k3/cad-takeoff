import CADCore
import SwiftUI

struct StatusBar: View {
    @Environment(DesignModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text(model.statusMessage).lineLimit(1)
            Spacer()
            let visible = model.document.features.filter(\.isVisible)
            let mesh = model.document.buildMesh()
            Label("\(visible.count) corpi", systemImage: "shippingbox")
            Label("\(mesh.triangleCount) triangoli", systemImage: "triangle")
            Label(String(format: "%.2f cm³", mesh.volume / 1000), systemImage: "cube.transparent")
            Text("mm · Z↑")
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.statusHeight)
        .background(Theme.Palette.panel)
    }
}
