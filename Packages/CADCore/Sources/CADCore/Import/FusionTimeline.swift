import Foundation

/// A Fusion 360 design's history as the «Esporta per CAD Takeoff» add-in writes it next to the
/// bodies' meshes in the .ftk (key `fusion`): parameters, sketches with their constraints and
/// dimensions, features, and the final bodies to check the rebuilt ones against.
/// Millimetres and degrees; sketch coordinates in each sketch's own plane.
public struct FusionTimeline: Codable, Sendable, Equatable {
    public var version: Int
    public var parameters: [Parameter]
    public var sketches: [Sketch]
    public var features: [Feature]
    public var bodies: [Body]

    public init(version: Int = 1, parameters: [Parameter] = [], sketches: [Sketch] = [], features: [Feature] = [], bodies: [Body] = []) {
        self.version = version; self.parameters = parameters; self.sketches = sketches; self.features = features; self.bodies = bodies
    }

    public struct Parameter: Codable, Sendable, Equatable {
        public var name: String
        /// As written in Fusion ("40 mm", "larghezza / 2", "30 deg").
        public var expression: String
        /// Value in mm or degrees.
        public var value: Double
        public var comment: String?
        /// A user parameter (shown in «Parametri»); model parameters (d1, d2…) are only inlined.
        public var isUser: Bool

        public init(name: String, expression: String, value: Double, comment: String? = nil, isUser: Bool) {
            self.name = name; self.expression = expression; self.value = value; self.comment = comment; self.isUser = isUser
        }
    }

    public struct Point: Codable, Sendable, Equatable {
        public var id: String
        public var x: Double, y: Double
        public var fixed: Bool?
        public init(id: String, x: Double, y: Double, fixed: Bool? = nil) { self.id = id; self.x = x; self.y = y; self.fixed = fixed }
    }

    public struct Curve: Codable, Sendable, Equatable {
        /// line, circle, arc (counter-clockwise from `start` to `end` about the sketch normal),
        /// spline (through `points`), polyline (any other curve, drawn as `polyline`).
        public var type: String
        public var id: String
        public var construction: Bool?
        public var start: String?, end: String?, center: String?
        public var radius: Double?
        public var points: [String]?
        public var polyline: [[Double]]?
        public var closed: Bool?

        public init(type: String, id: String, construction: Bool? = nil, start: String? = nil, end: String? = nil, center: String? = nil,
                    radius: Double? = nil, points: [String]? = nil, polyline: [[Double]]? = nil, closed: Bool? = nil) {
            self.type = type; self.id = id; self.construction = construction; self.start = start; self.end = end; self.center = center
            self.radius = radius; self.points = points; self.polyline = polyline; self.closed = closed
        }
    }

    public struct Constraint: Codable, Sendable, Equatable {
        /// horizontal, vertical, coincident, parallel, perpendicular, tangent, equal, concentric,
        /// midpoint, symmetry.
        public var type: String
        public var a: String?, b: String?, c: String?
        public init(type: String, a: String? = nil, b: String? = nil, c: String? = nil) { self.type = type; self.a = a; self.b = b; self.c = c }
    }

    public struct Dimension: Codable, Sendable, Equatable {
        /// distance (aligned), horizontal, vertical, diameter, radius, angle.
        public var type: String
        public var a: String
        public var b: String?
        public var value: Double
        public var expression: String?
        public init(type: String, a: String, b: String? = nil, value: Double, expression: String? = nil) {
            self.type = type; self.a = a; self.b = b; self.value = value; self.expression = expression
        }
    }

    public struct Profile: Codable, Sendable, Equatable {
        public var id: String
        public var area: Double
        public var min: [Double], max: [Double]
        public init(id: String, area: Double, min: [Double], max: [Double]) { self.id = id; self.area = area; self.min = min; self.max = max }
    }

    public struct Sketch: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var origin: [Double], xAxis: [Double], yAxis: [Double]
        public var points: [Point]
        public var curves: [Curve]
        public var constraints: [Constraint]?
        public var dimensions: [Dimension]?
        public var profiles: [Profile]?

