import CADCore
import SwiftUI

/// Horizontal feature history, like Fusion's timeline. Click selects; arrows step through.
struct TimelineBar: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            Button { step(-1) } label: { Label("Precedente", systemImage: "backward.frame") }
                .buttonStyle(IconButtonStyle()).help("Seleziona la feature precedente")
                .disabled(model.document.features.isEmpty)
            Button { step(1) } label: { Label("Successiva", systemImage: "forward.frame") }
                .buttonStyle(IconButtonStyle()).help("Seleziona la feature successiva")
                .disabled(model.document.features.isEmpty)
            Divider().frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(model.document.features.enumerated()), id: \.element.id) { index, feature in
                            chip(feature, index: index).id(feature.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metrics.timelineHeight)
        .background(Theme.Palette.panel)
    }

    private func chip(_ feature: Feature, index: Int) -> some View {
        let selected = model.selection == feature.id
        let hovered = workspace.hovered == feature.id
        return Image(systemName: feature.kind.symbol)
            .font(.system(size: 14))
            .foregroundStyle(selected ? .white : Theme.Palette.textPrimary)
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Theme.Palette.accent : hovered ? Theme.Palette.hover.opacity(2.5) : Theme.Palette.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Palette.separator))
            .opacity(feature.isVisible ? 1 : 0.45)
            .help("\(index + 1). \(feature.name) — \(feature.kind.typeName)")
            .onTapGesture { model.selection = feature.id }
            .onHover { workspace.hovered = $0 ? feature.id : (workspace.hovered == feature.id ? nil : workspace.hovered) }
    }

    private func step(_ delta: Int) {
        let features = model.document.features
        guard !features.isEmpty else { return }
        let current = model.selectedIndex ?? (delta > 0 ? -1 : features.count)
        model.selection = features[min(max(current + delta, 0), features.count - 1)].id
    }
}
