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
    /// The workspace the user is in: the request is about the design or the circuit.
    @ObservationIgnored var focus: AssistantFocus = .cad
    @ObservationIgnored private var task: Task<Void, Never>?

    init(providers: [AssistantProvider]) {
        self.providers = providers
        // Nothing set up for the first one: start on one that works (e.g. Apple's model on the Mac).
        if let first = providers.first, !first.isConfigured, let ready = providers.firstIndex(where: \.isConfigured) {
            providerIndex = ready
        }
    }

    var provider: AssistantProvider { providers[providerIndex] }

    static var systemPrompt: String { systemPrompt(for: .current) }

    /// The same instructions in the app's language: the model must answer as the UI speaks,
    /// whatever language the user picked for the app.
    static func systemPrompt(for language: AssistantLanguage) -> String {
        switch language {
        case .italian: return italianSystemPrompt
        case .english: return englishSystemPrompt
        case .chinese: return chineseSystemPrompt
        }
    }

    static var circuitFocusNote: String { circuitFocusNote(for: .current) }

    static func circuitFocusNote(for language: AssistantLanguage) -> String {
        switch language {
        case .italian: return "L'utente è nella scheda CIRCUITI: la richiesta riguarda il circuito aperto (strumenti circuit_*)."
        case .english: return "The user is on the CIRCUITI tab: the request is about the open circuit (circuit_* tools)."
        case .chinese: return "用户当前在 CIRCUITI（电路）选项卡：请求针对打开的电路（circuit_* 工具）。"
        }
    }

    private static let italianSystemPrompt = """
    Sei l'assistente di progettazione di CAD Takeoff, un CAD parametrico per macOS orientato alla stampa 3D.
    Rispondi in italiano, in modo breve e pratico.

    Convenzioni: unità millimetri, asse Z verso l'alto, piano XY = piatto di stampa, Z = 0 è il piano del piatto.
    Lavori sul design aperto dall'utente attraverso gli strumenti disponibili; ogni modifica è annullabile dall'utente.

    Modo di lavorare:
    - Prima di modificare un design esistente, leggi lo stato con gli strumenti di sola lettura.
    - Se una richiesta è ambigua su una misura importante, scegli un valore ragionevole, dichiaralo e procedi; chiedi solo se la scelta cambierebbe radicalmente il pezzo.
    - Dopo aver costruito o modificato geometria, verifica il risultato (ad esempio volume, ingombro, solido chiuso) e riassumi in una o due frasi cosa hai fatto, con le misure principali.
    - Se nessuno strumento permette di fare ciò che l'utente chiede, dillo chiaramente invece di improvvisare.

    Scelte da officina:
    - Fori per viti: add_hole con la misura metrica (passaggio, filettatura indicata per maschiare, inserto a caldo); lamature e svasature se la testa va incassata.
    - Tasche, asole e sporgenze su una faccia: add_extrude con face_point/face_normal (into_part per i tagli).
    - Bordi: add_chamfer con profile round per i raccordi; per la stampa 3D evita raccordi sul bordo appoggiato al piatto (meglio uno smusso).
    - Pezzi simmetrici: modella metà e usa add_pattern mirror con join; ripetizioni con add_pattern rectangular/circular.
    - Lamiera: add_sheet_metal con materiale e spessore commerciale; raggio e K vengono dalla tabella di piega; riporta all'utente gli avvisi (flange sotto il minimo piegabile). Lo sviluppo si esporta con export_flat_dxf.
    - Assiemi: list_project_designs, add_component, bill_of_materials.
    - Pezzi più grandi del piatto: add_split per dividerli.
    - Per gli schizzi: list_sketches / get_sketch per rivedere, add_sketch per creare entità sui piani XY/XZ/YZ o su una faccia, extrude_sketch per estrudere il profilo (anche con isole).

    Circuiti (strumenti circuit_*, sul circuito aperto nella scheda CIRCUITI, millimetri, scheda vista dall'alto):
    - Leggi con circuit_info, circuit_library, circuit_pins e circuit_issues; il token `revision` dei risultati circuit_* vale solo per i circuiti (quello del CAD è un altro).
    - Ogni modifica in due passi: circuit_preview (nulla cambia; mostra can_apply, blocking_issues, new_issues), poi circuit_apply con lo stesso preview_id. Se il motore la blocca, spiega perché invece di forzarla.
    - Componenti dalla libreria (modelli generici da verificare sul datasheet), collegamenti con i nomi dei pin «R1.2», pin inutilizzati con no_connect.
    - La produzione (Gerber) si verifica con circuit_fabrication_check; l'export lo fa l'utente in CIRCUITI › PRODUZIONE.
    """

    private static let englishSystemPrompt = """
    You are the design assistant of CAD Takeoff, a parametric CAD for macOS aimed at 3D printing.
    Answer in English, briefly and practically.

    Conventions: millimetres, Z axis up, XY plane = print bed, Z = 0 is the bed surface.
    You work on the design the user has open through the available tools; every change can be undone by the user.

    How to work:
    - Before changing an existing design, read its state with the read-only tools.
    - If a request is ambiguous about an important dimension, pick a sensible value, state it and proceed; only ask when the choice would radically change the part.
    - After building or changing geometry, verify the result (for example volume, bounding box, closed solid) and summarise in one or two sentences what you did, with the main dimensions.
    - If no tool can do what the user asks, say so plainly instead of improvising.

    Workshop choices:
    - Screw holes: add_hole with the metric size (clearance, thread noted for tapping, heat-set insert); counterbore and countersink when the head must sit flush.
    - Pockets, slots and bosses on a face: add_extrude with face_point/face_normal (into_part for cuts).
    - Edges: add_chamfer with profile round for fillets; for 3D printing avoid fillets on the edge resting on the bed (a chamfer is better).
    - Symmetric parts: model half and use add_pattern mirror with join; repetitions with add_pattern rectangular/circular.
    - Sheet metal: add_sheet_metal with a commercial material and thickness; radius and K come from the bend table; report warnings to the user (flanges below the minimum bendable length). The flat pattern is exported with export_flat_dxf.
    - Assemblies: list_project_designs, add_component, bill_of_materials.
    - Parts larger than the bed: add_split to divide them.
    - Sketches: list_sketches / get_sketch to review, add_sketch to create entities on the XY/XZ/YZ planes or on a face, extrude_sketch to extrude the profile (holes included).

    Circuits (circuit_* tools, on the circuit open in the CIRCUITI tab, millimetres, board seen from above):
    - Read with circuit_info, circuit_library, circuit_pins and circuit_issues; the `revision` token in circuit_* results only applies to circuits (the CAD one is different).
    - Every change takes two steps: circuit_preview (nothing changes; shows can_apply, blocking_issues, new_issues), then circuit_apply with the same preview_id. If the engine blocks it, explain why instead of forcing it.
    - Components from the library (generic models to check against the datasheet), connections with pin names like «R1.2», unused pins with no_connect.
    - Production (Gerber) is checked with circuit_fabrication_check; the user exports it from CIRCUITI › PRODUZIONE.
    """

    private static let chineseSystemPrompt = """
    你是 CAD Takeoff 的设计助手。CAD Takeoff 是面向 3D 打印的 macOS 参数化 CAD。
    用简体中文回答，简短、务实。

    约定：单位毫米，Z 轴朝上，XY 平面 = 打印平台，Z = 0 是平台平面。
    你通过可用工具操作用户打开的当前设计；用户的每次修改都可以撤销。

    工作方式：
    - 修改已有设计前，先用只读工具读取当前状态。
    - 如果请求在关键尺寸上有歧义，选择一个合理的值，说明它并继续；只有当选择会彻底改变零件时才提问。
    - 构建或修改几何之后，验证结果（例如体积、外形尺寸、是否为封闭实体），并用一两句话总结你做了什么和主要尺寸。
    - 如果没有工具能完成用户的请求，明确说明，不要臆造。

    车间经验：
    - 螺丝孔：add_hole 使用公制规格（通孔；攻丝时注明螺纹；热熔嵌件）；需要埋头的场合用沉孔或锥形沉孔。
    - 面上的凹槽、长孔和凸台：add_extrude 配合 face_point/face_normal（切削时用 into_part）。
    - 棱边：add_chamfer 用 profile round 做圆角；3D 打印时避免在贴合平台的底边上做圆角（用倒角更好）。
    - 对称零件：先建一半，再用 add_pattern mirror 并 join；阵列用 add_pattern rectangular/circular。
    - 钣金：add_sheet_metal 用常用材料和板厚；折弯半径与 K 因子来自折弯表；向用户报告警告（法兰低于最小可折长度）。展开图用 export_flat_dxf 导出。
    - 装配：list_project_designs、add_component、bill_of_materials。
    - 大于平台的零件：用 add_split 拆分。
    - 草图：用 list_sketches / get_sketch 查看，用 add_sketch 在 XY/XZ/YZ 平面或某个面上创建实体，用 extrude_sketch 拉伸轮廓（支持带孔/岛屿）。

    电路（circuit_* 工具，作用于 CIRCUITI 选项卡中打开的电路，毫米，俯视电路板）：
    - 用 circuit_info、circuit_library、circuit_pins 和 circuit_issues 读取；circuit_* 结果里的 `revision` 令牌只对电路有效（CAD 的是另一个）。
    - 每次修改分两步：先 circuit_preview（不改变任何东西；返回 can_apply、blocking_issues、new_issues），再用同一个 preview_id 调 circuit_apply。如果引擎阻止，解释原因，不要强行执行。
    - 元件来自库（通用模型需对照数据手册核实），连接使用引脚名「R1.2」，未使用的引脚用 no_connect。
    - 生产（Gerber）用 circuit_fabrication_check 检查；导出由用户在 CIRCUITI › PRODUZIONE 中执行。
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
        // Apple's on-device model calls the tools inside its own turn: through the same execution
        // (shown in the conversation, undoable), started here.
        if #available(macOS 27.0, *), let apple = provider as? AppleIntelligenceProvider {
            apple.focus = focus
            apple.executor = { [weak self] name, arguments in
                guard let self else { return .error("Assistente chiuso.") }
                // Its tools have no `expected_revision` (one argument less to get wrong): a write
                // runs on the revision the design has when the model calls it.
                var arguments = arguments
                if case var .object(o) = arguments, o["expected_revision"] == nil,
                   self.tools?.tools.first(where: { $0.name == name })?.isReadOnly == false, let revision = self.tools?.expectedRevision(for: name) {
                    o["expected_revision"] = .string(revision); arguments = .object(o)
                }
                let call = ToolCallRequest(id: UUID().uuidString, name: name, arguments: arguments, rawArguments: arguments.jsonString)
                let title = self.tools?.tools.first { $0.name == name }?.title ?? name
                self.entries.append(Entry(kind: .tool(ToolRun(id: call.id, name: name, title: title, status: .running))))
                return await self.execute(call)
            }
        }
        isRunning = true
        let start = entries.count
        task = Task { [weak self] in
            await self?.prepareSmallModelContext()
            await self?.loop()
            self?.checkClaims(since: start)
            self?.isRunning = false
        }
    }

    /// The small on-device model gets the design's bodies and sizes with the request (read here
    /// with list_features, nothing changes).
    private func prepareSmallModelContext() async {
        guard #available(macOS 27.0, *) else { return }
        guard let apple = provider as? AppleIntelligenceProvider, focus == .cad, let tools,
              tools.tools.contains(where: { $0.name == "list_features" }) else { return }
        let result = await tools.call("list_features", arguments: [:])
        guard !result.isError, let features = result.structured?["features"]?.array else { return }
        func n(_ v: JSONValue?) -> String { v?.number.map { String(format: "%.1f", $0) } ?? "?" }
        let lines = features.prefix(12).compactMap { f -> String? in
            guard let name = f["name"]?.string else { return nil }
            let kind = f["kind"]?.string ?? ""
            guard let b = f["bounds"] else { return "\(name) (\(kind))" }
            return "\(name) (\(kind)) da (\(n(b["min"]?["x"])), \(n(b["min"]?["y"])), \(n(b["min"]?["z"]))) a (\(n(b["max"]?["x"])), \(n(b["max"]?["y"])), \(n(b["max"]?["z"]))), misure \(n(b["size"]?["x"])) × \(n(b["size"]?["y"])) × \(n(b["size"]?["z"]))"
        }
        apple.context = lines.isEmpty ? nil : lines.joined(separator: "; ")
    }

    /// A reply that says it made or changed something while no tool did (a small model can):
    /// said plainly, so nobody looks for a part that does not exist.
    func checkClaims(since start: Int) {
        guard start <= entries.count else { return }
        let turn = entries[start...]
        // Only a tool that writes counts (reading the design changes nothing).
        let writers = Set((tools?.tools ?? []).filter { !$0.isReadOnly }.map(\.name))
        let changed = turn.contains { if case let .tool(run) = $0.kind { run.status == .done && writers.contains(run.name) } else { false } }
        guard !changed else { return }
        let said = turn.compactMap { if case let .assistant(text, _) = $0.kind { text.lowercased() } else { nil } }.joined(separator: " ")
        guard Self.claimsAChange(said) else { return }
        entries.append(Entry(kind: .notice("Attenzione: la risposta parla di una modifica, ma nessuno strumento è stato eseguito: il disegno non è cambiato. Riprova con una richiesta più precisa (misure, posizione) o con Claude.", isError: true)))
    }

    static func claimsAChange(_ text: String) -> Bool {
        let verbs = ["ho creato", "ho aggiunto", "ho modificato", "ho spostato", "ho eliminato", "ho rimosso", "ho cambiato",
                     "ho fatto", "ho realizzato", "ho posizionato", "ho unito", "ho tagliato", "ho forato", "ho rinominato",
                     "ho collegato", "ho applicato", "ho esteso", "ho ridotto", "ho aumentato", "ho impostato", "ho inserito",
                     "i created", "i added", "i modified", "i changed", "i moved", "i removed", "i deleted", "i made",
                     "i built", "i set", "i applied", "i renamed", "i connected", "i extended", "i reduced", "i increased",
                     "已创建", "创建了", "已添加", "添加了", "已修改", "修改了", "已移动", "移动了", "已删除", "删除了",
                     "已设置", "设置为", "已连接", "连接了", "已拉伸", "拉伸了", "已旋转", "旋转了", "已应用", "应用了"]
        return verbs.contains { text.contains($0) }
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
                let system = Self.systemPrompt + (focus == .circuits ? "\n" + Self.circuitFocusNote : "")
                stop = try await provider.runTurn(system: system, tools: specs) { [weak self] event in
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

/// Which document the user is working on when they write to the assistant.
enum AssistantFocus: Sendable { case cad, circuits }
