import AppKit
import SwiftUI

/// Design tokens. Every colour adapts to light/dark through dynamic NSColors,
/// so views never branch on colorScheme.
enum Theme {
    enum Palette {
        /// Brand accent: selection, active tool, primary actions.
        static let accent = dynamic(light: 0xE8650A, dark: 0xFF8A3D)
        /// Sketch geometry and sketch-mode chrome.
        static let sketch = dynamic(light: 0x1E7FD6, dark: 0x5AB0FF)
        static let danger = Color(nsColor: .systemRed)
        static let success = Color(nsColor: .systemGreen)

        static let canvas = dynamic(light: 0xE9ECEF, dark: 0x1E2226)
        static let panel = dynamic(light: 0xF7F8F9, dark: 0x2A2F34)
        static let panelRaised = dynamic(light: 0xFFFFFF, dark: 0x343A40)
        static let ribbon = dynamic(light: 0xFDFDFD, dark: 0x30353A)
        static let separator = dynamic(light: 0xD5D9DD, dark: 0x41474D)
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.06)

        /// Model shading in the viewport (linear-ish RGB for the renderer).
        static let body = SIMD3<Float>(0.63, 0.68, 0.74)
        static let bodySelected = SIMD3<Float>(1.0, 0.55, 0.22)
        static let bodyHover = SIMD3<Float>(0.80, 0.84, 0.90)
    }

    enum Metrics {
        static let ribbonHeight: CGFloat = 94
        static let tabBarHeight: CGFloat = 26
        static let browserWidth: CGFloat = 240
        static let inspectorWidth: CGFloat = 270
        static let timelineHeight: CGFloat = 44
        static let statusHeight: CGFloat = 22
        static let corner: CGFloat = 6
        static let pad: CGFloat = 10
    }

    enum Typeface {
        static let panelTitle = Font.system(size: 11, weight: .semibold).smallCaps()
        static let toolLabel = Font.system(size: 10.5)
        static let body = Font.system(size: 12)
        static let mono = Font.system(size: 11).monospacedDigit()
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Reusable pieces

/// Header shared by every side panel.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(Theme.Typeface.panelTitle).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .frame(height: 28)
        .background(Theme.Palette.panel)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Large icon-over-label button used in the ribbon.
struct RibbonButtonStyle: ButtonStyle {
    var isActive = false
    var tint = Theme.Palette.accent
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(RibbonLabelStyle(tint: isActive ? tint : Theme.Palette.textPrimary))
            .frame(minWidth: 52, minHeight: 50)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.corner)
                    .fill(isActive ? tint.opacity(0.16)
                          : configuration.isPressed ? Theme.Palette.hover.opacity(2)
                          : hovering ? Theme.Palette.hover : .clear)
            )
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

private struct RibbonLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 20, weight: .regular)).foregroundStyle(tint)
                .frame(height: 24)
            configuration.title.font(Theme.Typeface.toolLabel).foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
    }
}

/// Compact icon button for panels, timeline and viewport overlays.
struct IconButtonStyle: ButtonStyle {
    var isActive = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Theme.Palette.accent : Theme.Palette.textPrimary)
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(configuration.isPressed || isActive ? Theme.Palette.hover.opacity(2.5)
                      : hovering ? Theme.Palette.hover : .clear))
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

/// Numeric field with a unit suffix, right aligned like CAD dimension inputs.
struct DimensionField: View {
    let title: String
    @Binding var value: Double
    var unit = "mm"

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(Theme.Typeface.mono)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
            Text(unit).font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 24, alignment: .leading)
        }
    }
}

extension View {
    /// Floating translucent chip used for viewport overlays (nav bar, hints, ViewCube frame).
    /// Controls floating over the viewport: Liquid Glass (macOS 26), the part seen through it.
    func overlayChip() -> some View {
        padding(4)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
