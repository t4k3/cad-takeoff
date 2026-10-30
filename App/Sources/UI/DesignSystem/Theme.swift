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

        /// Behind the viewport and the glass islands: a soft neutral, not an opaque wall.
        static let canvas = dynamic(light: 0xE9ECEF, dark: 0x1E2226)
        /// Surfaces that sit *inside* a glass island (rows, chips): nearly clear, so the
        /// material shows through and the panel keeps one look in light and dark.
        static let panel = dynamic(light: 0xF7F8F9, dark: 0x2A2F34).opacity(0.0)
        static let panelRaised = dynamic(light: 0xFFFFFF, dark: 0x343A40).opacity(0.55)
        /// Top command bar: no opaque fill (the glass capsule is its background).
        static let ribbon = dynamic(light: 0xFDFDFD, dark: 0x30353A).opacity(0.0)
        static let separator = dynamic(light: 0xD5D9DD, dark: 0x41474D).opacity(0.6)
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

// MARK: - Liquid Glass (macOS HIG)

/// The floating islands: panels and capsules drawn in Liquid Glass, over the live viewport.
/// One look in light and dark: the system material does the blurring and the vibrancy, the
/// gradient stroke gives the edge its thickness, the soft shadow lifts it off the part.
enum LiquidGlass {
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let dock: CGFloat = 18
    }

    /// Rounded glass card: browser, inspector/assistant, command panel, dock.
    struct PanelSurface: ViewModifier {
        var cornerRadius: CGFloat = Radius.large
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.strokeBorder(edge, lineWidth: 0.8))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.13), radius: 16, x: 0, y: 8)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(edge, lineWidth: 0.8))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.13), radius: 16, x: 0, y: 8)
            }
        }

        /// Top-left highlight, bottom-right shade: a pane of glass catching the light.
        private var edge: LinearGradient {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [.white.opacity(0.20), .white.opacity(0.05), .black.opacity(0.20)]
                    : [.white.opacity(0.85), .white.opacity(0.35), .black.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Compact capsules: mode switcher, tool strip, timeline, status.
    struct CapsuleSurface: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            let shape = SwiftUI.Capsule(style: .continuous)
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(capsuleEdge)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 12, x: 0, y: 5)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(capsuleEdge)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 12, x: 0, y: 5)
            }
        }

        private var capsuleEdge: some View {
            let shape = SwiftUI.Capsule(style: .continuous)
            return shape.strokeBorder(
                LinearGradient(colors: colorScheme == .dark
                                ? [.white.opacity(0.25), .white.opacity(0.07)]
                                : [.white.opacity(0.9), .white.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        }
    }
}

extension View {
    /// A floating glass island (rounded card).
    func glassPanel(cornerRadius: CGFloat = LiquidGlass.Radius.large) -> some View {
        modifier(LiquidGlass.PanelSurface(cornerRadius: cornerRadius))
    }

    /// A floating glass capsule (mode bar, tool strip, timeline, status).
    func glassCapsule() -> some View {
        modifier(LiquidGlass.CapsuleSurface())
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
            Text(LocalizedStringKey(title)).font(Theme.Typeface.panelTitle).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

/// Tool button in the floating command bar: SF Symbol over a one-word label, compact.
struct RibbonButtonStyle: ButtonStyle {
    var isActive = false
    var tint = Theme.Palette.accent
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(RibbonLabelStyle(tint: isActive ? tint : Theme.Palette.textPrimary))
            .frame(minWidth: 46, minHeight: 42)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: LiquidGlass.Radius.small, style: .continuous)
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
        VStack(spacing: 2) {
            configuration.icon.font(.system(size: 16, weight: .regular)).foregroundStyle(tint)
                .frame(height: 20)
            configuration.title.font(.system(size: 9.5)).foregroundStyle(Theme.Palette.textPrimary)
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
            Text(LocalizedStringKey(title)).font(Theme.Typeface.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            TextField(LocalizedStringKey(title), value: $value, format: .number.precision(.fractionLength(0...3)))
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
    @ViewBuilder
    func overlayChip() -> some View {
        if #available(macOS 26.0, *) {
            padding(4)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