        public init(id: String, name: String, origin: [Double] = [0, 0, 0], xAxis: [Double] = [1, 0, 0], yAxis: [Double] = [0, 1, 0],
                    points: [Point] = [], curves: [Curve] = [], constraints: [Constraint]? = nil, dimensions: [Dimension]? = nil,
                    profiles: [Profile]? = nil) {
            self.id = id; self.name = name; self.origin = origin; self.xAxis = xAxis; self.yAxis = yAxis; self.points = points
            self.curves = curves; self.constraints = constraints; self.dimensions = dimensions; self.profiles = profiles
        }
    }

    public struct Extent: Codable, Sendable, Equatable {
        /// distance, symmetric (total distance), through (all), twoSides, or Fusion's own name of
        /// an extent not described here (to an object…).
        public var type: String
        public var distance: Double?
        public var expression: String?
        public var reversed: Bool?
        public var taper: Double?
        /// twoSides: the second side's distance.
        public var distance2: Double?
        public var expression2: String?
        /// Offset start: how far from the sketch it starts (mm along the normal); another kind of
        /// start (from an object) by name.
        public var start: Double?
        public var startExpression: String?
        public var startType: String?
        /// Where it really starts and ends along the sketch's normal (mm), measured by Fusion on
        /// the result: any extent comes in right from these.
        public var measuredStart: Double?
        public var measuredEnd: Double?
        public init(type: String, distance: Double? = nil, expression: String? = nil, reversed: Bool? = nil, taper: Double? = nil,
                    distance2: Double? = nil, expression2: String? = nil, start: Double? = nil, startExpression: String? = nil,
                    startType: String? = nil, measuredStart: Double? = nil, measuredEnd: Double? = nil) {
            self.type = type; self.distance = distance; self.expression = expression; self.reversed = reversed; self.taper = taper
            self.distance2 = distance2; self.expression2 = expression2; self.start = start; self.startExpression = startExpression
            self.startType = startType; self.measuredStart = measuredStart; self.measuredEnd = measuredEnd
        }
    }

    public struct Axis: Codable, Sendable, Equatable {
        /// A line of the profile's sketch, or a world axis (origin and direction, mm).
        public var curve: String?
        public var origin: [Double]?, direction: [Double]?
        public init(curve: String? = nil, origin: [Double]? = nil, direction: [Double]? = nil) { self.curve = curve; self.origin = origin; self.direction = direction }
    }

    public struct Feature: Codable, Sendable, Equatable {
        /// extrude, revolve, fillet, chamfer, hole, shell; anything else is kept as `type` and
        /// reported as not converted.
        public var type: String
        public var name: String
        /// newBody, join, cut, intersect.
        public var operation: String?
        /// "<sketch id>/<profile id>".
        public var profiles: [String]?
        public var extent: Extent?
        public var axis: Axis?
        public var angle: Double?
        public var angleExpression: String?
        /// Fillet/chamfer: each edge as points along it (world, mm).
        public var edges: [[[Double]]]?
        public var size: Double?
        public var sizeExpression: String?
        /// Hole: centres (world), drilling direction, diameter, depth (nil = through).
        public var centers: [[Double]]?
        public var direction: [Double]?
        public var diameter: Double?
        public var depth: Double?
        /// Shell: a point and the normal of each removed face (world).
        public var faces: [[[Double]]]?
        /// Hole: simple, counterbore, countersink; head (counterbore/countersink) diameter,
        /// counterbore depth, countersink angle; each hole's own direction and depth (nil: through).
        public var style: String?
        public var headDiameter: Double?
        public var counterboreDepth: Double?
        public var countersinkAngle: Double?
        public var diameterExpression: String?
        public var directions: [[Double]]?
        public var depths: [Double?]?
        /// Pattern / mirror: the features copied (by name), what else was given (bodies, faces:
        /// not converted), and each copy's placement in the world (3 rows: rotation | translation).
        public var inputs: [String]?
        public var inputKind: String?
        public var transforms: [[[Double]]]?
        /// Combine: the target and tool bodies as they were just before it (volume and extent, to
        /// find them among the rebuilt ones), and whether the tools stay.
        public var targetBody: Body?
        public var toolBodies: [Body]?
        public var keepTools: Bool?
        /// Pattern / mirror of bodies: the bodies copied as they were just before it.
        public var inputBodies: [Body]?

        public init(type: String, name: String, operation: String? = nil, profiles: [String]? = nil, extent: Extent? = nil, axis: Axis? = nil,
                    angle: Double? = nil, angleExpression: String? = nil, edges: [[[Double]]]? = nil, size: Double? = nil,
                    sizeExpression: String? = nil, centers: [[Double]]? = nil, direction: [Double]? = nil, diameter: Double? = nil,
                    depth: Double? = nil, faces: [[[Double]]]? = nil) {
            self.type = type; self.name = name; self.operation = operation; self.profiles = profiles; self.extent = extent; self.axis = axis
            self.angle = angle; self.angleExpression = angleExpression; self.edges = edges; self.size = size; self.sizeExpression = sizeExpression
            self.centers = centers; self.direction = direction; self.diameter = diameter; self.depth = depth; self.faces = faces
        }
    }

    /// A body of the finished design: to check the rebuilt one, and its mesh (the index of its
    /// imported-mesh step in the .ftk) to fall back on.
    public struct Body: Codable, Sendable, Equatable {
        public var name: String
        public var volume: Double
        public var min: [Double], max: [Double]
        public var mesh: Int?
        public init(name: String, volume: Double, min: [Double], max: [Double], mesh: Int? = nil) {
            self.name = name; self.volume = volume; self.min = min; self.max = max; self.mesh = mesh
        }
    }
}
