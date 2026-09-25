import SwiftUI

/// ChatGPT connection through OpenAI's Secure MCP Tunnel: the user runs `tunnel-client`
/// with their own OpenAI account; the tunnel launches the bundled ftk-mcp bridge.
/// Commands come from ChatGPTConnector (Codex, T51); nothing here touches the account.
struct ChatGPTSetupView<CopyButton: View>: View {
    var copy: (String, String) -> CopyButton
    @AppStorage("connectors.chatgpt.tunnelID") private var tunnelID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usa il tuo ChatGPT su questo design tramite un tunnel MCP privato di OpenAI (niente server pubblici).")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Crea un tunnel nelle impostazioni OpenAI e copia il suo tunnel_id.")
            TextField("tunnel_…", text: $tunnelID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            step(2, "Nel Terminale (con tunnel-client installato) configura una volta:")
            switch Result(catching: { try ChatGPTConnector.configureCommand(tunnelID: tunnelID.trimmingCharacters(in: .whitespaces)) }) {
            case let .success(cmd):
                command(cmd, copyTitle: "Copia configurazione")
            case let .failure(error):
                Text(tunnelID.isEmpty ? "Inserisci il tunnel_id per generare il comando." : error.localizedDescription)
                    .font(.caption).foregroundStyle(tunnelID.isEmpty ? Theme.Palette.textSecondary : Theme.Palette.danger)
            }
            step(3, "Avvia il tunnel ogni volta che vuoi usare ChatGPT con l'app (l'app si apre da sola):")
            command(ChatGPTConnector.runCommand, copyTitle: "Copia avvio")
            HStack {
                Link("Guida OpenAI ai tunnel MCP", destination: ChatGPTConnector.documentationURL).font(.caption)
                Spacer()
                copy("Copia diagnosi", ChatGPTConnector.doctorCommand)
            }
            if !ChatGPTConnector.isBridgeInstalled {
                Label("Bridge ftk-mcp non trovato nell'app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.Palette.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Text("\(n). \(text)").font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private func command(_ cmd: String, copyTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cmd).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .lineLimit(4).truncationMode(.middle)
            HStack { Spacer(); copy(copyTitle, cmd) }
        }
    }
}
