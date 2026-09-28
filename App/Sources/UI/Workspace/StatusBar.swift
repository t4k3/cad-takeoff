import CADCore
import SwiftUI

struct StatusBar: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        HStack(spacing: 14) {
            if workspace.tab == .circuits {
                // CIRCUITI: the circuit's messages and counts, never the 3D design's.
                Text(circuits.message).lineLimit(1)
                Spacer()
                if let design = circuits.design {
                    let errors = circuits.issues.filter { $0.severity == .error }.count
                    let warnings = circuits.issues.count - errors
                    if let m = design.manufacturing {
                        // An imported board: its parts and the lot shown; no nets or routing here.
                        Label("\(m.components.count) componenti", systemImage: "cpu")
                        Label("\(m.activeLot?.fittedComponentIDs.count ?? 0) montati · \(m.activeLot?.name ?? "")", systemImage: "checkmark.square")
                            .help("Componenti montati nel lotto mostrato; gli esclusi restano sulla scheda")
                        Label("\(m.lots.count) lott\(m.lots.count == 1 ? "o" : "i")", systemImage: "square.stack")
                    } else {
                        Label("\(design.components.count) componenti", systemImage: "cpu")
                        Label("\(design.nets.count) reti", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("\(circuits.board?.airwires.count ?? 0) da sbrogliare", systemImage: "line.diagonal")
                            .help("Collegamenti logici ancora senza pista")
                    }
                    if errors > 0 { Label("\(errors) errori", systemImage: "xmark.octagon").foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings) avvisi", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text("mm · vista dall'alto")
                }
            } else {
                Text(model.statusMessage).lineLimit(1)
                Spacer()
                let stats = model.stats()
                Label("\(stats.bodies) corpi", systemImage: "shippingbox")
                Label("\(stats.triangles) triangoli", systemImage: "triangle")
                Label(String(format: "%.2f cm³", stats.volume / 1000), systemImage: "cube.transparent")
                Text("mm · Z↑")
            }
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
