import CADCore
import SwiftUI

/// Tabbed tool ribbon. Only tools that actually work are shown; new ones appear as their tasks land.
struct Ribbon: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @Environment(ProjectLibrary.self) private var library
    @Environment(CircuitModel.self) private var circuits
    /// The sketch constraints' list (VINCOLI › Vincoli).
    @State private var showConstraints = false
    /// The copper layers' list (SBROGLIO › Strato).
    @State private var showLayers = false

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
                // SCHIZZO only while a sketch is open (as in Fusion): it starts from SOLIDO › Schizzo.
                ForEach(WorkspaceState.Tab.allCases.filter { $0 != .sketch || workspace.sketch != nil }) { tab in
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

            // Scrolls sideways when the window is narrower than the tools (no bar shown).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    switch workspace.tab {
                    case .solid: solidTools
                    case .sketch: if workspace.sketch != nil { sketchTools } else { solidTools }
                    case .sheetMetal: sheetMetalTools
                    case .print: printTools
                    case .circuits: circuitTools
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
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
            Button { model.importMeshWithPanel() } label: { Label("Importa", systemImage: "square.and.arrow.down.on.square") }
                .help("Importa STL, OBJ o 3MF (anche esportati da Fusion 360) come corpi: le facce piane restano selezionabili (⇧⌘I)")
        }
        ToolGroup("ASSIEME") {
            Button { workspace.showComponentPicker = true } label: { Label("Inserisci", systemImage: "puzzlepiece.extension") }
                .help("Inserisci un altro disegno del progetto come componente (si aggiorna quando il pezzo cambia)")
            Button { workspace.showBOM = true } label: { Label("Distinta", systemImage: "list.number") }
                .help("Distinta base dell'assieme: pezzi, quantità, materiali, volumi")
            Button { workspace.startJoint(model: model) } label: { Label("Giunto", systemImage: "link") }
                .disabled(model.document.features.count < 2)
                .help("Unisci due pezzi: clicca il bordo del foro o dell'albero sul pezzo che si muove, poi dove va; rigido, rotazione o scorrimento")
            Button { workspace.startExplode(model: model) } label: { Label("Esplosa", systemImage: "arrow.up.left.and.arrow.down.right") }
                .disabled(model.document.features.count < 2)
                .help("Vista esplosa: i pezzi si allontanano dal centro dell'assieme (solo vista, il disegno non cambia)")
            Button { workspace.showInterference = true } label: { Label("Interferenze", systemImage: "exclamationmark.triangle") }
                .disabled(model.document.features.count < 2)
                .help("Controlla quali corpi e componenti si compenetrano, e di quanto")
        }
        ToolGroup("LAVORA") {
            Button { workspace.startHole(model: model) } label: { Label("Foro", systemImage: "circle.circle") }
                .help("Fori semplici, lamati o svasati, per viti, filettature o inserti a caldo: clicca su una faccia piana")
        }
        ToolGroup("MODIFICA") {
            Button { workspace.startPattern(model: model, kind: .rectangular) } label: { Label("Serie", systemImage: "square.grid.3x3") }
                .disabled(model.selection == nil)
                .help("Ripete il corpo selezionato in griglia o in cerchio; con un foro o un taglio selezionato ripete l'operazione")
            Button { workspace.startPattern(model: model, kind: .mirror) } label: {
                Label("Specchio", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .disabled(model.selection == nil)
            .help("Specchia il corpo selezionato rispetto a un piano (anche unito, per i pezzi simmetrici)")
            Button { workspace.startSplit(model: model) } label: { Label("Dividi", systemImage: "rectangle.split.2x1") }
                .disabled(model.selection == nil)
                .help("Divide il corpo selezionato con un piano (es. per stampare un pezzo più grande del piatto)")
            Button { workspace.startPressPull(model: model) } label: { Label("Premi/Tira", systemImage: "arrow.up.and.down.square") }
                .help("Clicca una faccia e trascina la freccia (Q): l'alto o il basso di un'estrusione ne cambia l'altezza, le altre facce si estrudono")
            Button { workspace.startMove(model: model) } label: { Label("Sposta", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                .disabled(model.selection == nil)
                .help("Sposta e ruota il corpo selezionato (resta un passo della timeline)")
            Button { workspace.startShell(model: model) } label: { Label("Guscio", systemImage: "cube.transparent") }
                .help("Svuota un corpo lasciando pareti di spessore dato: clicca le facce da aprire (es. il sopra di una scatola)")
            Button { workspace.startChamfer(model: model, profile: .round) } label: { Label("Raccordo", systemImage: "circle.bottomhalf.filled") }
                .help("Arrotonda o smussa gli spigoli: clicca gli spigoli, scegli la forma (Tondo o Piatto) e la misura, o trascina la freccia")
            Button { workspace.showParameters = true } label: { Label("Parametri", systemImage: "function") }
                .help("Valori con un nome da usare nelle quote e nelle misure (es. «larghezza / 2»)")
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
            Button { model.exportFlatDrawingWithPanel(selectedSheet?.id) } label: { Label("Tavola", systemImage: "doc.richtext") }
                .disabled(!model.hasSheetMetal)
                .help("Tavola di piega (PDF o DXF): sviluppo quotato, linee di piega su/giù, tabella pieghe e fori")
        }
    }

    @ViewBuilder private var sketchTools: some View {
        if let sketch = workspace.sketch {
            ToolGroup("DISEGNA") {
                ForEach(SketchSession.Tool.drawing) { tool in
                    Button { sketch.constraintTool = nil; sketch.tool = tool } label: { Label(tool.rawValue, systemImage: tool.symbol) }
                        .buttonStyle(RibbonButtonStyle(isActive: sketch.tool == tool && sketch.constraintTool == nil, tint: Theme.Palette.sketch))
                        .help(tool.hint + (tool.key.map { " (\($0.uppercased()))" } ?? ""))
                }
            }
            ToolGroup("MODIFICA") {
                ForEach(SketchSession.Tool.modify) { tool in
                    Button { sketch.constraintTool = nil; sketch.tool = tool } label: { Label(tool.rawValue, systemImage: tool.symbol) }
                        .buttonStyle(RibbonButtonStyle(isActive: sketch.tool == tool && sketch.constraintTool == nil, tint: Theme.Palette.sketch))
                        .help(tool.hint + (tool.key.map { " (\($0.uppercased()))" } ?? ""))
                }
            }
            ToolGroup("VINCOLI") {
                Button { sketch.constraintTool = nil; sketch.tool = .dimension } label: { Label("Quota", systemImage: "ruler") }
                    .buttonStyle(RibbonButtonStyle(isActive: sketch.tool == .dimension, tint: Theme.Palette.sketch))
                    .help(SketchSession.Tool.dimension.hint + " (D)")
                Button { workspace.showParameters = true } label: { Label("Parametri", systemImage: "function") }
                    .help("Valori con un nome: nelle quote scrivi «larghezza / 2» e la quota li segue")
                // Used now and then: behind one button, the list opens below it (fits a 13" screen).
                Button { showConstraints.toggle() } label: {
                    Label("Vincoli", systemImage: sketch.constraintTool?.symbol ?? "link")
                }
                .buttonStyle(RibbonButtonStyle(isActive: sketch.constraintTool != nil, tint: Theme.Palette.sketch))
                .help(sketch.constraintTool.map { "\($0.rawValue): \($0.hint)" } ?? "Vincoli geometrici: orizzontale/verticale, coincidente, parallelo, tangente…")
                .popover(isPresented: $showConstraints, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(ConstraintTool.allCases) { c in
                            Button {
                                sketch.constraintTool = sketch.constraintTool == c ? nil : c
                                showConstraints = false
                            } label: {
                                Label(c.rawValue, systemImage: c.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(sketch.constraintTool == c ? Theme.Palette.sketch.opacity(0.3) : Color.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(c.hint)
                        }
                    }
                    .padding(6)
                    .frame(width: 190)
                }
            }
            ToolGroup("OPZIONI") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Griglia 1 mm", isOn: Binding(get: { sketch.snapToGrid }, set: { sketch.snapToGrid = $0 }))
                        .toggleStyle(.checkbox)
                    if [.fillet, .chamfer, .offset].contains(sketch.tool) {
                        let tool = sketch.tool
                        HStack(spacing: 4) {
                            Text(tool == .fillet ? "Raggio" : "Distanza")
                            TextField("", value: Binding(get: { tool == .fillet ? sketch.filletRadius : tool == .chamfer ? sketch.chamferDistance : sketch.offsetDistance },
                                                         set: { v in
                                                             let v = max(0.01, v)
                                                             switch tool {
                                                             case .fillet: sketch.filletRadius = v
                                                             case .chamfer: sketch.chamferDistance = v
                                                             default: sketch.offsetDistance = v
                                                             }
                                                         }),
                                      format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 44).textFieldStyle(.roundedBorder)
                            Text("mm")
                        }
                    }
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
                    .disabled(sketch.faces.isEmpty || workspace.command != nil)
                    .help(sketch.faces.isEmpty ? "Disegna un profilo chiuso" : "Estrudi: clicca le aree da estrudere (E)")
                Button { workspace.revolveSketch(model: model) } label: { Label("Rivoluzione", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(sketch.faces.isEmpty || workspace.command != nil)
                    .help("Fa girare le aree intorno a una linea dello schizzo (meglio di costruzione): alberi, pulegge, perni")
                Button { workspace.sheetMetalFromSketch(model: model) } label: { Label("Lamiera", systemImage: "square.stack.3d.down.forward") }
                    .disabled(sketch.faces.isEmpty || workspace.command != nil)
                    .help("Lamiera con il profilo chiuso come base: poi clicca i lati da piegare")
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

    /// CIRCUITI: the circuit file, moving parts, manufacturing (the engine is Codex's
    /// ElectronicsCore; schematic and routing come as it grows).
    @ViewBuilder private var circuitTools: some View {
        ToolGroup("CIRCUITO") {
            Button { if circuits.confirmDiscard() { try? circuits.newCircuit() } } label: { Label("Nuovo", systemImage: "plus.square") }
                .help("Nuovo circuito: scheda 50 × 30 mm")
            Button { circuits.openWithPanel() } label: { Label("Apri", systemImage: "folder") }
                .help("Apri un circuito (.ftkc)")
            Button { circuits.saveWithPanel() } label: { Label("Salva", systemImage: "square.and.arrow.down") }
                .disabled(circuits.document == nil)
                .help("Salva il circuito (.ftkc)")
            Button { circuits.openExample() } label: { Label("Esempio", systemImage: "sparkles") }
                .help("Il circuito di prova del motore (componenti fittizi, da non ordinare)")
        }
        if circuits.canvas == .schematic {
            ToolGroup("SCHEMA") {
                Button { circuits.schematicTool = .select; circuits.showAddComponent = true } label: { Label("Componente", systemImage: "cpu") }
                    .disabled(circuits.document == nil)
                    .help("Aggiungi un componente allo schema: scegli, poi clic sul foglio")
                schematicToolButton(.wire, "Filo", "line.diagonal", "Collega pin, giunzioni e fili: clic sul pin di partenza, clic nel vuoto per le pieghe, clic sull'arrivo (Esc annulla)")
                schematicToolButton(.label, "Etichetta", "tag", "Dai un nome alla rete di un pin: lo stesso nome altrove è la stessa rete")
                schematicToolButton(.noConnect, "NC", "xmark", "Segna un pin da lasciare scollegato")
                schematicToolButton(.junction, "Giunzione", "circle.fill", "Una giunzione su un filo, per ramificare")
            }
            ToolGroup("SIMBOLO") {
                Button { if let c = circuits.schematicSelection?.componentID { circuits.rotateSymbol(c) } } label: { Label("Ruota", systemImage: "rotate.right") }
                    .disabled(circuits.schematicSelection?.componentID == nil)
                    .help("Ruota di 90° il simbolo selezionato (R)")
                Button { if let c = circuits.schematicSelection?.componentID { circuits.mirrorSymbol(c) } } label: { Label("Specchia", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .disabled(circuits.schematicSelection?.componentID == nil)
                    .help("Specchia il simbolo selezionato (M)")
                Button { if let s = circuits.schematicSelection { circuits.removeSchematicObject(s) } } label: { Label("Elimina", systemImage: "trash") }
                    .disabled(circuits.schematicSelection == nil)
                    .help("Elimina simbolo, filo, etichetta o giunzione selezionati (Canc); il componente resta sulla scheda")
            }
        } else {
        ToolGroup("CREA") {
            Button { circuits.tool = .select; circuits.showAddComponent = true } label: { Label("Componente", systemImage: "cpu") }
                .disabled(circuits.document == nil)
                .help("Aggiungi un componente: scegli, dai sigla e valore, poi clicca sulla scheda dove posarlo")
            Button { circuits.tool = circuits.tool == .connect ? .select : .connect } label: { Label("Collega", systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(RibbonButtonStyle(isActive: circuits.tool == .connect, tint: Theme.Palette.accent))
                .disabled(circuits.document == nil)
                .help("Collega due pin: clicca una piazzola, poi l'altra (stessa rete; collegamento logico, non ancora una pista)")
            Button { circuits.tool = .select; circuits.showBoard = true } label: { Label("Scheda", systemImage: "rectangle.dashed") }
                .disabled(circuits.document == nil)
                .help("Misure e spessore della scheda, strati del rame e regole, con anteprima")
        }
        ToolGroup("SBROGLIO") {
            Button { circuits.tool = circuits.tool == .route ? .select : .route } label: {
                Label("Pista", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(RibbonButtonStyle(isActive: circuits.tool == .route, tint: Theme.Palette.accent))
            .disabled(circuits.document == nil)
            .help("Traccia una pista (X): clicca una piazzola, poi i punti di piega; finisce sul rame della stessa rete, con Invio o con un secondo clic sull'ultimo punto")
            Button { circuits.tool = circuits.tool == .zone ? .select : .zone } label: {
                Label("Piano", systemImage: "square.fill.on.square.fill")
            }
            .buttonStyle(RibbonButtonStyle(isActive: circuits.tool == .zone, tint: Theme.Palette.accent))
            .disabled(circuits.document == nil)
            .help("Piano di rame (P): contorno a clic riempito col rame di una rete (GND…), lontano dalle altre reti; collegamento pieno")
            Button { circuits.tool = circuits.tool == .keepout ? .select : .keepout } label: {
                Label("Area vietata", systemImage: "nosign")
            }
            .buttonStyle(RibbonButtonStyle(isActive: circuits.tool == .keepout, tint: Theme.Palette.accent))
            .disabled(circuits.document == nil)
            .help("Disegna un'area dove il rame è vietato (K): clicca i punti, 2 punti e Invio fanno un rettangolo")
            Button { circuits.tool = .select; circuits.showNetClasses = true } label: { Label("Classi", systemImage: "square.stack.3d.up") }
                .disabled(circuits.document == nil)
                .help("Classi di rete: minimi e misure di pista e via per gruppi di reti (alimentazione, segnali…)")
            // The layers behind one button (up to 32: a list that opens below it).
            Button { showLayers.toggle() } label: { Label(circuits.layerName(circuits.activeLayer), systemImage: "square.3.layers.3d") }
                .disabled(circuits.document == nil)
                .help("Strato su cui tracciare. Durante una pista, cambiarlo mette una via (V: lato opposto)")
                .popover(isPresented: $showLayers, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(0..<circuits.layerCount, id: \.self) { layer in
                            Button {
                                circuits.switchLayer(to: layer)
                                showLayers = false
                            } label: {
                                Label(circuits.layerName(layer), systemImage: "square.fill")
                                    .foregroundStyle(CopperColors.layer(layer, of: circuits.layerCount))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(circuits.activeLayer == layer ? Theme.Palette.accent.opacity(0.3) : Color.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .frame(width: 160)
                }
        }
        ToolGroup("COMPONENTE") {
            Button { if let c = circuits.selection { circuits.rotate(c) } } label: { Label("Ruota", systemImage: "rotate.right") }
                .disabled(circuits.selection == nil)
                .help("Ruota di 90° il componente selezionato (R)")
            Button { if let c = circuits.selection { circuits.flip(c) } } label: { Label("Lato", systemImage: "arrow.up.arrow.down.square") }
                .disabled(circuits.selection == nil)
                .help("Porta il componente sull'altro lato della scheda (F)")
            Button {
                if let item = circuits.copperSelection { Task { await circuits.removeCopper(item) } }
                else if let k = circuits.keepoutSelection { Task { await circuits.removeKeepout(k) } }
                else if let z = circuits.zoneSelection { Task { await circuits.removeZone(z) } }
                else if let c = circuits.selection { circuits.removeComponent(c) }
            } label: { Label("Elimina", systemImage: "trash") }
                .disabled(circuits.selection == nil && circuits.copperSelection == nil && circuits.keepoutSelection == nil && circuits.zoneSelection == nil)
                .help("Elimina la pista, la via, l'area vietata o il piano selezionato, o il componente con i suoi collegamenti (Canc)")
        }
        }
        ToolGroup("LIBRERIA") {
            Button { circuits.tool = .select; circuits.importWithPanel() } label: { Label("Importa", systemImage: "square.and.arrow.down.on.square") }
                .disabled(circuits.document == nil)
                .help("Importa un'impronta o un simbolo KiCad, o un'impronta EasyEDA Standard: anteprima e avvisi prima di confermare")
            Button { circuits.tool = .select; circuits.showCreateDevice = true } label: { Label("Nuovo tipo", systemImage: "puzzlepiece.extension") }
                .disabled(circuits.document == nil)
                .help("Unisci un simbolo e un'impronta della libreria in un componente da posare (pin ↔ piazzole proposti, da verificare sul datasheet)")
        }
        ToolGroup("PRODUZIONE") {
            Button { circuits.exportJLCWithPanel() } label: { Label("JLCPCB", systemImage: "shippingbox") }
                .disabled(circuits.document == nil)
                .help("BOM e CPL per il montaggio JLCPCB (CSV). Il motore blocca l'export se manca qualcosa e dice cosa.")
        }
    }

    private func schematicToolButton(_ tool: CircuitModel.SchematicTool, _ title: String, _ symbol: String, _ help: String) -> some View {
        Button { circuits.schematicTool = circuits.schematicTool == tool ? .select : tool } label: { Label(title, systemImage: symbol) }
            .buttonStyle(RibbonButtonStyle(isActive: circuits.schematicTool == tool, tint: Theme.Palette.accent))
            .disabled(circuits.document == nil)
            .help(help)
    }

    @ViewBuilder private var printTools: some View {
        ToolGroup("ESPORTA") {
            Button { model.exportSTLWithPanel() } label: { Label("STL", systemImage: "square.and.arrow.up") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta i corpi visibili in STL binario (mm), senza colori")
            Button { model.export3MFWithPanel() } label: { Label("3MF", systemImage: "paintpalette") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta in 3MF con parti separate e colori (Bambu Studio, OrcaSlicer, Snapmaker Orca)")
            Button { model.exportSTEPWithPanel() } label: { Label("STEP", systemImage: "shippingbox") }
                .disabled(model.document.features.isEmpty)
                .help("Esporta in STEP AP214 (mm): un solido per corpo, con i colori — per fornitori, CNC e altri CAD")
            Button { model.showDrawing = true } label: { Label("Tavola", systemImage: "doc.richtext") }
                .disabled(model.document.features.isEmpty)
                .help("Tavola tecnica ISO (primo diedro) a schermo: aggiungi, sposta o togli quote, poi PDF o DXF (⇧⌘P)")
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
