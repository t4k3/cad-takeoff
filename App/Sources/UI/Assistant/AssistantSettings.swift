import SwiftUI

/// Settings → Assistente: API keys (stored in the Keychain) and model choice.
struct AssistantSettingsView: View {
    @Environment(AssistantSession.self) private var session

    private var claudeProviders: [ClaudeProvider] { session.providers.compactMap { $0 as? ClaudeProvider } }
    private var claude: ClaudeProvider? { claudeProviders.first { $0.config.kind == .claude } }
    private var anthropicCompatible: ClaudeProvider? { claudeProviders.first { $0.config.kind == .compatible } }

    private var openAIProviders: [OpenAIChatProvider] { session.providers.compactMap { $0 as? OpenAIChatProvider } }
    private var chatGPT: OpenAIChatProvider? { openAIProviders.first { $0.config.kind == .chatGPT } }
    private var deepSeek: OpenAIChatProvider? { openAIProviders.first { $0.config.kind == .deepSeek } }
    private var openAICompatible: OpenAIChatProvider? { openAIProviders.first { $0.config.kind == .compatible } }

    var body: some View {
        Form {
            if let claude {
                @Bindable var claude = claude
                Section("Claude (Anthropic)") {
                    Picker("Modello", selection: $claude.modelID) {
                        ForEach(claude.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    ProviderKeyRow(
                        hasKey: claude.hasKey,
                        placeholder: "sk-ant-…",
                        linkTitle: "Crea una chiave su console.anthropic.com",
                        linkURL: URL(string: "https://console.anthropic.com/settings/keys"),
                        caption: "La chiave resta nel Portachiavi di macOS e viene inviata solo ad api.anthropic.com.",
                        save: { claude.setAPIKey($0) },
                        remove: { claude.setAPIKey(nil) }
                    )
                    if !claude.isConfigured {
                        Text(claude.setupHint).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            if let chatGPT {
                @Bindable var chatGPT = chatGPT
                Section("ChatGPT (OpenAI)") {
                    Picker("Modello", selection: $chatGPT.modelID) {
                        ForEach(chatGPT.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    ProviderKeyRow(
                        hasKey: chatGPT.hasKey,
                        placeholder: "sk-…",
                        linkTitle: "Crea una chiave su platform.openai.com",
                        linkURL: URL(string: "https://platform.openai.com/api-keys"),
                        caption: "La chiave API è diversa dall'abbonamento ChatGPT: si crea su platform.openai.com e resta nel Portachiavi di macOS.",
                        save: { chatGPT.setAPIKey($0) },
                        remove: { chatGPT.setAPIKey(nil) }
                    )
                    if !chatGPT.isConfigured {
                        Text(chatGPT.setupHint).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            if let deepSeek {
                @Bindable var deepSeek = deepSeek
                Section("DeepSeek") {
                    Picker("Modello", selection: $deepSeek.modelID) {
                        ForEach(deepSeek.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    ProviderKeyRow(
                        hasKey: deepSeek.hasKey,
                        placeholder: "sk-…",
                        linkTitle: nil,
                        linkURL: nil,
                        caption: "La chiave resta nel Portachiavi di macOS e viene inviata solo all'API scelta.",
                        save: { deepSeek.setAPIKey($0) },
                        remove: { deepSeek.setAPIKey(nil) }
                    )
                    if !deepSeek.isConfigured {
                        Text(deepSeek.setupHint).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            if let anthropicCompatible {
                @Bindable var anthropicCompatible = anthropicCompatible
                Section("Anthropic compatibile") {
                    TextField("Base URL", text: $anthropicCompatible.baseURL,
                              prompt: Text("https://api.deepseek.com/anthropic"))
                    TextField("Modello", text: $anthropicCompatible.modelID, prompt: Text("deepseek-flash"))
                    ProviderKeyRow(
                        hasKey: anthropicCompatible.hasKey,
                        placeholder: "sk-ant-…",
                        linkTitle: nil,
                        linkURL: nil,
                        caption: "La chiave resta nel Portachiavi di macOS e viene inviata solo all'API scelta.",
                        save: { anthropicCompatible.setAPIKey($0) },
                        remove: { anthropicCompatible.setAPIKey(nil) }
                    )
                    if !anthropicCompatible.isConfigured {
                        Text(anthropicCompatible.setupHint).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            if let openAICompatible {
                @Bindable var openAICompatible = openAICompatible
                Section("OpenAI compatibile") {
                    TextField("Base URL", text: $openAICompatible.baseURL,
                              prompt: Text("https://api.openai.com/v1"))
                    TextField("Modello", text: $openAICompatible.modelID, prompt: Text("gpt-6-sol"))
                    ProviderKeyRow(
                        hasKey: openAICompatible.hasKey,
                        placeholder: "sk-…",
                        linkTitle: nil,
                        linkURL: nil,
                        caption: "La chiave resta nel Portachiavi di macOS e viene inviata solo all'API scelta.",
                        save: { openAICompatible.setAPIKey($0) },
                        remove: { openAICompatible.setAPIKey(nil) }
                    )
                    if !openAICompatible.isConfigured {
                        Text(openAICompatible.setupHint).font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}

/// API key editor for one provider: its own draft, so sections don't share what is being typed.
private struct ProviderKeyRow: View {
    let hasKey: Bool
    let placeholder: String
    let linkTitle: String?
    let linkURL: URL?
    let caption: String
    let save: (String) -> Void
    let remove: () -> Void

    @State private var draft = ""

    var body: some View {
        if hasKey {
            LabeledContent("API key") {
                HStack {
                    Label("Salvata nel Portachiavi", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Palette.success)
                    Button("Rimuovi", role: .destructive, action: remove)
                }
            }
        } else {
            SecureField("API key", text: $draft, prompt: Text(placeholder))
            HStack {
                if let linkTitle, let linkURL {
                    Link(linkTitle, destination: linkURL).font(.caption)
                }
                Spacer()
                Button("Salva") {
                    save(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        Text(caption)
            .font(.caption).foregroundStyle(.secondary)
    }
}
