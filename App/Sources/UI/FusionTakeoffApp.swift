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
        WindowGroup("Fusion Takeoff") {
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
                    library.adoptInitialDesign(model)
                    AppDelegate.confirmQuit = { [library, model] in library.confirmDiscard(model) }
                }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) { UndoMenuItems(model: model) }
            CommandGroup(replacing: .newItem) {
                Button("Home") { library.showHome.toggle() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Nuovo disegno") { library.newUntitled(model: model) }.keyboardShortcut("n")
                Button("Apri…") { library.openWithPanel(model: model) }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Salva") { library.save(model: model) }.keyboardShortcut("s")
                Button("Salva con nome…") { library.saveAs(model: model) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Esporta STL…") { model.exportSTLWithPanel() }.keyboardShortcut("e")
                Button("Esporta 3MF (con colori)…") { model.export3MFWithPanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        Settings {
            AssistantSettingsView()
                .environment(assistant)
        }
    }
}
