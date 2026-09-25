import Foundation

/// ASCII DXF (AC1015), millimetres: one closed CUT outline, bend centre and tangent lines.
/// No hole, relief, nesting, tooling or machine-angle claims are made by this base exporter.
public enum SheetMetalDXF {
    public static func export(_ pattern: SheetMetalFlatPattern, for part: SheetMetalPart) throws -> String {
        _ = try part.validatedParameters()
        guard pattern.isCurrent(for: part) else { throw SheetMetalError.staleFlatPattern }
        var records: [String] = []
        func put(_ code: Int, _ value: String) { records += [String(code), value] }
        func number(_ value: Double) -> String {
            value == 0 ? "0" : String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        put(999, "Fusion Takeoff sheet metal \(part.id.uuidString) revision \(part.revision)")
        put(0, "SECTION"); put(2, "HEADER")
        put(9, "$ACADVER"); put(1, "AC1015")
        put(9, "$INSUNITS"); put(70, "4")
        put(9, "$MEASUREMENT"); put(70, "1")
        put(0, "ENDSEC")
        put(0, "SECTION"); put(2, "TABLES")
        put(0, "TABLE"); put(2, "LTYPE"); put(70, "1")
        put(0, "LTYPE"); put(100, "AcDbSymbolTableRecord"); put(100, "AcDbLinetypeTableRecord")
        put(2, "CONTINUOUS"); put(70, "0"); put(3, "Solid line"); put(72, "65"); put(73, "0"); put(40, "0")
        put(0, "ENDTAB")
        let layers = [("0", 7), ("CUT", 7), ("BEND_UP", 1), ("BEND_DOWN", 5), ("BEND_TANGENT", 8)]
        put(0, "TABLE"); put(2, "LAYER"); put(70, String(layers.count))
        for (name, color) in layers {
            put(0, "LAYER"); put(100, "AcDbSymbolTableRecord"); put(100, "AcDbLayerTableRecord")
            put(2, name); put(70, "0"); put(62, String(color)); put(6, "CONTINUOUS")
        }
        put(0, "ENDTAB"); put(0, "ENDSEC")
        put(0, "SECTION"); put(2, "ENTITIES")
        put(0, "LWPOLYLINE"); put(100, "AcDbEntity"); put(8, "CUT"); put(100, "AcDbPolyline")
        put(90, String(pattern.outline.points.count)); put(70, "1")
        for point in pattern.outline.points { put(10, number(point.x)); put(20, number(point.y)) }
        func line(_ x: Double, _ layer: String) {
            put(0, "LINE"); put(100, "AcDbEntity"); put(8, layer); put(100, "AcDbLine")
            put(10, number(x)); put(20, number(-pattern.width / 2)); put(30, "0")
            put(11, number(x)); put(21, number(pattern.width / 2)); put(31, "0")
        }
        for zone in pattern.bendZones {
            put(999, "Bend \(zone.operationID.uuidString) rotation_deg=\(number(zone.angleDegrees)) inside_radius_mm=\(number(zone.insideRadius))")
            line(zone.centerX, zone.direction == .up ? "BEND_UP" : "BEND_DOWN")
            line(zone.startX, "BEND_TANGENT"); line(zone.endX, "BEND_TANGENT")
        }
        put(0, "ENDSEC"); put(0, "EOF")
        return records.joined(separator: "\n") + "\n"
    }
}
