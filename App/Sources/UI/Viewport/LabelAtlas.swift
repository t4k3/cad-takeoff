import AppKit
import Metal
import simd

/// Fonts, padding and box size of the on-canvas labels (constraint symbols and dimension values).
/// The renderer and the SwiftUI hit areas measure with the same code, so a click always lands on
/// the box that is drawn.
enum LabelText {
    enum Style: Hashable, Sendable {
        case dimension
        case constraint

        var font: NSFont {
            switch self {
            case .dimension: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            case .constraint: .systemFont(ofSize: 10.5, weight: .bold)
            }
        }

        var padding: CGSize {
            switch self {
            case .dimension: CGSize(width: 6, height: 2)
            case .constraint: CGSize(width: 4, height: 2)
            }
        }

        var cornerRadius: Float { 4 }
    }

    /// Size of the run itself (no padding), rounded up to whole points.
    static func textSize(_ text: String, _ style: Style) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: style.font])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Size of the whole label, padding included: what the viewport shows and what is clickable.
    static func boxSize(_ text: String, _ style: Style) -> CGSize {
        let text = textSize(text, style)
        return CGSize(width: text.width + 2 * style.padding.width,
                      height: text.height + 2 * style.padding.height)
    }
}

/// One texture shared by every label: each run is rasterized once (at the backing scale) and
/// packed into it, then drawn by the renderer as a textured quad. A camera move or a hover costs
/// no text layout and no CoreText call; only a new string (a value being typed, a new dimension)
/// is rasterized. When the atlas fills up it starts over: the labels on screen are packed again
/// the first time they are drawn.
@MainActor
final class TextAtlas {
    /// A textured quad in screen points (top-left origin).
    struct Quad {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        /// x, y, w, h in normalised texture coordinates.
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct Key: Hashable {
        var text: String
        var style: LabelText.Style
        var scale: CGFloat
    }

    private struct Entry {
        /// Top-left corner in atlas pixels and the cell size.
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var textSize: CGSize
    }

    private let side: Int
    private var texture: MTLTexture?
    private var entries: [Key: Entry] = [:]
    private var nextX = 1
    private var nextY = 1
    private var rowHeight = 0

    init?(device: MTLDevice, side: Int = 1024) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side,
                                                         mipmapped: false)
        d.usage = .shaderRead
        // Shared, not private: `replace` on a private texture crashes with tightly packed rows
        // (Metal wants row alignment); the atlas is uploaded run by run from the main thread.
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        self.side = side
        texture = t
    }

    var metalTexture: MTLTexture? { texture }

    /// The quad that draws `text` centred on `center`, or nil when the run is empty or cannot be
    /// rasterized (the label then simply shows its box).
    func quad(_ text: String, style: LabelText.Style, center: CGPoint, color: SIMD4<Float>,
              scale: CGFloat) -> Quad? {
        guard !text.isEmpty, let texture else { return nil }
        let key = Key(text: text, style: style, scale: scale)
        var entry = entries[key]
        if entry == nil {
            guard let cell = rasterize(text, style: style, scale: scale) else { return nil }
            guard let placed = place(cell.width, cell.height) else { return nil }
            texture.replace(region: MTLRegionMake2D(placed.0, placed.1, cell.width, cell.height),
                            mipmapLevel: 0, withBytes: cell.data, bytesPerRow: cell.width)
            entry = Entry(x: placed.0, y: placed.1, width: cell.width, height: cell.height,
                          textSize: cell.textSize)
            entries[key] = entry
        }
        guard let e = entry else { return nil }
        let textSize = CGSize(width: e.textSize.width, height: e.textSize.height)
        let origin = SIMD2<Float>(Float(center.x - textSize.width / 2), Float(center.y - textSize.height / 2))
        let atlasSide = Float(side)
        let uv = SIMD4<Float>(Float(e.x) / atlasSide, Float(e.y) / atlasSide,
                              Float(e.width) / atlasSide, Float(e.height) / atlasSide)
        return Quad(origin: origin, size: SIMD2(Float(textSize.width), Float(textSize.height)),
                    uv: uv, color: color)
    }

    // MARK: Packing

    /// Shelf packing. A full atlas starts over: the entries are dropped and the visible labels
    /// are packed again as they are drawn, so the atlas never grows without bound.
    private func place(_ width: Int, _ height: Int) -> (Int, Int)? {
        if nextX + width >= side {
            nextX = 1
            nextY += rowHeight + 1
            rowHeight = 0
        }
        if nextY + height >= side {
            entries.removeAll(keepingCapacity: true)
            nextX = 1
            nextY = 1
            rowHeight = 0
        }
        guard nextX + width < side, nextY + height < side else { return nil }
        let at = (nextX, nextY)
        nextX += width + 1
        rowHeight = max(rowHeight, height)
        return at
    }

    // MARK: Rasterizing

    private struct Cell {
        var width: Int
        var height: Int
        var textSize: CGSize
        var data: [UInt8]
    }

    /// The run drawn white on black in an 8-bit grey bitmap: the renderer uses it as an alpha
    /// mask, so a label's colour stays a uniform (no per-colour copies in the atlas).
    private func rasterize(_ text: String, style: LabelText.Style, scale: CGFloat) -> Cell? {
        let textSize = LabelText.textSize(text, style)
        let width = max(1, Int(ceil(textSize.width * scale)))
        let height = max(1, Int(ceil(textSize.height * scale)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = gc
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: NSColor.white,
        ]
        (text as NSString).draw(at: .zero, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                                count: width * height))
        return Cell(width: width, height: height, textSize: textSize, data: bytes)
    }
}
