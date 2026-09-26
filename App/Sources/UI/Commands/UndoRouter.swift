import AppKit
import SwiftUI

/// Where ⌘Z / ⇧⌘Z go: the text field being edited, then the open sketch, then the design history.
@MainActor
enum UndoRouter {
    private static var editingText: NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor else { return nil }
        return tv
    }

    static func canUndo(_ model: DesignModel) -> Bool {
        if editingText?.undoManager?.canUndo == true { return true }
        if let local = model.localUndoTarget { return local.canUndoLocally }
        return model.canUndo
    }

    static func canRedo(_ model: DesignModel) -> Bool {
        if editingText?.undoManager?.canRedo == true { return true }
        if let local = model.localUndoTarget { return local.canRedoLocally }
        return model.canRedo
    }

    static func undoTitle(_ model: DesignModel) -> String {
        if let local = model.localUndoTarget { return local.localUndoTitle.map { "Annulla \($0)" } ?? "Annulla" }
        return model.undoTitle.map { "Annulla \($0)" } ?? "Annulla"
    }

    static func redoTitle(_ model: DesignModel) -> String {
        if let local = model.localUndoTarget { return local.localRedoTitle.map { "Ripeti \($0)" } ?? "Ripeti" }
        return model.redoTitle.map { "Ripeti \($0)" } ?? "Ripeti"
    }

    static func undo(_ model: DesignModel) {
        if let um = editingText?.undoManager, um.canUndo { um.undo(); return }
        if let local = model.localUndoTarget { local.undoLocally(); return }
        model.undo()
    }

    static func redo(_ model: DesignModel) {
        if let um = editingText?.undoManager, um.canRedo { um.redo(); return }
        if let local = model.localUndoTarget { local.redoLocally(); return }
        model.redo()
    }
}

/// Asks before quitting with unsaved changes; closing the only window quits the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var confirmQuit: () -> Bool = { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.confirmQuit() } ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Edit-menu items as a View, so their titles and enabled state follow the observed model.
struct UndoMenuItems: View {
    let model: DesignModel

    var body: some View {
        Button(UndoRouter.undoTitle(model)) { UndoRouter.undo(model) }
            .keyboardShortcut("z")
            .disabled(!UndoRouter.canUndo(model))
        Button(UndoRouter.redoTitle(model)) { UndoRouter.redo(model) }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!UndoRouter.canRedo(model))
    }
}
