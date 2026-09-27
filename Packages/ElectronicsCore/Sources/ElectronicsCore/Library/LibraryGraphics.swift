import Foundation

/// Semantic geometry for a future UI; no presentation colours or UI framework dependencies.
public struct LibraryGraphic: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case line, rectangle, circle, arc, polyline }
    public var id: UUID
    public var kind: Kind
    /// line/rectangle/circle: two points; arc: start/mid/end; polyline: 2+ points.
    public var points: [PCBPoint]
    public var layer: String
    public var strokeWidth: Double
    public var filled: Bool
    public init(id: UUID, kind: Kind, points: [PCBPoint], layer: String, strokeWidth: Double, filled: Bool = false) {
        self.id = id; self.kind = kind; self.points = points; self.layer = layer
        self.strokeWidth = strokeWidth; self.filled = filled
    }
}

enum LibraryGraphics {
    static func validate(_ graphics: [LibraryGraphic], subject: String) -> [ElectronicsIssue] {
        var issues: [ElectronicsIssue] = []
        if Set(graphics.map(\.id)).count != graphics.count { issues.append(.init("duplicate_graphic", subject, "Identità grafiche duplicate.")) }
        for g in graphics {
            let countOK: Bool
            switch g.kind {
            case .line, .rectangle, .circle: countOK = g.points.count == 2
            case .arc: countOK = g.points.count == 3
            case .polyline: countOK = g.points.count >= 2
            }
            if !countOK || !g.points.allSatisfy(ElectronicsGeometry.valid) || !ElectronicsGeometry.valid(g.strokeWidth) || g.strokeWidth < 0 {
                var issue = ElectronicsIssue("invalid_graphic", subject, "Geometria grafica non valida: controllare punti e spessore.")
                issue.subjectIDs = [g.id]; issues.append(issue)
            }
        }
        return issues
    }
}
