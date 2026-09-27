import CADCore

/// What SketchSession needs from the app's model layer (the real one lives in DesignModel.swift).
@MainActor
protocol LocalUndoTarget: AnyObject {
    var canUndoLocally: Bool { get }
    var canRedoLocally: Bool { get }
    var localUndoTitle: String? { get }
    var localRedoTitle: String? { get }
    func undoLocally()
    func redoLocally()
}
