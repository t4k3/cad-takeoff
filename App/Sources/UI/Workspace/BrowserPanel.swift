import CADCore
import SwiftUI

/// Design tree: origin planes and bodies, with visibility toggles.
struct BrowserPanel: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var originExpanded = false
    @State private var bodiesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Browser")
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    DisclosureRow(title: "Origine", symbol: "move.3d", isExpanded: $originExpanded)
                    if originExpanded {
                        ForEach(["Piano XY", "Piano XZ", "Piano YZ"], id: \.self) { plane in
                            TreeRow(indent: 1, symbol: "square.dashed", title: plane, isSelected: false, isHovered: false)
                        }
                    }
                    DisclosureRow(title: "Corpi", symbol: "shippingbox", count: model.document.features.count,
                                  isExpanded: $bodiesExpanded)
                    if bodiesExpanded {
                        ForEach(model.document.features) { feature in
                            bodyRow(feature)
                        }
                        if model.document.features.isEmpty {
                            Text("Nessun corpo. Usa CREA nella barra in alto.")
                                .font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
                                .padding(.leading, 34).padding(.vertical, 6)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Theme.Palette.panel)
    }

    private func bodyRow(_ feature: Feature) -> some View {
        TreeRow(indent: 1, symbol: feature.kind.symbol, title: feature.name,
                isSelected: model.selection == feature.id, isHovered: workspace.hovered == feature.id,
                isDimmed: !feature.isVisible) {
            Button {
                // TODO(R1): replace with model.setVisible(_:_:) when Codex ships it.
                if let i = model.document.features.firstIndex(where: { $0.id == feature.id }) {
                    model.document.features[i].isVisible.toggle()
                }
            } label: {
                Label(feature.isVisible ? "Nascondi" : "Mostra", systemImage: feature.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(IconButtonStyle())
            .help(feature.isVisible ? "Nascondi corpo" : "Mostra corpo")
        }
        .onTapGesture { model.selection = feature.id }
        .onHover { workspace.hovered = $0 ? feature.id : (workspace.hovered == feature.id ? nil : workspace.hovered) }
        .contextMenu {
            Button("Elimina", role: .destructive) {
                model.selection = feature.id
                model.deleteSelected()
            }
        }
    }
}

private struct DisclosureRow: View {
    let title: String
    let symbol: String
    var count: Int?
    @Binding var isExpanded: Bool

    var body: some View {
        TreeRow(indent: 0, symbol: symbol, title: title, isSelected: false, isHovered: false,
                chevron: isExpanded ? "chevron.down" : "chevron.right") {
            if let count { Text("\(count)").font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary) }
        }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }
    }
}

struct TreeRow<Accessory: View>: View {
    let indent: Int
    let symbol: String
    let title: String
    let isSelected: Bool
    let isHovered: Bool
    var isDimmed = false
    var chevron: String?
    @ViewBuilder var accessory: Accessory

    init(indent: Int, symbol: String, title: String, isSelected: Bool, isHovered: Bool, isDimmed: Bool = false,
         chevron: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.indent = indent; self.symbol = symbol; self.title = title
        self.isSelected = isSelected; self.isHovered = isHovered; self.isDimmed = isDimmed
        self.chevron = chevron; self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chevron ?? "")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 10)
            Image(systemName: symbol)
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .frame(width: 16)
            Text(title).font(Theme.Typeface.body).lineLimit(1)
            Spacer(minLength: 4)
            accessory
        }
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.leading, 8 + CGFloat(indent) * 16)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.Palette.accent.opacity(0.18) : isHovered ? Theme.Palette.hover : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }
}
