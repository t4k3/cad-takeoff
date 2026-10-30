import CADCore
import SwiftUI

/// Right-hand side of the workspace's bottom bar: the current message, the circuit counts
/// (only in CIRCUITI) and the app version. The design's counts live at the bottom of the
/// right panel; the navigation buttons are on the left of this bar.
struct StatusBar: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(CircuitModel.self) private var circuits

    var body: some View {
        HStack(spacing: 14) {
            if workspace.tab == .circuits {
                // CIRCUITI: the circuit's messages and counts, never the 3D design's.
                Text(LocalizedStringKey(circuits.message)).lineLimit(1)
                Spacer(minLength: 12)
                circuitStats
                Text("mm · vista dall'alto")
            } else {
                Text(LocalizedStringKey(model.statusMessage)).lineLimit(1)
                Spacer(minLength: 8)
            }
            Divider().frame(height: 12)
            Text(AppVersion.short).help(AppVersion.long).textSelection(.enabled)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    @ViewBuilder private var circuitStats: some View {
        if let design = circuits.design {
            let errors = circuits.issues.filter { $0.severity == .error }.count
            let warnings = circuits.issues.count - errors
            if let m = design.manufacturing {
                // An imported board: its parts and the lot shown; no nets or routing here.
                Label("\(m.components.count) componenti", systemImage: "cpu")
                Label("\(m.activeLot?.fittedComponentIDs.count ?? 0) montati · \(m.activeLot?.name ?? "")", systemImage: "checkmark.square")
                    .help("Componenti montati nel lotto mostrato; gli esclusi restano sulla scheda")
                Label(m.lots.count == 1 ? String(localized: "1 lotto") : String(localized: "\(m.lots.count) lotti"), systemImage: "square.stack")
            } else {
                Label("\(design.components.count) componenti", systemImage: "cpu")
                Label("\(design.nets.count) reti", systemImage: "point.3.connected.trianglepath.dotted")
                Label("\(circuits.board?.airwires.count ?? 0) da sbrogliare", systemImage: "line.diagonal")
                    .help("Collegamenti logici ancora senza pista")
            }
            if errors > 0 {
                Label(errors == 1 ? String(localized: "1 errore") : String(localized: "\(errors) errori"),
                      systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if warnings > 0 {
                Label(warnings == 1 ? String(localized: "1 avviso") : String(localized: "\(warnings) avvisi"),
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}
