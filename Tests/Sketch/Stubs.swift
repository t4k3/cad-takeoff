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

/// SketchSession names the entities in its undo steps; the app localizes that in
/// SketchInspector.swift, which is not compiled here.
extension SketchShape {
    var localizedTypeName: String {
        switch kind {
        case let .polyline(points, closed):
            closed ? "Profilo" : (points.count == 2 ? "Linea" : "Polilinea")
        case .rectangle: "Rettangolo"
        case .circle: "Cerchio"
        case let .polygon(_, _, n, _, _): "Poligono (\(n) lati)"
        case .slot: "Asola"
        case .arc: "Arco"
        case .spline: "Spline"
        case .bezier: "Curva di Bezier"
        case .point3D: "Punto 3D"
        case .line3D: "Linea 3D"
        case .workplane: "Piano di lavoro"
        }
    }
}
