import SwiftUI

/// Settings → Assistente: API keys (stored in the Keychain) and model choice.
struct AssistantSettingsView: View {
    @Environment(AssistantSession.self) private var session
    @State private var keyDraft = ""
    @State private var openAIKeyDraft = ""

    private var claude: ClaudeProvider? { session.providers.compactMap { $0 as? ClaudeProvider }.first }
    private var openAI: OpenAIProvider? { session.providers.compactMap { $0 as? OpenAIProvider }.first }

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
            if let openAI {
                @Bindable var openAI = openAI
                Section("OpenAI") {
                    Picker("Modello", selection: $openAI.modelID) {
                        ForEach(OpenAIProvider.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if openAI.hasKey {
                        LabeledContent("API key") {
                            HStack {
                                Label("Salvata nel Portachiavi", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Theme.Palette.success)
                                Button("Rimuovi", role: .destructive) { openAI.setAPIKey(nil) }
                            }
                        }
                    } else {
                        SecureField("API key", text: $openAIKeyDraft, prompt: Text("sk-…"))
                        HStack {
                            Link("Crea una chiave su platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                                .font(.caption)
                            Spacer()
                            Button("Salva") { openAI.setAPIKey(openAIKeyDraft); openAIKeyDraft = "" }
                                .disabled(openAIKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let error = openAI.credentialError {
                        Text(error).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                    Text("La chiave API è diversa dall'abbonamento ChatGPT: si crea su platform.openai.com e resta nel Portachiavi di macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
