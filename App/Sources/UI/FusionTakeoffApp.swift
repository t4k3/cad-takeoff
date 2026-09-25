import SwiftUI

@main
struct FusionTakeoffApp: App {
    @State private var model = DesignModel()
    @State private var mcp = MCPHost()
    @State private var assistant = AssistantSession(providers: [ClaudeProvider(), OpenAIProvider()])

    var body: some Scene {
        WindowGroup("Fusion Takeoff") {
            WorkspaceView()
                .environment(model)
                .environment(mcp)
                .environment(assistant)
                .task {
                    // The Model is the single CAD tool provider (T48) for MCP clients and the in-app chat.
                    let tools = (model as AnyObject) as? CADToolProvider
                    mcp.attach(tools)
                    assistant.tools = tools
                    mcp.start()
                }
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuovo design") { model.newDesign() }.keyboardShortcut("n")
                Button("Apri…") { model.openWithPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Salva…") { model.saveWithPanel() }.keyboardShortcut("s")
                Button("Esporta STL…") { model.exportSTLWithPanel() }.keyboardShortcut("e")
            }
        }
        Settings {
            AssistantSettingsView()
                .environment(assistant)
        }
    }
}
