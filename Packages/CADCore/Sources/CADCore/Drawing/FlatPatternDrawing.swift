import Foundation

extension TechnicalDrawing {
    /// Workshop sheet of a sheet-metal part's flat pattern: the blank to cut with its holes, bend
    /// lines (up/down), overall size and bend positions, a bend table for the press brake and a
    /// hole table for the laser.
    public static func flatPattern(_ flat: SheetFlatPattern, rule: SheetBendRule, info: Info, format: SheetFormat = .a4) throws -> DrawingSheet {
        guard flat.outline.count >= 3 else { throw KernelError.invalidParameter("sviluppo vuoto") }
        let (W, H) = format.size
        var sheet = DrawingSheet(width: W, height: H)
        let frame = (x0: 20.0, y0: 10.0, x1: W - 10, y1: H - 10)
        rect(&sheet, frame.x0, frame.y0, frame.x1, frame.y1, .border)
        let titleH = 36.0
        let xs = flat.outline.map(\.x), ys = flat.outline.map(\.y)
        let lo = Vec2(xs.min()!, ys.min()!), hi = Vec2(xs.max()!, ys.max()!)
        let size = hi - lo
        // Bend lines split by direction: vertical ones are dimensioned along X, horizontal along Y.
        let vertical = flat.bends.filter { abs($0.line.0.x - $0.line.1.x) < 1e-6 }
        let horizontal = flat.bends.filter { abs($0.line.0.y - $0.line.1.y) < 1e-6 }
        let roomX = 10 + 6 * Double(horizontal.count), roomY = 10 + 6 * Double(vertical.count)
        let availW = frame.x1 - frame.x0 - 40 - roomX, availH = frame.y1 - frame.y0 - titleH - 30 - roomY
        let fit = min(availW / max(size.x, 1e-6), availH / max(size.y, 1e-6))
        guard let (scale, label) = scales.first(where: { $0.0 <= fit }) else { throw KernelError.invalidParameter("sviluppo troppo grande per il foglio") }
        let origin = Vec2(frame.x0 + 25 + roomX, frame.y0 + titleH + 20 + roomY)
        func at(_ p: Vec2) -> Vec2 { origin + (p - lo) * scale }

        for i in flat.outline.indices {
            sheet.lines.append(.init(a: at(flat.outline[i]), b: at(flat.outline[(i + 1) % flat.outline.count]), style: .visible))
        }
        for c in flat.cutouts {
            for i in c.indices { sheet.lines.append(.init(a: at(c[i]), b: at(c[(i + 1) % c.count]), style: .visible)) }
        }
        for h in flat.holes {
            let r = h.diameter / 2
            for k in 0..<48 {
                let t0 = Double(k) / 48 * 2 * .pi, t1 = Double(k + 1) / 48 * 2 * .pi
                sheet.lines.append(.init(a: at(h.center + Vec2(cos(t0), sin(t0)) * r), b: at(h.center + Vec2(cos(t1), sin(t1)) * r), style: .visible))
            }
        }
        // Bends: centre line (dash-dot), bend-zone tangents (dashed), a label on each.
        for (k, b) in flat.bends.enumerated() {
            sheet.lines.append(.init(a: at(b.line.0), b: at(b.line.1), style: .center))
            for t in b.tangents { sheet.lines.append(.init(a: at(t.0), b: at(t.1), style: .hidden)) }
            let mid = at((b.line.0 + b.line.1) * 0.5)
            let along = (b.line.1 - b.line.0).normalized
            let angle = atan2(along.y, along.x) * 180 / .pi
            let upright = angle > 90 || angle <= -90 ? angle + 180 : angle
            // Beside the bend zone, clear of its lines.
            let side = Vec2(-sin(upright * .pi / 180), cos(upright * .pi / 180))
            let band = b.tangents.map { t in abs((t.0 - b.line.0).x * -along.y + (t.0 - b.line.0).y * along.x) }.max() ?? 0
            sheet.texts.append(.init(at: mid + side * (band * scale + 1.2),
                                     text: "P\(k + 1) \(b.direction == .up ? "SU" : "GIÙ") \(number(b.angle))°", size: 2.8, align: .center, angle: upright))
        }
        // Overall size, then each bend line's position from the lower-left corner.
        dimension(&sheet, from: at(lo), to: at(Vec2(hi.x, lo.y)), offset: -8, value: size.x)
        dimension(&sheet, from: at(lo), to: at(Vec2(lo.x, hi.y)), offset: 8, value: size.y)
        for (k, b) in vertical.sorted(by: { $0.line.0.x < $1.line.0.x }).enumerated() {
            dimension(&sheet, from: at(Vec2(lo.x, hi.y)), to: at(Vec2(b.line.0.x, hi.y)), offset: 8 + 6 * Double(k), value: b.line.0.x - lo.x)
        }
        for (k, b) in horizontal.sorted(by: { $0.line.0.y < $1.line.0.y }).enumerated() {
            dimension(&sheet, from: at(Vec2(hi.x, lo.y)), to: at(Vec2(hi.x, b.line.0.y)), offset: -(8 + 6 * Double(k)), value: b.line.0.y - lo.y)
        }
        sheet.texts.append(.init(at: at(lo) + Vec2(-1.5, -4), text: "0,0", size: 2.5, align: .right))

        // Bend table and hole table, bottom left beside the title block.
        func table(_ rows: [[String]], widths: [Double], x0: Double, bottom: Double) -> Double {
            let rowH = 5.0, width = widths.reduce(0, +), top = bottom + rowH * Double(rows.count)
            for (r, row) in rows.enumerated() {
                let y = top - rowH * Double(r + 1)
                var x = x0
                for (k, text) in row.enumerated() {
                    sheet.texts.append(.init(at: Vec2(x + widths[k] / 2, y + 1.4), text: text, size: r == 0 ? 2.3 : 2.6, align: .center))
                    x += widths[k]
                }
                sheet.lines.append(.init(a: Vec2(x0, y), b: Vec2(x0 + width, y), style: r == 0 ? .visible : .thin))
            }
            rect(&sheet, x0, bottom, x0 + width, top, .visible)
            var x = x0
            for w in widths.dropLast() { x += w; sheet.lines.append(.init(a: Vec2(x, bottom), b: Vec2(x, top), style: .thin)) }
            return top
        }
        var bottom = frame.y0 + 4
        if !flat.holes.isEmpty, flat.holes.count <= 12 {
            let rows = [["Foro", "X", "Y", "Ø"]] + flat.holes.enumerated().map { k, h in
                ["F\(k + 1)", number(h.center.x - lo.x), number(h.center.y - lo.y), number(h.diameter)]
            }
            bottom = table(rows, widths: [12, 18, 18, 16], x0: frame.x0 + 4, bottom: bottom) + 3
            for (k, h) in flat.holes.enumerated() {
                sheet.texts.append(.init(at: at(h.center) + Vec2(h.diameter / 2 * scale + 1, h.diameter / 2 * scale), text: "F\(k + 1)", size: 2.6, align: .left))
            }
        }
        if !flat.bends.isEmpty {
            let rows = [["Piega", "Verso", "Angolo", "R int."]] + flat.bends.enumerated().map { k, b in
                ["P\(k + 1)", b.direction == .up ? "su" : "giù", number(b.angle) + "°", number(b.insideRadius)]
            }
            _ = table(rows, widths: [12, 14, 16, 22], x0: frame.x0 + 4, bottom: bottom)
        }
        let note = "\(rule.material.name) sp. \(number(rule.thickness)) · K \(String(format: "%.3f", rule.kFactor)) · matrice V\(number(rule.vDie)) · sviluppo \(number(size.x))×\(number(size.y))"
        sheet.texts.append(.init(at: Vec2(frame.x1 - 180, frame.y0 + titleH + 3), text: note, size: 2.6, align: .left))
        var titled = info
        if titled.material.isEmpty { titled.material = "\(rule.material.name) sp. \(number(rule.thickness)) mm" }
        titleBlock(&sheet, x1: frame.x1, y0: frame.y0, width: 180, height: titleH, info: titled, scale: label, format: format)
        sheet.texts.append(.init(at: Vec2(frame.x0 + 4, frame.y1 - 6), text: "SVILUPPO", size: 3.5, align: .left))
        return sheet
    }
}
