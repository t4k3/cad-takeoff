import CADCore
import SwiftUI

/// Tabbed tool ribbon. Only tools that actually work are shown; new ones appear as their tasks land.
struct Ribbon: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(WorkspaceState.Tab.allCases) { tab in
                    TabButton(title: tab.rawValue, isSelected: workspace.tab == tab) { workspace.tab = tab }
                }
                Spacer()
                Button { workspace.showAssistant() } label: {
                    Label("Assistente", systemImage: "sparkles")
                }.buttonStyle(IconButtonStyle(isActive: workspace.showInspector && workspace.sideTab == .assistant))
                    .help("Assistente di progettazione (⌘L)")
                    .keyboardShortcut("l", modifiers: .command)
                Button { workspace.showBrowser.toggle() } label: {
                    Label("Browser", systemImage: "sidebar.left")
                }.buttonStyle(IconButtonStyle(isActive: workspace.showBrowser)).help("Mostra/nascondi Browser")
                Button { workspace.showInspector.toggle() } label: {
                    Label("Parametri", systemImage: "sidebar.right")
                }.buttonStyle(IconButtonStyle(isActive: workspace.showInspector)).help("Mostra/nascondi Parametri")
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.Metrics.tabBarHeight)
            .background(Theme.Palette.panel)

            HStack(alignment: .top, spacing: 0) {
                switch workspace.tab {
                case .solid: solidTools
                case .sketch: sketchTools
                case .print: printTools
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.Metrics.ribbonHeight - Theme.Metrics.tabBarHeight)
            .background(Theme.Palette.ribbon)
        }
    }

    @ViewBuilder private var solidTools: some View {
        ToolGroup("CREA") {
            Button { model.addBox() } label: { Label("Box", systemImage: "cube") }
                .help("Nuovo parallelepipedo 20×20×20 mm")
            Button { model.addCylinder() } label: { Label("Cilindro", systemImage: "cylinder") }
                .help("Nuovo cilindro Ø20×20 mm")
            Button { model.addHexPrism() } label: { Label("Prisma", systemImage: "hexagon") }
                .help("Nuovo prisma esagonale estruso")
        }
        ToolGroup("MODIFICA") {
            Button(role: .destructive) { model.deleteSelected() } label: { Label("Elimina", systemImage: "trash") }
                .disabled(model.selection == nil)
                .help("Elimina la feature selezionata (⌫)")
        }
    }

    @ViewBuilder private var sketchTools: some View {
        ToolGroup("SCHIZZO") {
            Text("Gli strumenti di schizzo arrivano con T05")
                .font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
                .frame(height: 50)
        }
    }

    @ViewBuilder private var printTools: some View {
        ToolGroup("ESPORTA") {
            Button { model.exportSTLWithPanel() } label: { Label("STL", systemImage: "square.and.arrow.up") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta i corpi visibili in STL binario (mm)")
        }
    }
}

private struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .tracking(0.6)
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? Theme.Palette.accent : .clear).frame(height: 2)
                }
                .background(hovering && !isSelected ? Theme.Palette.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A labelled cluster of ribbon buttons with a trailing separator.
struct ToolGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                HStack(spacing: 2) { content }.buttonStyle(RibbonButtonStyle())
                Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, 6)
            Rectangle().fill(Theme.Palette.separator).frame(width: 1).padding(.vertical, 8)
        }
    }
}
