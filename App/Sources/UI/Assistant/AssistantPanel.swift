import CADCore
import SwiftUI

/// Chat with the design assistant: it builds and edits geometry through the CAD tools.
struct AssistantPanel: View {
    @Environment(AssistantSession.self) private var session
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var draft = ""
    @State private var desktopMessage: String?
    @FocusState private var composerFocused: Bool

    static let suggestions = [
        "Crea una staffa a L 40×20 mm, spessore 3 mm, larga 15 mm",
        "Aggiungi un cilindro Ø10 × 25 mm al centro del piatto",
        "Quanto volume ha il pezzo e sta su un piatto 256×256?",
        "Rendi la base più alta di 2 mm",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Theme.Palette.panel)
        .onAppear { composerFocused = true }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var session = session
        return HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Theme.Palette.accent)
            Menu {
                Picker("Provider", selection: $session.providerIndex) {
                    ForEach(session.providers.indices, id: \.self) { i in
                        Text("\(session.providers[i].displayName) — \(session.providers[i].modelName)").tag(i)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                SettingsLink { Text("Impostazioni assistente…") }
            } label: {
                Text("\(session.provider.displayName) · \(session.provider.modelName)")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button { session.newConversation() } label: { Label("Nuova conversazione", systemImage: "square.and.pencil") }
                .buttonStyle(IconButtonStyle())
                .help("Nuova conversazione")
                .disabled(session.entries.isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.entries.isEmpty { emptyState }
                    ForEach(session.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    if session.isRunning { TypingIndicator().id("typing") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.entries) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AssistantSession.Entry) -> some View {
        switch entry.kind {
        case let .user(text):
            HStack {
                Spacer(minLength: 30)
                Text(text)
                    .font(Theme.Typeface.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.Palette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        case let .assistant(text, thinking):
            VStack(alignment: .leading, spacing: 6) {
                if !thinking.isEmpty { ThinkingDisclosure(text: thinking) }
                if !text.isEmpty {
                    Text(markdown(text))
                        .font(Theme.Typeface.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .tool(run):
            ToolRunCard(run: run)
                .onHover { inside in
                    let id = run.changedFeatures.first
                    workspace.hovered = inside ? id : (workspace.hovered == id ? nil : workspace.hovered)
                }
                .onTapGesture { if let id = run.changedFeatures.first { model.selection = id } }
        case let .notice(text, isError):
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isError, !session.provider.isConfigured {
                    SettingsLink { Text("Apri Impostazioni") }.controlSize(.small)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistente di progettazione").font(.system(size: 14, weight: .semibold))
                Text("Descrivi il pezzo a parole: l'assistente crea e modifica la geometria nel design aperto. Ogni modifica si annulla con ⌘Z.")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.provider.isConfigured {
                // With a Claude subscription (Pro/Max) there is no API key: Claude Desktop, logged
                // in with that account, drives this design through the bundled MCP bridge.
                VStack(alignment: .leading, spacing: 6) {
                    Label("Hai l'abbonamento a Claude? Usa l'app Claude Desktop: parli con Claude lì e lui lavora su questo disegno, senza API key.",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(ClaudeDesktopSetup.configuredBridgePath == nil ? "Collega a Claude Desktop…" : "Ricollega Claude Desktop…") {
                            switch ClaudeDesktopSetup.connect() {
                            case .configured: desktopMessage = "Fatto. Chiudi e riapri Claude Desktop: nella chat troverai gli strumenti «fusion-takeoff». Tieni aperto CAD Takeoff mentre lavori."
                            case .cancelled: desktopMessage = nil
                            case let .failed(msg): desktopMessage = msg
                            }
                        }
                        .controlSize(.small)
                        if ClaudeDesktopSetup.configuredBridgePath != nil, !ClaudeDesktopSetup.needsUpdate {
                            Label("Collegato", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.Palette.success)
                        }
                    }
                    if let desktopMessage {
                        Text(desktopMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(Theme.Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Label("Oppure, per usare l'assistente qui dentro: " + session.provider.setupHint, systemImage: "key.fill")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    SettingsLink { Text("Apri Impostazioni") }.controlSize(.small)
                }
                .padding(10)
                .background(Theme.Palette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(Self.suggestions, id: \.self) { s in
                Button { send(s) } label: {
                    HStack {
                        Text(s).font(Theme.Typeface.body).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.Palette.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.separator))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Chiedi all'assistente di creare o modificare…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Typeface.body)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { send(draft) }
                if session.isRunning {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary)
                    .help("Interrompi")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Palette.textSecondary : Theme.Palette.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Invia (↩)")
                }
            }
            .padding(8)
            .background(Theme.Palette.panelRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(composerFocused ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.separator))

            HStack {
                Text("⌥↩ a capo")
                Spacer()
                if session.usage.input + session.usage.output > 0 {
                    Text("\(session.usage.input + session.usage.output) token")
                }
            }
            .font(.system(size: 9.5)).foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(10)
    }

    private func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.isRunning else { return }
        session.send(text)
        draft = ""
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Compact card for one tool call: status, readable arguments, result on demand.
private struct ToolRunCard: View {
    let run: AssistantSession.ToolRun
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                statusIcon
                Text(run.title).font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if !run.resultText.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(expanded ? "Nascondi dettagli" : "Mostra dettagli")
                }
            }
            if let args = argumentSummary, !args.isEmpty {
                Text(args).font(Theme.Typeface.mono).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            if expanded {
                Text(run.resultText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(run.status == .failed ? Theme.Palette.danger : Theme.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if run.status == .failed {
                Text(run.resultText).font(.caption).foregroundStyle(Theme.Palette.danger).lineLimit(2)
            }
        }
        .padding(8)
        .background(Theme.Palette.panelRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor))
        .contentShape(Rectangle())
        .help(run.changedFeatures.isEmpty ? "" : "Clicca per selezionare il corpo nel viewport")
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.Palette.danger)
        }
    }

    private var borderColor: Color {
        switch run.status {
        case .running: Theme.Palette.sketch.opacity(0.6)
        case .done: Theme.Palette.separator
        case .failed: Theme.Palette.danger.opacity(0.5)
        }
    }

    /// "width 40 · depth 20 · height 3" — numbers without trailing zeros, nested values abbreviated.
    private var argumentSummary: String? {
        guard case let .object(o)? = run.arguments else { return nil }
        return o.keys.sorted().filter { $0 != "expected_revision" }.map { key in
            let v: String = switch o[key]! {
            case let .number(n): n.formatted(.number.precision(.fractionLength(0...3)))
            case let .string(s): s
            case let .bool(b): b ? "sì" : "no"
            case let .array(a): "[\(a.count)]"
            case .object: "{…}"
            case .null: "—"
            }
            return "\(key) \(v)"
        }.joined(separator: " · ")
    }
}

private struct ThinkingDisclosure: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                Label("Ragionamento", systemImage: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            if open {
                Text(text).font(.system(size: 11)).foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.Palette.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * max(0, sin(phase + Double(i) * 0.8)))
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
        .padding(.vertical, 4)
    }
}
