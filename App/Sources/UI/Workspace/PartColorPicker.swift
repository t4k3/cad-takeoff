import AppKit
import CADCore
import SwiftUI

/// Filament-like swatches plus a free colour well. Changes go through
/// `model.setFeatureColor` (undoable); the colour well is debounced so dragging
/// it produces one undo step, not dozens.
struct PartColorPicker: View {
    @Environment(DesignModel.self) private var model
    let feature: Feature

    static let swatches: [(String, PartColor)] = [
        ("Bianco", PartColor(red: 245, green: 245, blue: 240)), ("Grigio", PartColor(red: 166, green: 178, blue: 195)),
        ("Nero", PartColor(red: 38, green: 38, blue: 40)), ("Rosso", PartColor(red: 214, green: 45, blue: 45)),
        ("Arancione", PartColor(red: 245, green: 130, blue: 32)), ("Giallo", PartColor(red: 247, green: 208, blue: 45)),
        ("Verde", PartColor(red: 60, green: 170, blue: 80)), ("Blu", PartColor(red: 36, green: 99, blue: 210)),
        ("Azzurro", PartColor(red: 80, green: 180, blue: 230)), ("Viola", PartColor(red: 130, green: 80, blue: 190)),
    ]

    @State private var wellColor = Color.gray
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 10), alignment: .leading, spacing: 6) {
                ForEach(Self.swatches, id: \.0) { name, c in
                    Button { apply(c) } label: {
                        Circle().fill(c.swiftUIColor).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                            .overlay(Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2).padding(-3)
                                .opacity(feature.color == c ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel("Colore \(name)")
                    .accessibilityAddTraits(feature.color == c ? .isSelected : [])
                }
            }
            HStack {
                ColorPicker("Altro colore", selection: $wellColor, supportsOpacity: false)
                    .font(Theme.Typeface.body)
                    .onChange(of: wellColor) { _, new in
                        guard let c = PartColor(new), c != feature.color else { return }
                        pending?.cancel()
                        pending = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            if !Task.isCancelled { apply(c) }
                        }
                    }
                Spacer()
                Text(feature.color.hex).font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { wellColor = feature.color.swiftUIColor }
        .onChange(of: feature.id) { _, _ in wellColor = feature.color.swiftUIColor }
    }

    private func apply(_ c: PartColor) {
        do { try model.setFeatureColor(feature.id, color: c) }
        catch { model.statusMessage = "Colore non applicato: \(error.localizedDescription)" }
    }
}

extension PartColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Linear-ish RGB for the renderer.
    var simd: SIMD3<Float> { SIMD3(Float(red) / 255, Float(green) / 255, Float(blue) / 255) }

    /// sRGB conversion from a SwiftUI colour (alpha dropped).
    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func b(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(red: b(c.redComponent), green: b(c.greenComponent), blue: b(c.blueComponent))
    }
}
