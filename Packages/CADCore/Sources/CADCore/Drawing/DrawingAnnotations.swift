import Foundation

/// What the user changed on the technical drawing, saved with the design: dimensions added by
/// hand, and automatic ones moved or taken off. The drawing itself is always regenerated from
/// the model; these are applied on top.
public struct DrawingAnnotations: Codable, Equatable, Sendable {
    public var dimensions: [DrawingDimension] = []
    /// Automatic dimensions moved away from (or towards) the view: their key → sheet mm added
    /// to their distance.
    public var moved: [String: Double] = [:]
    /// Automatic dimensions taken off the sheet, by key.
    public var hidden: [String] = []
    public init(dimensions: [DrawingDimension] = [], moved: [String: Double] = [:], hidden: [String] = []) {
        self.dimensions = dimensions; self.moved = moved; self.hidden = hidden
    }
    public var isEmpty: Bool { dimensions.isEmpty && moved.isEmpty && hidden.isEmpty }
}

/// A dimension added by hand between two points of an orthographic view.
public struct DrawingDimension: Codable, Equatable, Sendable, Identifiable {
    public enum View: String, Codable, Sendable, CaseIterable { case front, top, left }
    public enum Direction: String, Codable, Sendable { case horizontal, vertical, aligned }
    public var id: UUID
    public var view: View
    /// The measured points in the view's own coordinates (model mm along the view's right and
    /// up): they stay put when the sheet's scale or layout changes.
    public var a: Vec2, b: Vec2
    public var direction: Direction
    /// Sheet mm from the farther measured point to the dimension line; the sign picks the side
    /// (above/right/left of a→b for aligned ones when positive).
    public var offset: Double
    public init(id: UUID = UUID(), view: View, a: Vec2, b: Vec2, direction: Direction, offset: Double) {
        self.id = id; self.view = view; self.a = a; self.b = b; self.direction = direction; self.offset = offset
    }

    /// The measured length in model mm.
    public var value: Double {
        switch direction {
        case .horizontal: abs(b.x - a.x)
        case .vertical: abs(b.y - a.y)
        case .aligned: (b - a).length
        }
    }
}

extension DrawingSheet {
    /// An orthographic view as placed on the sheet: view coordinates (model mm) → sheet mm.
    public struct ViewPlacement: Sendable {
        public var view: DrawingDimension.View
        public var origin: Vec2, extentMin: Vec2, extentMax: Vec2, scale: Double
        public func sheet(_ p: Vec2) -> Vec2 { Vec2(origin.x + (p.x - extentMin.x) * scale, origin.y + (p.y - extentMin.y) * scale) }
        public func local(_ q: Vec2) -> Vec2 { Vec2(extentMin.x + (q.x - origin.x) / scale, extentMin.y + (q.y - origin.y) / scale) }
        /// The view's box on the sheet.
        public var box: (min: Vec2, max: Vec2) { (sheet(extentMin), sheet(extentMax)) }
    }

    /// A point a dimension can start or end on: a visible edge's end or middle, a circle's centre.
    public struct SnapPoint: Sendable, Equatable {
        public var view: DrawingDimension.View
        public var local: Vec2
        public var at: Vec2
    }

    /// A dimension as drawn: what to hit (its line and text) and how dragging it moves it
    /// (along `side`, sheet mm).
    public struct DimensionMark: Sendable, Equatable {
        public var key: String
        /// A dimension added by hand (else automatic: moved or hidden by key).
        public var manual: UUID?
        public var line: (Vec2, Vec2)
        public var text: Vec2
        public var side: Vec2
        public static func == (l: Self, r: Self) -> Bool {
            l.key == r.key && l.manual == r.manual && l.line.0 == r.line.0 && l.line.1 == r.line.1 && l.text == r.text && l.side == r.side
        }
        /// Distance from a sheet point to the dimension (its line or its text).
        public func distance(to p: Vec2) -> Double {
            let d = line.1 - line.0, len2 = max(d.dot(d), 1e-12)
            let u = max(0, min(1, (p - line.0).dot(d) / len2))
            return min((line.0 + d * u - p).length, (text - p).length)
        }
    }
}
