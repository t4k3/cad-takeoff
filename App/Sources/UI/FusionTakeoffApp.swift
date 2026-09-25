import SwiftUI

@main
struct FusionTakeoffApp: App {
    @State private var model = DesignModel()

    var body: some Scene {
        WindowGroup("Fusion Takeoff") {
            WorkspaceView()
                .environment(model)
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
    }
}
