import SwiftUI

@main
struct FusionTakeoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DesignModel()
    @State private var mcp = MCPHost()
    @State private var library = ProjectLibrary()
    @State private var sketches = SketchStore()
    @State private var assistant = AssistantSession(providers: [ClaudeProvider(), OpenAIProvider()])

    var body: some Scene {
        WindowGroup("CAD Takeoff") {
            WorkspaceView()
                .environment(model)
                .environment(mcp)
                .environment(assistant)
                .environment(library)
                .environment(sketches)
                .navigationTitle(library.currentName + (library.isDirty(model) ? " — modificato" : ""))
                .navigationSubtitle(library.currentURL.flatMap { library.project(of: $0) } ?? "")
                .task {
                    // The Model is the single CAD tool provider (T48) for MCP clients and the in-app chat.
                    let tools = (model as AnyObject) as? CADToolProvider
                    mcp.attach(tools)
                    assistant.tools = tools
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
                Button("Chiudi disegno") { library.closeDesign(model: model) }.keyboardShortcut("w")
                    .disabled(library.currentURL == nil && model.document.features.isEmpty && model.document.sketches.isEmpty)
                Button("Importa mesh (STL, OBJ, 3MF)…") { model.importMeshWithPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Installa add-in in Fusion 360…") { model.statusMessage = FusionAddInInstaller.installWithPanel() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Salva") { library.save(model: model) }.keyboardShortcut("s")
                Button("Salva con nome…") { library.saveAs(model: model) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Esporta STL…") { model.exportSTLWithPanel() }.keyboardShortcut("e")
                Button("Esporta 3MF (con colori)…") { model.export3MFWithPanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Esporta STEP…") { model.exportSTEPWithPanel() }
            }
        }
        Settings {
            AssistantSettingsView()
                .environment(assistant)
        }
    }
}
