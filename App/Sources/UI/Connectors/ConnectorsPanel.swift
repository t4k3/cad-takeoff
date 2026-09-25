import AppKit
import SwiftUI

/// Status-bar indicator for the MCP server.
struct MCPStatusButton: View {
    @Environment(MCPHost.self) private var mcp
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("MCP")
                if !mcp.clients.isEmpty { Text("· \(mcp.clients.count)") }
            }
        }
        .buttonStyle(.plain)
        .help("Connettori MCP (Claude, ChatGPT)")
        .popover(isPresented: $showPanel, arrowEdge: .top) { ConnectorsPanel().frame(width: 420) }
    }

    private var color: Color {
        switch mcp.state {
        case .running: Theme.Palette.success
        case .starting: .yellow
        case .failed: Theme.Palette.danger
        case .stopped: .gray
        }
    }
}

struct ConnectorsPanel: View {
    @Environment(MCPHost.self) private var mcp
    @State private var revealToken = false
    @State private var copied: String?
    @State private var setupMessage: String?

    var body: some View {
        @Bindable var mcp = mcp
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.Palette.accent)
                Text("Connettori MCP").font(.headline)
                Spacer()
                Toggle("Attivo", isOn: $mcp.enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            Text("Claude e ChatGPT possono leggere e modificare il design aperto tramite il Model Context Protocol. Il server ascolta solo su questo Mac.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            statusRow

            if let url = mcp.url {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        copyRow("Endpoint", url)
                        copyRow("Token", mcp.token, secret: true)
                        HStack {
                            Spacer()
                            Button("Rigenera token") { mcp.regenerateToken() }
                                .controlSize(.small)
                                .help("I client configurati dovranno usare il nuovo token")
                        }
                    }
                }
                GroupBox("Claude Code") {
                    VStack(alignment: .leading, spacing: 6) {
                        let cmd = "claude mcp add --transport http fusion-takeoff \(url) --header \"Authorization: Bearer \(mcp.token)\""
                        Text(revealToken ? cmd : cmd.replacingOccurrences(of: mcp.token, with: "••••••"))
                            .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            copyButton("Copia comando", cmd)
                        }
                    }
                }
                GroupBox("Claude Desktop") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Usa il tuo Claude Desktop (il tuo account) per progettare in questo design. Il collegamento aggiunge la voce «fusion-takeoff» alla configurazione di Claude, con backup.")
                            .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let path = ClaudeDesktopSetup.configuredBridgePath, !ClaudeDesktopSetup.needsUpdate {
                                Label("Collegato", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(Theme.Palette.success)
                                    .help(path)
                            } else if ClaudeDesktopSetup.needsUpdate {
                                Label("L'app è stata spostata: aggiorna il collegamento", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(ClaudeDesktopSetup.configuredBridgePath == nil ? "Collega a Claude Desktop…" : "Ricollega…") {
                                switch ClaudeDesktopSetup.connect() {
                                case let .configured(backup):
                                    setupMessage = "Fatto. Riavvia Claude Desktop: troverai gli strumenti «fusion-takeoff»." + (backup != nil ? " Configurazione precedente salvata come backup." : "")
                                case .cancelled: setupMessage = nil
                                case let .failed(msg): setupMessage = msg
                                }
                            }
                            .controlSize(.small)
                        }
                        if let setupMessage {
                            Text(setupMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GroupBox("ChatGPT") {
                    ChatGPTSetupView(copy: { title, value in copyButton(title, value) })
                }
                GroupBox("Altri client MCP (stdio)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let bridge = MCPHost.bridgeURL?.path {
                            Text(bridge).font(.system(size: 10.5, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                            HStack { Spacer(); copyButton("Copia percorso bridge", bridge) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !mcp.activity.isEmpty {
                Text("ATTIVITÀ").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(mcp.activity.prefix(40)) { a in
                            HStack(alignment: .top, spacing: 6) {
                                Text(a.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                Text(a.text).foregroundStyle(a.isError ? Theme.Palette.danger : Theme.Palette.textPrimary)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(16)
        }
        .frame(maxHeight: 640)
    }

    @ViewBuilder private var statusRow: some View {
        switch mcp.state {
        case .running:
            Label(mcp.clients.isEmpty ? "In ascolto, nessun client connesso" : "Connessi: \(mcp.clients.joined(separator: ", "))",
                  systemImage: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
        case .starting: Label("Avvio…", systemImage: "hourglass")
        case let .failed(msg): Label("Errore: \(msg)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.danger)
        case .stopped: Label("Disattivato", systemImage: "pause.circle").foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func copyRow(_ title: String, _ value: String, secret: Bool = false) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.Palette.textSecondary).frame(width: 64, alignment: .leading)
            Text(secret && !revealToken ? String(repeating: "•", count: 16) : value)
                .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if secret {
                Button { revealToken.toggle() } label: { Label("Mostra", systemImage: revealToken ? "eye.slash" : "eye") }
                    .buttonStyle(IconButtonStyle()).help(revealToken ? "Nascondi" : "Mostra")
            }
            copyButton(nil, value)
        }
    }

    @ViewBuilder
    private func copyButton(_ title: String?, _ value: String) -> some View {
        let done = copied == value
        if let title {
            Button { copy(value) } label: { Label(done ? "Copiato" : title, systemImage: done ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.bordered).controlSize(.small)
        } else {
            Button { copy(value) } label: { Label("Copia", systemImage: done ? "checkmark" : "doc.on.doc") }
                .buttonStyle(IconButtonStyle()).help("Copia")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = value
    }
}
