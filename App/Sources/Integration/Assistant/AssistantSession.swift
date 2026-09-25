import Foundation
import Observation

/// Provider-independent agent loop: user message → model turn → run requested CAD
/// tools → feed results back → repeat until the model stops. Observable transcript for the UI.
@MainActor
@Observable
final class AssistantSession {
    struct ToolRun: Identifiable, Equatable {
        enum Status: Equatable { case running, done, failed }
        let id: String
        let name: String
        let title: String
        var arguments: JSONValue?
        var status: Status
        var resultText: String = ""
        var changedFeatures: [UUID] = []
    }

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(String)
            case assistant(text: String, thinking: String)
            case tool(ToolRun)
            case notice(String, isError: Bool)
        }
        let id = UUID()
        var kind: Kind
    }

    static let maxToolRounds = 25

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    private(set) var usage = (input: 0, output: 0)

    @ObservationIgnored var providers: [AssistantProvider]
    var providerIndex = 0 { didSet { if providerIndex != oldValue { newConversation() } } }
    @ObservationIgnored weak var tools: CADToolProvider?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(providers: [AssistantProvider]) { self.providers = providers }

    var provider: AssistantProvider { providers[providerIndex] }

    static let systemPrompt = """
    Sei l'assistente di progettazione di Fusion Takeoff, un CAD parametrico per macOS orientato alla stampa 3D.
    Rispondi in italiano, in modo breve e pratico.

    Convenzioni: unità millimetri, asse Z verso l'alto, piano XY = piatto di stampa, Z = 0 è il piano del piatto.
    Lavori sul design aperto dall'utente attraverso gli strumenti disponibili; ogni modifica è annullabile dall'utente.

    Modo di lavorare:
    - Prima di modificare un design esistente, leggi lo stato con gli strumenti di sola lettura.
    - Se una richiesta è ambigua su una misura importante, scegli un valore ragionevole, dichiaralo e procedi; chiedi solo se la scelta cambierebbe radicalmente il pezzo.
    - Dopo aver costruito o modificato geometria, verifica il risultato (ad esempio volume, ingombro, solido chiuso) e riassumi in una o due frasi cosa hai fatto, con le misure principali.
    - Se nessuno strumento permette di fare ciò che l'utente chiede, dillo chiaramente invece di improvvisare.
    """

    func newConversation() {
        stop()
        providers.forEach { $0.reset() }
        entries = []
        usage = (0, 0)
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard provider.isConfigured else {
            entries.append(Entry(kind: .notice(provider.setupHint, isError: true)))
            return
        }
        entries.append(Entry(kind: .user(text)))
        provider.addUserMessage(text)
        isRunning = true
        task = Task { [weak self] in
            await self?.loop()
            self?.isRunning = false
        }
    }

    private func loop() async {
        let specs = tools?.tools ?? []
        if specs.isEmpty {
            entries.append(Entry(kind: .notice("Strumenti CAD non ancora collegati: l'assistente può rispondere ma non modificare il design (in arrivo con T48).", isError: false)))
        }
        for _ in 0..<Self.maxToolRounds {
            if Task.isCancelled { return }
            var current: Int?
            let stop: AssistantStop
            do {
                stop = try await provider.runTurn(system: Self.systemPrompt, tools: specs) { [weak self] event in
                    self?.apply(event, current: &current, specs: specs)
                }
            } catch is CancellationError {
                entries.append(Entry(kind: .notice("Interrotto.", isError: false)))
                return
            } catch {
                if Task.isCancelled { entries.append(Entry(kind: .notice("Interrotto.", isError: false))); return }
                entries.append(Entry(kind: .notice(error.localizedDescription, isError: true)))
                return
            }
            switch stop {
            case .done:
                return
            case let .refused(explanation):
                entries.append(Entry(kind: .notice("Il modello ha rifiutato la richiesta" + (explanation.map { ": \($0)" } ?? "."), isError: true)))
                return
            case .truncated:
                entries.append(Entry(kind: .notice("Risposta interrotta per limite di lunghezza.", isError: true)))
                return
            case let .toolCalls(calls):
                var results: [(ToolCallRequest, ToolResult)] = []
                for call in calls {
                    if Task.isCancelled { return }
                    let result = await execute(call)
                    results.append((call, result))
                }
                provider.addToolResults(results)
            }
        }
        entries.append(Entry(kind: .notice("Troppi passaggi consecutivi: mi fermo qui. Scrivi \"continua\" per proseguire.", isError: true)))
    }

    private func apply(_ event: AssistantEvent, current: inout Int?, specs: [ToolSpec]) {
        switch event {
        case let .textDelta(t):
            if let i = current, case let .assistant(text, thinking) = entries[i].kind {
                entries[i].kind = .assistant(text: text + t, thinking: thinking)
            } else {
                entries.append(Entry(kind: .assistant(text: t, thinking: "")))
                current = entries.count - 1
            }
        case let .thinkingDelta(t):
            if let i = current, case let .assistant(text, thinking) = entries[i].kind {
                entries[i].kind = .assistant(text: text, thinking: thinking + t)
            } else {
                entries.append(Entry(kind: .assistant(text: "", thinking: t)))
                current = entries.count - 1
            }
        case let .toolCallStarted(id, name):
            let title = specs.first { $0.name == name }?.title ?? name
            entries.append(Entry(kind: .tool(ToolRun(id: id, name: name, title: title, status: .running))))
            current = nil
        case .toolArgumentsDelta:
            break
        case let .usage(input, output):
            usage = (usage.input + input, usage.output + output)
        case .servedBy:
            break
        }
    }

    private func execute(_ call: ToolCallRequest) async -> ToolResult {
        let index = entries.lastIndex { if case let .tool(run) = $0.kind { run.id == call.id } else { false } }
        func update(_ change: (inout ToolRun) -> Void) {
            guard let index, case var .tool(run) = entries[index].kind else { return }
            change(&run)
            entries[index].kind = .tool(run)
        }
        update { $0.arguments = call.arguments }

        let result: ToolResult
        if call.arguments == nil {
            result = .error("INVALID_JSON: gli argomenti dello strumento non sono JSON valido. Riprova con argomenti completi.")
        } else if let tools, tools.tools.contains(where: { $0.name == call.name }) {
            result = await tools.call(call.name, arguments: call.arguments ?? .object([:]))
        } else {
            result = .error("Strumento sconosciuto: \(call.name)")
        }
        update {
            $0.status = result.isError ? .failed : .done
            $0.resultText = result.text
            $0.changedFeatures = result.changedFeatures
        }
        return result
    }
}
