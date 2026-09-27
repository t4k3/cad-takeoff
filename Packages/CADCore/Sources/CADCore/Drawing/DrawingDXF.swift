import Foundation

/// A drawing sheet as DXF R12 (mm): one layer per line kind with its ISO line type, arrows as
/// solids, texts with their rotation. Opens in LibreCAD, AutoCAD, DraftSight and CAM programs.
public enum DrawingDXF {
    static let layers: [(DrawingSheet.Style, String, String, Int)] = [
        (.visible, "VISIBILI", "CONTINUOUS", 7), (.hidden, "NASCOSTE", "DASHED", 8), (.thin, "QUOTE", "CONTINUOUS", 3),
        (.center, "ASSI", "CENTER", 1), (.border, "CORNICE", "CONTINUOUS", 7),
    ]

    /// DXF text: Ø and ° as the %%c and %%d codes, other non-ASCII letters as \U+XXXX.
    static func encoded(_ text: String) -> String {
        var out = ""
        for ch in text.unicodeScalars {
            switch ch {
            case "Ø", "⌀": out += "%%c"
            case "°": out += "%%d"
            default: out += ch.isASCII ? String(ch) : String(format: "\\U+%04X", ch.value)
            }
        }
        return out
    }

    public static func dxf(_ sheet: DrawingSheet) -> String {
        var o: [String] = []
        func g(_ code: Int, _ value: String) { o.append(String(code)); o.append(value) }
        func r(_ v: Double) -> String { String(format: "%.4f", v) }
        g(0, "SECTION"); g(2, "HEADER")
        g(9, "$ACADVER"); g(1, "AC1009")
        g(9, "$INSUNITS"); g(70, "4")
        g(9, "$EXTMIN"); g(10, "0"); g(20, "0")
        g(9, "$EXTMAX"); g(10, r(sheet.width)); g(20, r(sheet.height))
        g(0, "ENDSEC")
        g(0, "SECTION"); g(2, "TABLES")
        g(0, "TABLE"); g(2, "LTYPE"); g(70, "3")
        for (name, text, pattern) in [("CONTINUOUS", "Continua", [Double]()), ("DASHED", "Tratteggiata __ __", [3, -1.5]),
                                      ("CENTER", "Tratto e punto ____ . ____", [8, -1.5, 1, -1.5])] {
            g(0, "LTYPE"); g(2, name); g(70, "0"); g(3, text); g(72, "65"); g(73, String(pattern.count)); g(40, r(pattern.map(abs).reduce(0, +)))
            for p in pattern { g(49, r(p)) }
        }
        g(0, "ENDTAB")
        g(0, "TABLE"); g(2, "LAYER"); g(70, String(layers.count + 1))
        for (_, name, type, colour) in layers + [(.thin, "TESTI", "CONTINUOUS", 7)] {
            g(0, "LAYER"); g(2, name); g(70, "0"); g(62, String(colour)); g(6, type)
        }
        g(0, "ENDTAB")
        g(0, "ENDSEC")
        g(0, "SECTION"); g(2, "ENTITIES")
        for l in sheet.lines {
            let layer = layers.first { $0.0 == l.style }!.1
            g(0, "LINE"); g(8, layer); g(10, r(l.a.x)); g(20, r(l.a.y)); g(30, "0"); g(11, r(l.b.x)); g(21, r(l.b.y)); g(31, "0")
        }
        for a in sheet.arrows where a.count == 3 {
            g(0, "SOLID"); g(8, "QUOTE")
            g(10, r(a[0].x)); g(20, r(a[0].y)); g(30, "0"); g(11, r(a[1].x)); g(21, r(a[1].y)); g(31, "0")
            g(12, r(a[2].x)); g(22, r(a[2].y)); g(32, "0"); g(13, r(a[2].x)); g(23, r(a[2].y)); g(33, "0")
        }
        for t in sheet.texts {
            // Centred and right-aligned texts use the second alignment point (R12: 72 = 1 or 2).
            let align = t.align == .left ? 0 : (t.align == .center ? 1 : 2)
            g(0, "TEXT"); g(8, "TESTI"); g(10, r(t.at.x)); g(20, r(t.at.y)); g(30, "0"); g(40, r(t.size)); g(1, encoded(t.text))
            if t.angle != 0 { g(50, r(t.angle)) }
            if align != 0 { g(72, String(align)); g(11, r(t.at.x)); g(21, r(t.at.y)); g(31, "0") }
        }
        g(0, "ENDSEC")
        g(0, "EOF")
        return o.joined(separator: "\n") + "\n"
    }
}
