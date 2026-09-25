import SwiftUI

/// Settings → Assistente: API keys (stored in the Keychain) and model choice.
struct AssistantSettingsView: View {
    @Environment(AssistantSession.self) private var session
    @State private var keyDraft = ""

    private var claude: ClaudeProvider? { session.providers.compactMap { $0 as? ClaudeProvider }.first }

    var body: some View {
        Form {
            if let claude {
                @Bindable var claude = claude
                Section("Claude (Anthropic)") {
                    Picker("Modello", selection: $claude.modelID) {
                        ForEach(ClaudeProvider.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if claude.hasKey {
                        LabeledContent("API key") {
                            HStack {
                                Label("Salvata nel Portachiavi", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Theme.Palette.success)
                                Button("Rimuovi", role: .destructive) { claude.setAPIKey(nil) }
                            }
                        }
                    } else {
                        SecureField("API key", text: $keyDraft, prompt: Text("sk-ant-…"))
                        HStack {
                            Link("Crea una chiave su console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                .font(.caption)
                            Spacer()
                            Button("Salva") { claude.setAPIKey(keyDraft); keyDraft = "" }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Text("La chiave resta nel Portachiavi di macOS e viene inviata solo ad api.anthropic.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("ChatGPT (OpenAI)") {
                Text("Provider in arrivo (T53, a cura di Codex).").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
