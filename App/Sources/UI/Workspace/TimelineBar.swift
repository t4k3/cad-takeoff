import CADCore
import SwiftUI

/// The design history, like Fusion's timeline: steps in order (sketches, solids, sheet metal),
/// a draggable rollback marker, suppression, edit and delete. Everything is undoable.
struct TimelineBar: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var dragOffset: CGFloat = 0
    @State private var dragging = false

    private static let chip: CGFloat = 30
    private static let spacing: CGFloat = 3
    private static let step = chip + spacing

    var body: some View {
        let timeline = model.document.timeline
        let marker = model.document.insertionIndex
        HStack(spacing: 6) {
            Button { step(-1) } label: { Label("Precedente", systemImage: "backward.frame") }
                .buttonStyle(IconButtonStyle()).help("Seleziona il corpo precedente")
                .disabled(model.document.features.isEmpty)
            Button { step(1) } label: { Label("Successiva", systemImage: "forward.frame") }
                .buttonStyle(IconButtonStyle()).help("Seleziona il corpo successivo")
                .disabled(model.document.features.isEmpty)
            Divider().frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
                            if index == marker { markerView(count: timeline.count, at: marker) }
                            chip(item, index: index, active: index < marker && !item.isSuppressed).id(item.id)
                        }
                        if marker >= timeline.count { markerView(count: timeline.count, at: marker) }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if model.document.rollback != nil {
                Button("Alla fine") { model.moveRollback(to: timeline.count) }
                    .controlSize(.small)
                    .help("Riporta il marker alla fine della timeline")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metrics.timelineHeight)
        .background(Theme.Palette.panel)
    }

    // MARK: Marker

    /// Orange bar with a grip; drag it left/right to roll the design back or forward.
    private func markerView(count: Int, at index: Int) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8))
            Rectangle().frame(width: 3)
        }
        .foregroundStyle(Theme.Palette.accent)
        .frame(width: 12, height: 30)
        .contentShape(Rectangle())
        .offset(x: dragging ? dragOffset : 0)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in dragging = true; dragOffset = v.translation.width }
            .onEnded { v in
                let target = index + Int((v.translation.width / Self.step).rounded())
                dragging = false; dragOffset = 0
                model.moveRollback(to: max(0, min(count, target)))
            })
        .help("Marker della timeline: trascinalo per tornare a un punto dello storico")
        .accessibilityElement()
        .accessibilityLabel("Marker della timeline, dopo \(index) passi")
        .accessibilityAdjustableAction { dir in
            model.moveRollback(to: dir == .increment ? index + 1 : index - 1)
        }
    }

    // MARK: Steps

    private func chip(_ item: TimelineItem, index: Int, active: Bool) -> some View {
        let selected = model.selection == item.id || workspace.sketch?.sketch.id == item.id
        let hovered = workspace.hovered == item.id
        let tint = tintColor(item)
        return ZStack {
            Image(systemName: symbol(item))
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white : tint)
            if let f = item.feature, f.operation != .newBody {
                Text(f.operation == .cut ? "−" : f.operation == .join ? "+" : "∩")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(f.operation == .cut ? Theme.Palette.danger : Theme.Palette.success)
                    .offset(x: 10, y: -9)
            }
            if item.isSuppressed {
                Rectangle().fill(Theme.Palette.danger).frame(width: 26, height: 1.5).rotationEffect(.degrees(-35))
            }
        }
        .frame(width: Self.chip, height: 28)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? tint : hovered ? Theme.Palette.hover.opacity(2.5) : Theme.Palette.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(item.sketch != nil ? Theme.Palette.sketch.opacity(0.6) : Theme.Palette.separator))
        .overlay(alignment: .bottom) {
            if let f = item.feature { Capsule().fill(f.color.swiftUIColor).frame(width: 16, height: 3).offset(y: -2) }
        }
        .opacity(active ? 1 : 0.35)
        .help(help(item, index: index, active: active))
        .onTapGesture(count: 2) { edit(item) }
        .onTapGesture { if item.feature != nil { model.selection = item.id } }
        .onHover { workspace.hovered = $0 ? item.id : (workspace.hovered == item.id ? nil : workspace.hovered) }
        .contextMenu {
            Button(item.sketch != nil ? "Modifica schizzo" : "Modifica…") { edit(item) }
            Button(item.isSuppressed ? "Ripristina" : "Sopprimi") { model.setSuppressed(item.id, !item.isSuppressed) }
            Button("Porta il marker dopo questo passo") { model.moveRollback(to: index + 1) }
            Divider()
            Button("Elimina", role: .destructive) { model.deleteStep(item.id) }
        }
        .accessibilityElement()
        .accessibilityLabel(help(item, index: index, active: active))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { edit(item) }
    }

    private func edit(_ item: TimelineItem) {
        if let s = item.sketch { workspace.enterSketch(editing: s) }
        else if item.feature != nil { workspace.editFeature(item.id, model: model) }
    }

    private func symbol(_ item: TimelineItem) -> String {
        switch item.content {
        case let .feature(f): f.kind.symbol
        case .sketch: "pencil.and.outline"
        }
    }

    private func tintColor(_ item: TimelineItem) -> Color {
        item.sketch != nil ? Theme.Palette.sketch : Theme.Palette.accent
    }

    private func help(_ item: TimelineItem, index: Int, active: Bool) -> String {
        let kind = switch item.content {
        case let .feature(f): f.kind.typeName
        case .sketch: "Schizzo"
        }
        let state = item.isSuppressed ? " — soppresso" : (active ? "" : " — dopo il marker")
        return "\(index + 1). \(item.name) — \(kind)\(state). Doppio clic per modificare."
    }

    private func step(_ delta: Int) {
        let features = model.document.features
        guard !features.isEmpty else { return }
        let current = model.selectedIndex ?? (delta > 0 ? -1 : features.count)
        model.selection = features[min(max(current + delta, 0), features.count - 1)].id
    }
}
