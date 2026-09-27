import Foundation

/// A drawing sheet as a one-page vector PDF (no dependencies): ISO line widths, dashed hidden
/// lines, Helvetica text in WinAnsi (accents, Ø, °).
public enum PDFWriter {
    public static func pdf(_ sheet: DrawingSheet) -> Data {
        let k = 72 / 25.4   // points per mm
        func n(_ v: Double) -> String { String(format: "%.3f", v * k) }
        var c = ""
        c += "1 J 1 j\n"
        let widths: [DrawingSheet.Style: Double] = [.visible: 0.5, .hidden: 0.25, .thin: 0.18, .border: 0.7, .center: 0.18]
        for style in [DrawingSheet.Style.border, .visible, .hidden, .thin, .center] {
            let lines = sheet.lines.filter { $0.style == style }
            guard !lines.isEmpty else { continue }
            c += "\(n(widths[style]!)) w\n"
            switch style {
            case .hidden: c += "[\(n(3)) \(n(1.5))] 0 d\n"
            case .center: c += "[\(n(8)) \(n(1.5)) \(n(1)) \(n(1.5))] 0 d\n"
            default: c += "[] 0 d\n"
            }
            for l in lines { c += "\(n(l.a.x)) \(n(l.a.y)) m \(n(l.b.x)) \(n(l.b.y)) l S\n" }
        }
        c += "[] 0 d\n"
        for a in sheet.arrows where a.count == 3 {
            c += "\(n(a[0].x)) \(n(a[0].y)) m \(n(a[1].x)) \(n(a[1].y)) l \(n(a[2].x)) \(n(a[2].y)) l h f\n"
        }
        for t in sheet.texts {
            let size = t.size * k
            // Helvetica average width ≈ 0.52 em: enough to centre or right-align.
            let width = Double(t.text.count) * size * 0.52
            let shift = t.align == .left ? 0 : (t.align == .center ? -width / 2 : -width)
            let a = t.angle * .pi / 180
            let x = t.at.x * k + shift * cos(a), y = t.at.y * k + shift * sin(a)
            c += "BT /F1 \(String(format: "%.2f", size)) Tf \(String(format: "%.4f %.4f %.4f %.4f %.3f %.3f", cos(a), sin(a), -sin(a), cos(a), x, y)) Tm (\(escaped(t.text))) Tj ET\n"
        }
        let stream = Data(c.utf8)
        var objects: [Data] = []
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(sheet.width)) \(n(sheet.height))] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".utf8))
        objects.append(Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        var out = Data("%PDF-1.4\n%\u{e2}\u{e3}\u{cf}\u{d3}\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Data("\(i + 1) 0 obj\n".utf8) + o + Data("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out += Data(table.utf8)
        return out
    }

    /// PDF string: WinAnsi bytes, escaped; characters outside it become «?».
    static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "(", ")", "\\": out += "\\" + String(ch)
            default:
                if ch.value < 128 { out.unicodeScalars.append(ch) }
                else if let b = winAnsi[ch.value] { out += String(format: "\\%03o", b) }
                else if ch.value < 256 { out += String(format: "\\%03o", ch.value) }
                else { out += "?" }
            }
        }
        return out
    }

    /// WinAnsi code points above Latin-1 that differ from Unicode.
    static let winAnsi: [UInt32: Int] = [0x20AC: 0x80, 0x2019: 0x92, 0x2018: 0x91, 0x201C: 0x93, 0x201D: 0x94, 0x2013: 0x96, 0x2014: 0x97, 0x2022: 0x95]
}
