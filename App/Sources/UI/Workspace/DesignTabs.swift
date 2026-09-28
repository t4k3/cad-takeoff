import SwiftUI

/// Open designs as tabs (Fusion style): click to switch, X to close (asks to save changes),
/// + for a new design. Switching is instant: each tab keeps its evaluated design and camera.
struct DesignTabs: View {
    @Environment(DesignModel.self) private var model
    @Environment(ProjectLibrary.self) private var library
    @Environment(CircuitModel.self) private var circuits
    @State private var hovered: ProjectLibrary.Tab.ID?
    @State private var circuitHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    // In CIRCUITI the open circuit, with its own name (not the 3D design's tabs).
                    if circuits.isFrontmost {
                        if circuits.document != nil { circuitTab }
                    } else {
                        ForEach(library.tabs) { tab in tabView(tab) }
                    }
                }
            }
            Button {
                if circuits.isFrontmost { if circuits.confirmDiscard() { try? circuits.newCircuit() } }
                else { library.newUntitled(model: model) }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)
            .help(circuits.isFrontmost ? "Nuovo circuito" : "Nuovo disegno in una nuova scheda (⌘N)")
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.horizontal, 6)
        .background(Theme.Palette.canvas)
    }

    /// The circuit open in CIRCUITI: its file name, a dot for unsaved changes, X to close it.
    private var circuitTab: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(Theme.Palette.accent)
            Text(circuits.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            ZStack {
                if circuits.isDirty && !circuitHovered {
                    Circle().fill(Theme.Palette.textSecondary).frame(width: 6, height: 6)
                } else {
                    Button { circuits.closeCircuit() } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(circuitHovered ? Color.white.opacity(0.12) : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Chiudi il circuito (⌘W)")
                }
            }
            .frame(width: 16, height: 16)
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 24)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.panel))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.accent).frame(height: 2).padding(.horizontal, 6) }
        .contentShape(Rectangle())
        .onHover { circuitHovered = $0 }
        .help(circuits.url?.path.replacingOccurrences(of: ProjectLibraryHome.path, with: "~") ?? "\(circuits.title) — non ancora salvato")
    }

    private func tabView(_ tab: ProjectLibrary.Tab) -> some View {
        let active = tab.id == library.activeTab || (library.activeTab == nil && tab.id == library.tabs.first?.id)
        let name = active ? library.currentName : tab.name
        let dirty = active ? library.isDirty(model) : tab.isDirty
        return HStack(spacing: 6) {
            Image(systemName: "cube").font(.system(size: 10)).foregroundStyle(active ? Theme.Palette.accent : Theme.Palette.textSecondary)
            Text(name).font(.system(size: 11.5, weight: active ? .semibold : .regular)).lineLimit(1)
            ZStack {
                // Unsaved changes: a dot, turning into the X under the mouse.
                if dirty && hovered != tab.id {
                    Circle().fill(Theme.Palette.textSecondary).frame(width: 6, height: 6)
                } else {
                    Button { library.closeTab(tab.id, model: model) } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(hovered == tab.id ? Color.white.opacity(0.12) : .clear))
                            // The whole 16×16 circle takes the click (a clear background alone
                            // does not: only the small cross did).
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(active || hovered == tab.id ? 1 : 0)
                    .help("Chiudi (⌘W)")
                }
            }
            .frame(width: 16, height: 16)
        }
        .foregroundStyle(active ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 24)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.Palette.panel : (hovered == tab.id ? Theme.Palette.panel.opacity(0.5) : .clear)))
        .overlay(alignment: .bottom) {
            if active { Rectangle().fill(Theme.Palette.accent).frame(height: 2).padding(.horizontal, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { library.activate(tab.id, model: model) }
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(tab.url?.path.replacingOccurrences(of: ProjectLibraryHome.path, with: "~") ?? name)
    }
}
