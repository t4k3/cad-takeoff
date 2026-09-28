import SwiftUI

@main
struct FusionTakeoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DesignModel()
    @State private var mcp = MCPHost()
    @State private var library = ProjectLibrary()
    @State private var sketches = SketchStore()
    @State private var circuits = CircuitModel()
    @State private var tools: ToolRouter?
    @State private var assistant = AssistantSession(providers: [ClaudeProvider(), OpenAIProvider(), AppleIntelligenceProvider()])

    var body: some Scene {
        WindowGroup("CAD Takeoff") {
            WorkspaceView()
                .environment(model)
                .environment(mcp)
                .environment(assistant)
                .environment(library)
                .environment(sketches)
                .environment(circuits)
                .navigationTitle(circuits.isFrontmost && circuits.document != nil
                                 ? circuits.title + (circuits.isDirty ? " — modificato" : "")
                                 : library.currentName + (library.isDirty(model) ? " — modificato" : ""))
                .navigationSubtitle((circuits.isFrontmost && circuits.document != nil ? circuits.url : library.currentURL).flatMap { library.project(of: $0) } ?? "")
                .task {
                    // One provider for MCP clients and the in-app chat: the CAD design's tools (T48)
                    // and CIRCUITI's circuit_* tools (T100), kept alive here (both hold it weakly).
                    let router = ToolRouter(cad: model, circuits: circuits)
                    tools = router
                    mcp.attach(router)
                    assistant.tools = router
                    mcp.start()
                    sketches.model = model
                    model.componentResolver = library.componentResolver
                    model.projectDesigns = { [library] in library.allDesigns.map { library.componentPath(for: $0.url) } }
                    library.adoptInitialDesign(model)
                    AppDelegate.confirmQuit = { [library, model] in library.confirmDiscardAll(model) }
                }
                .onChange(of: library.rootURL) { _, _ in model.componentResolver = library.componentResolver }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Informazioni su CAD Takeoff") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: "\(AppVersion.version) (build \(AppVersion.build))",
                        .credits: NSAttributedString(string: "Commit \(AppVersion.commit) · compilata il \(AppVersion.buildDate)\nhttps://github.com/t4k3/cad-takeoff"),
                    ])
                }
            }
            CommandGroup(replacing: .undoRedo) { UndoMenuItems(model: model) }
            CommandGroup(replacing: .newItem) {
                Button("Home") { library.showHome.toggle() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Nuovo disegno") { library.newUntitled(model: model) }.keyboardShortcut("n")
                Button("Apri…") { library.openWithPanel(model: model) }.keyboardShortcut("o")
                Button(circuits.isFrontmost ? "Chiudi circuito" : "Chiudi disegno") {
                    if circuits.isFrontmost { circuits.closeCircuit() } else { library.closeDesign(model: model) }
                }
                .keyboardShortcut("w")
                .disabled(circuits.isFrontmost ? circuits.document == nil
                          : library.currentURL == nil && model.document.features.isEmpty && model.document.sketches.isEmpty)
                Button("Importa mesh (STL, OBJ, 3MF)…") { model.importMeshWithPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Installa add-in in Fusion 360…") { model.statusMessage = FusionAddInInstaller.installWithPanel() }
            }
            CommandGroup(replacing: .saveItem) {
                // In CIRCUITI the circuit (.ftkc), elsewhere the design (.ftk).
                Button(circuits.isFrontmost ? "Salva circuito" : "Salva") {
                    if circuits.isFrontmost { circuits.saveWithPanel() } else { library.save(model: model) }
                }
                .keyboardShortcut("s")
                .disabled(circuits.isFrontmost && circuits.document == nil)
                Button(circuits.isFrontmost ? "Salva circuito con nome…" : "Salva con nome…") {
                    if circuits.isFrontmost { circuits.saveWithPanel(asNew: true) } else { library.saveAs(model: model) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(circuits.isFrontmost && circuits.document == nil)
                Button("Esporta STL…") { model.exportSTLWithPanel() }.keyboardShortcut("e")
                Button("Esporta 3MF (con colori)…") { model.export3MFWithPanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Esporta STEP…") { model.exportSTEPWithPanel() }
                Button("Tavola tecnica…") { model.showDrawing = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.document.features.isEmpty)
            }
        }
        Settings {
            AssistantSettingsView()
                .environment(assistant)
        }
    }
}
