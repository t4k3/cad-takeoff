import CADCore
import SwiftUI

/// Tabbed tool ribbon. Only tools that actually work are shown; new ones appear as their tasks land.
struct Ribbon: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(ProjectLibrary.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { library.showHome = true } label: { Label("Home", systemImage: "house") }
                    .buttonStyle(IconButtonStyle())
                    .help("Home: progetti e disegni (⇧⌘H)")
                Text(library.currentName + (library.isDirty(model) ? " •" : ""))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .help(library.currentURL?.path ?? "Disegno non ancora salvato")
                Button { UndoRouter.undo(model) } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!UndoRouter.canUndo(model))
                    .help(UndoRouter.undoTitle(model) + " (⌘Z)")
                Button { UndoRouter.redo(model) } label: { Label("Ripeti", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!UndoRouter.canRedo(model))
                    .help(UndoRouter.redoTitle(model) + " (⇧⌘Z)")
                Divider().frame(height: 14)
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
                case .sheetMetal: sheetMetalTools
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
            Button { workspace.startSketch() } label: { Label("Schizzo", systemImage: "pencil.and.outline") }
                .help("Nuovo schizzo: clicca una faccia piana del pezzo, o scegli il piano XY")
            Button { model.addBox() } label: { Label("Box", systemImage: "cube") }
                .help("Nuovo parallelepipedo 20×20×20 mm")
            Button { model.addCylinder() } label: { Label("Cilindro", systemImage: "cylinder") }
                .help("Nuovo cilindro Ø20×20 mm")
            Button { model.addHexPrism() } label: { Label("Prisma", systemImage: "hexagon") }
                .help("Nuovo prisma esagonale estruso")
        }
        ToolGroup("LAVORA") {
            Button { workspace.startHole(model: model) } label: { Label("Foro", systemImage: "circle.circle") }
                .help("Fori semplici, lamati o svasati, per viti, filettature o inserti a caldo: clicca su una faccia piana")
        }
        ToolGroup("MODIFICA") {
            Button { workspace.startChamfer(model: model, profile: .round) } label: { Label("Raccordo", systemImage: "circle.bottomhalf.filled") }
                .help("Arrotonda o smussa gli spigoli: clicca gli spigoli, scegli la forma (Tondo o Piatto) e la misura, o trascina la freccia")
            Button(role: .destructive) { model.deleteSelected() } label: { Label("Elimina", systemImage: "trash") }
                .disabled(model.selection == nil)
                .help("Elimina la feature selezionata (⌫)")
        }
    }

    /// The selected sheet-metal part, if the selection is one.
    private var selectedSheet: Feature? {
        guard let id = model.selection, let f = model.document.features.first(where: { $0.id == id }),
              case .sheetMetal = f.kind else { return nil }
        return f
    }

    @ViewBuilder private var sheetMetalTools: some View {
        ToolGroup("CREA") {
            Button { workspace.startSheetMetal(model: model) } label: { Label("Lamiera", systemImage: "square.stack.3d.down.forward") }
                .help("Nuova lamiera piegata: materiale, spessore, ingombro esterno e flange sui lati")
        }
        ToolGroup("MODIFICA") {
            Button { if let f = selectedSheet { workspace.startSheetMetal(model: model, editing: f) } } label: {
                Label("Modifica", systemImage: "slider.horizontal.3")
            }
            .disabled(selectedSheet == nil)
            .help("Modifica la lamiera selezionata (anche doppio clic nella timeline)")
        }
        ToolGroup("SVILUPPO") {
            Button { workspace.showFlat.toggle() } label: {
                Label(workspace.showFlat ? "Piegato" : "Sviluppo", systemImage: workspace.showFlat ? "cube" : "square.dashed")
            }
            .disabled(!model.hasSheetMetal)
            .help(workspace.showFlat ? "Torna al pezzo piegato" : "Mostra lo sviluppo in piano con le linee di piega")
            Button { model.exportFlatDXFWithPanel(selectedSheet?.id) } label: { Label("DXF", systemImage: "square.and.arrow.up") }
                .disabled(!model.hasSheetMetal)
                .help("Esporta lo sviluppo in DXF (mm): contorno di taglio e linee di piega per il laser e la piegatrice")
        }
    }

    @ViewBuilder private var sketchTools: some View {
        if let sketch = workspace.sketch {
            ToolGroup("DISEGNA") {
                ForEach(SketchSession.Tool.allCases) { tool in
                    Button { sketch.tool = tool } label: { Label(tool.rawValue, systemImage: tool.symbol) }
                        .buttonStyle(RibbonButtonStyle(isActive: sketch.tool == tool, tint: Theme.Palette.sketch))
                        .help(tool.hint)
                }
            }
            ToolGroup("OPZIONI") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Griglia 1 mm", isOn: Binding(get: { sketch.snapToGrid }, set: { sketch.snapToGrid = $0 }))
                        .toggleStyle(.checkbox)
                    HStack(spacing: 4) {
                        Stepper("Lati: \(sketch.polygonSides)", value: Binding(get: { sketch.polygonSides }, set: { sketch.polygonSides = $0 }), in: 3...64)
                        Toggle("Circoscr.", isOn: Binding(get: { sketch.polygonCircumscribed }, set: { sketch.polygonCircumscribed = $0 }))
                            .toggleStyle(.checkbox)
                            .help("Poligono circoscritto: il raggio va al punto medio dei lati")
                    }
                }
                .font(Theme.Typeface.toolLabel)
                .controlSize(.small)
                .frame(height: 50)
                .padding(.horizontal, 4)
            }
            ToolGroup("CREA") {
                Button { workspace.extrudeSketch(model: model) } label: { Label("Estrudi", systemImage: "square.stack.3d.up") }
                    .disabled(sketch.extrudeCandidate == nil || workspace.command != nil)
                    .help(sketch.extrudeCandidate == nil ? "Disegna o seleziona un profilo chiuso" : "Estrudi il profilo selezionato (E)")
                Button { sketch.deleteSelection() } label: { Label("Elimina", systemImage: "trash") }
                    .disabled(sketch.selection == nil)
            }
            ToolGroup("SCHIZZO") {
                Button { workspace.exitSketch() } label: { Label("Termina", systemImage: "checkmark.circle") }
                    .buttonStyle(RibbonButtonStyle(tint: Theme.Palette.sketch))
                    .help("Termina schizzo")
            }
        } else {
            ToolGroup("SCHIZZO") {
                Button { workspace.startSketch() } label: { Label("Crea schizzo", systemImage: "pencil.and.outline") }
                    .buttonStyle(RibbonButtonStyle(tint: Theme.Palette.sketch))
                    .help("Nuovo schizzo sul piano XY (piatto di stampa)")
            }
            Text("Disegna un profilo sul piano XY e trasformalo in un solido con Estrudi.")
                .font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
                .frame(height: 50).padding(.leading, 8)
        }
    }

    @ViewBuilder private var printTools: some View {
        ToolGroup("ESPORTA") {
            Button { model.exportSTLWithPanel() } label: { Label("STL", systemImage: "square.and.arrow.up") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta i corpi visibili in STL binario (mm), senza colori")
            Button { model.export3MFWithPanel() } label: { Label("3MF", systemImage: "paintpalette") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta in 3MF con parti separate e colori (Bambu Studio, OrcaSlicer, Snapmaker Orca)")
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
