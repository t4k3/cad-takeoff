import CADCore
import SwiftUI

struct StatusBar: View {
    @Environment(DesignModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text(model.statusMessage).lineLimit(1)
            Spacer()
            let stats = model.stats()
            Label("\(stats.bodies) corpi", systemImage: "shippingbox")
            Label("\(stats.triangles) triangoli", systemImage: "triangle")
            Label(String(format: "%.2f cm³", stats.volume / 1000), systemImage: "cube.transparent")
            Text("mm · Z↑")
            Divider().frame(height: 12)
            MCPStatusButton()
            Divider().frame(height: 12)
            Text(AppVersion.short).help(AppVersion.long).textSelection(.enabled)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.statusHeight)
        .background(Theme.Palette.panel)
    }
}
