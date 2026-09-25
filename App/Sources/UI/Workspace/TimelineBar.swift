import CADCore
import SwiftUI

/// Horizontal feature history, like Fusion's timeline. Click selects; arrows step through.
struct TimelineBar: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SketchStore.self) private var sketches

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
                            ForEach(sketchesBefore(index)) { sk in sketchChip(sk) }
                            chip(feature, index: index).id(feature.id)
                        }
                        ForEach(unusedSketches) { sk in sketchChip(sk) }
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
            .overlay(alignment: .bottom) {
                Capsule().fill(feature.color.swiftUIColor).frame(width: 16, height: 3).offset(y: -2)
            }
            .opacity(feature.isVisible ? 1 : 0.45)
            .help("\(index + 1). \(feature.name) — \(feature.kind.typeName)")
            .onTapGesture(count: 2) { workspace.editFeature(feature.id, model: model) }
            .onTapGesture { model.selection = feature.id }
            .contextMenu { Button("Modifica…") { workspace.editFeature(feature.id, model: model) } }
            .onHover { workspace.hovered = $0 ? feature.id : (workspace.hovered == feature.id ? nil : workspace.hovered) }
    }

    /// Sketches whose first linked feature is at `index` (so they appear right before it).
    private func sketchesBefore(_ index: Int) -> [Sketch] {
        let features = model.document.features
        return sketches.sketches.filter { sk in
            let ids = Set(sketches.links(of: sk.id).map(\.featureID))
            return features.firstIndex { ids.contains($0.id) } == index
        }
    }

    private var unusedSketches: [Sketch] {
        let used = Set(model.document.features.map(\.id))
        return sketches.sketches.filter { sk in !sketches.links(of: sk.id).contains { used.contains($0.featureID) } }
    }

    private func sketchChip(_ sk: Sketch) -> some View {
        let editing = workspace.sketch?.sketch.id == sk.id
        return Image(systemName: "pencil.and.outline")
            .font(.system(size: 13))
            .foregroundStyle(editing ? .white : Theme.Palette.sketch)
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(editing ? Theme.Palette.sketch : Theme.Palette.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Palette.sketch.opacity(0.6)))
            .opacity(sk.isVisible ? 1 : 0.5)
            .help("\(sk.name) — doppio clic per modificare")
            .onTapGesture(count: 2) { workspace.enterSketch(editing: sk) }
            .contextMenu { Button("Modifica schizzo") { workspace.enterSketch(editing: sk) } }
    }

    private func step(_ delta: Int) {
        let features = model.document.features
        guard !features.isEmpty else { return }
        let current = model.selectedIndex ?? (delta > 0 ? -1 : features.count)
        model.selection = features[min(max(current + delta, 0), features.count - 1)].id
    }
}
