import AppKit
import CADCore
import SwiftUI

/// Design tree: origin planes and bodies, with visibility toggles.
struct BrowserPanel: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SketchStore.self) private var sketches
    @State private var originExpanded = false
    @State private var sketchesExpanded = true
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
                    DisclosureRow(title: "Schizzi", symbol: "pencil.and.outline", count: sketches.sketches.count,
                                  isExpanded: $sketchesExpanded)
                    if sketchesExpanded {
                        ForEach(sketches.sketches) { sk in sketchRow(sk) }
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

    private func sketchRow(_ sk: Sketch) -> some View {
        let editing = workspace.sketch?.sketch.id == sk.id
        return TreeRow(indent: 1, symbol: "pencil.and.outline", title: sk.name, isSelected: editing, isHovered: false,
                       isDimmed: !sk.isVisible) {
            Button { sketches.setVisible(sk.id, !sk.isVisible) } label: {
                Label(sk.isVisible ? "Nascondi" : "Mostra", systemImage: sk.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(IconButtonStyle())
            .help(sk.isVisible ? "Nascondi schizzo" : "Mostra schizzo")
        }
        .onTapGesture(count: 2) { workspace.enterSketch(editing: sk) }
        .help("Doppio clic per modificare lo schizzo")
        .contextMenu {
            Button("Modifica schizzo") { workspace.enterSketch(editing: sk) }
            Button("Elimina schizzo", role: .destructive) { confirmDelete(sk) }
        }
    }

    private func confirmDelete(_ sk: Sketch) {
        let linked = sketches.links(of: sk.id).count
        if linked > 0 {
            let alert = NSAlert()
            alert.messageText = "Eliminare «\(sk.name)»?"
            alert.informativeText = "\(linked) estrusion\(linked == 1 ? "e resta" : "i restano") nel disegno ma non si aggiornerà più dallo schizzo."
            alert.addButton(withTitle: "Elimina")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        sketches.delete(sk.id)
    }

    private func bodyRow(_ feature: Feature) -> some View {
        let active = model.document.isActive(feature.id)
        return TreeRow(indent: 1, symbol: feature.kind.symbol, title: feature.name,
                isSelected: model.selection == feature.id, isHovered: workspace.hovered == feature.id,
                isDimmed: !feature.isVisible || !active) {
            if let issue = model.snapshot().issues.first(where: { $0.featureID == feature.id }) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Geometria non valida: \(issue.message)")
                    .accessibilityLabel("Geometria non valida: \(issue.message)")
            }
            if !active {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .help("Non calcolato: soppresso o dopo il marker della timeline")
                    .accessibilityLabel("Non calcolato")
            }
            Circle().fill(feature.color.swiftUIColor).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                .help("Colore \(feature.color.hex)")
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
        .onTapGesture(count: 2) { workspace.editFeature(feature.id, model: model) }
        .onTapGesture { model.selection = feature.id }
        .onHover { workspace.hovered = $0 ? feature.id : (workspace.hovered == feature.id ? nil : workspace.hovered) }
        .contextMenu {
            Button("Modifica…") { workspace.editFeature(feature.id, model: model) }
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
