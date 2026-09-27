import ElectronicsCore
import Foundation

/// The assistant's CIRCUITI tools (chat and MCP, T100): the same engine commands and transactions
/// as the workspace. Every change goes in two steps: `circuit_preview` computes it on a copy
/// (nothing changes) and remembers the exact command under an ID; `circuit_apply` with that ID
/// applies that very command, only on the circuit it was previewed on — same identity, same open
/// document (a reopened copy with the same identity and revision is another one), same revision —
/// and only if the engine did not block it (`canApply`: new copper errors block; component moves
/// that leave diagnostics are allowed, as in the workspace). The token that names that circuit
/// is `revision` in every result and `expected_revision` in every write.
extension CircuitModel: CADToolProvider {
    struct ToolPreview {
        var command: ElectronicsCommand
        var token: String
        var canApply: Bool
        var blocking: [ElectronicsIssue]
        var subjects: [UUID]
    }

    /// A history entry the assistant made: where it sits in the timeline (past, then future read
    /// back) of which open document. Undo and redo move entries between past and future without
    /// changing them or their position, so the assistant keeps owning its own steps — and never a
    /// step of the user's, even after its own were undone.
    struct AssistantStep: Equatable {
        var epoch: Int
        var position: Int
        var edit: ElectronicsEdit
    }

    var tools: [ToolSpec] { CircuitToolCatalog.tools }

    /// The next undo (redo) is the assistant's.
    var assistantCanUndo: Bool {
        guard let doc = document, let last = doc.past.last else { return false }
        return assistantSteps.contains(AssistantStep(epoch: documentEpoch, position: doc.past.count - 1, edit: last))
    }
    var assistantCanRedo: Bool {
        guard let doc = document, let next = doc.future.last else { return false }
        return assistantSteps.contains(AssistantStep(epoch: documentEpoch, position: doc.past.count, edit: next))
    }

    /// The circuit as the tools name it: design identity, this open document, revision.
    var designRevision: String {
        guard let doc = document else { return "nessun-circuito" }
        return "\(doc.design.id.uuidString.lowercased())@\(doc.revision)#\(toolSession)-\(documentEpoch)"
    }

    func call(_ name: String, arguments: JSONValue) async -> ToolResult {
        do {
            try Task.checkCancellation()
            guard let spec = tools.first(where: { $0.name == name }) else { throw CircuitEditError("Strumento non disponibile: \(name). Leggere tools/list.") }
            guard case let .object(args) = arguments,
                  case let .object(properties)? = spec.inputSchema["properties"] else { throw CircuitEditError("Gli argomenti devono essere un oggetto JSON.") }
            let unknown = Set(args.keys).subtracting(properties.keys)
            guard unknown.isEmpty else { throw CircuitEditError("Parametri sconosciuti: \(unknown.sorted().joined(separator: ", ")).") }
            for key in spec.inputSchema["required"]?.array?.compactMap(\.string) ?? [] {
                guard args[key] != nil else { throw CircuitEditError("Parametro richiesto: \(key).") }
            }
            // Every argument of the type its schema says: a wrong type is an error, never a default.
            for (key, value) in args { try Self.validate(value, properties[key] ?? .null, key) }
            guard document != nil else { throw CircuitEditError("Nessun circuito aperto in CIRCUITI: aprirne o crearne uno.") }
            if !spec.isReadOnly {
                guard args["expected_revision"]?.string == designRevision else {
                    throw CircuitEditError("Conflitto di revisione: il circuito è cambiato o è stato aperto un altro file. Rileggere circuit_info e rifare l'anteprima.")
                }
            }
            switch name {
            case "circuit_info":
                await waitForCopperCheck()
                return info()
            case "circuit_issues":
                await waitForCopperCheck()
                let list = issues
                return result(pcbIsCurrent ? "\(list.count) segnalazioni" : "\(list.count) segnalazioni; controllo del rame non ancora pronto",
                              ["issues": .array(list.map(Self.describe)), "copper_check": .string(pcbIsCurrent ? "current" : "pending")])
            case "circuit_library": return library()
            case "circuit_pins": return try pins(args)
            case "circuit_fabrication_check": return try await fabricationCheck(args)
            case "circuit_preview": return try await preview(args)
            case "circuit_apply": return try await applyPreview(args)
            case "circuit_undo": return try restore(redo: false)
            case "circuit_redo": return try restore(redo: true)
            default: throw CircuitEditError("Strumento non disponibile: \(name).")
            }
        } catch {
            let message = (error as? CircuitEditError)?.message ?? Self.describe(error)
            return result(message, ["error": .string(message)], error: true)
        }
    }

    // MARK: Reading

    /// The copper check (DRC) of the circuit as it is, before counting errors: never «zero errors»
    /// only because it is still running. If it does not arrive, the result says «pending».
    private func waitForCopperCheck() async {
        if !pcbIsCurrent { await pcbReady() }
    }

    private func info() -> ToolResult {
        guard let d = design, let doc = document else { return .error("Nessun circuito aperto.") }
        let placements = Dictionary(d.board.placements.map { ($0.componentID, $0) }, uniquingKeysWith: { a, _ in a })
        let connections = Dictionary(grouping: d.connections.compactMap(\.netID), by: { $0 }).mapValues(\.count)
        let copper = d.board.copper
        var fields: [String: JSONValue] = [
            "design_id": .string(d.id.uuidString.lowercased()), "name": .string(d.name), "file": .string(title),
            "document_revision": .number(Double(doc.revision)), "modified": .bool(isDirty),
            "board": ["outline": .array(d.board.outline.map(Self.point)), "thickness": .number(d.board.thickness),
                      "copper_layers": .number(Double(layerCount)), "assembly_origin": Self.point(d.board.assemblyOrigin)],
            "components": .array(d.components.map { c in
                var o: [String: JSONValue] = ["id": .string(c.id.uuidString.lowercased()), "reference": .string(c.reference),
                                              "value": .string(c.value), "assembly": .string(c.assembly.rawValue)]
                if let device = d.library.devices.first(where: { $0.key == c.device }), !device.manufacturerPartNumber.isEmpty {
                    o["part_number"] = .string(device.manufacturerPartNumber)
                }
                if let p = placements[c.id] {
                    o["x"] = .number(p.position.x); o["y"] = .number(p.position.y)
                    o["rotation"] = .number(p.rotationDegrees); o["side"] = .string(p.side.rawValue)
                } else { o["placed"] = false }
                return .object(o)
            }),
            "nets": .array(d.nets.map { n in
                ["id": .string(n.id.uuidString.lowercased()), "name": .string(n.name), "pins": .number(Double(connections[n.id] ?? 0))]
            }),
            "tracks": .array((copper?.tracks ?? []).map { t in
                ["id": .string(t.id.uuidString.lowercased()), "net": .string(netName(t.netID)), "layer": .number(Double(t.layer)),
                 "width": .number(t.width), "points": .array(t.points.map(Self.point))]
            }),
            "vias": .array((copper?.vias ?? []).map { v in
                ["id": .string(v.id.uuidString.lowercased()), "net": .string(netName(v.netID)), "x": .number(v.position.x), "y": .number(v.position.y),
                 "diameter": .number(v.diameter), "drill": .number(v.drill)]
            }),
            "zones": .number(Double(copper?.zones.count ?? 0)), "keepouts": .number(Double(copper?.keepouts.count ?? 0)),
            "variants": .array(d.variants.map { ["id": .string($0.id.uuidString.lowercased()), "name": .string($0.name)] }),
            "copper_check": .string(pcbIsCurrent ? "current" : "pending"),
            "errors": .number(Double(issues.filter { $0.severity == .error }.count)),
            "warnings": .number(Double(issues.filter { $0.severity == .warning }.count)),
        ]
        if let board, pcbIsCurrent {
            fields["connections_to_route"] = .array(board.airwires.map { a in
                ["net": .string(netName(a.netID)), "from": .string(reference(a.fromComponent)), "to": .string(reference(a.toComponent)),
                 "from_point": Self.point(a.from), "to_point": Self.point(a.to)]
            })
        }
        return result("Circuito «\(d.name)»: \(d.components.count) componenti, \(d.nets.count) reti", fields)
    }

    /// What can be added: the engine's generic models, then the devices of the circuit's library.
    private func library() -> ToolResult {
        let choices = deviceChoices
        return result("\(choices.count) componenti disponibili", ["devices": .array(choices.map { c in
            let symbol = symbolFor(c)
            return ["device": .string(Self.deviceKey(c)), "name": .string(c.name), "detail": .string(c.detail),
                    "reference_prefix": .string(c.prefix), "default_value": .string(c.defaultValue),
                    "pins": .array((symbol?.pins ?? []).map { pin in
                        ["number": .string(pin.number ?? pin.name), "name": .string(pin.name), "type": .string(pin.electricalType.rawValue)]
                    })]
        })])
    }

    private func pins(_ args: [String: JSONValue]) throws -> ToolResult {
        guard let d = design, let given = args["component"]?.string else { throw CircuitEditError("Serve component.") }
        let id = try componentID(given, in: d)
        let list = try ElectronicsCommands.pins(of: id, in: d)
        let reference = d.components.first { $0.id == id }?.reference ?? given
        return result("\(list.count) pin di \(reference)", ["component": .string(reference), "pins": .array(list.map { pin in
            ["pin": .string("\(reference).\(pin.number)"), "number": .string(pin.number), "name": .string(pin.name),
             "type": .string(pin.electricalType.rawValue),
             "net": pin.netID.map { .string(netName($0)) } ?? .null, "no_connect": .bool(pin.explicitlyUnconnected)]
        })])
    }

    private func symbolFor(_ c: DeviceChoice) -> SymbolDefinition? {
        if let sid = c.starterID, let t = ElectronicsStarterLibrary.components.first(where: { $0.id == sid }) {
            guard let device = t.library.devices.first(where: { $0.key == t.device }) else { return nil }
            return t.library.symbols.first { $0.key == device.symbol }
        }
        guard let lib = design?.library, let device = lib.devices.first(where: { $0.key == c.key }) else { return nil }
        return lib.symbols.first { $0.key == device.symbol }
    }

    nonisolated static func deviceKey(_ c: DeviceChoice) -> String {
        c.starterID ?? "\(c.key.id.uuidString.lowercased())/\(c.key.revision)"
    }

    private func componentID(_ given: String, in d: ElectronicsDesign) throws -> UUID {
        let matches = d.components.filter { $0.id.uuidString.lowercased() == given.lowercased() || $0.reference == given }
        guard matches.count == 1 else { throw CircuitEditError(matches.isEmpty ? "Componente sconosciuto: \(given)." : "Riferimento ambiguo: \(given); usare l'id.") }
        return matches[0].id
    }

    /// «R1.2»: pin 2 (number, else name) of R1.
    private func pinReferences(_ args: [String: JSONValue], in d: ElectronicsDesign) throws -> [PinReference] {
        guard let list = args["pins"]?.array, !list.isEmpty else { throw CircuitEditError("Serve pins: [\"R1.1\", \"C1.2\"…] (riferimento.pin).") }
        return try list.map { item in
            guard let text = item.string, let dot = text.lastIndex(of: ".") else { throw CircuitEditError("Pin «\(item.string ?? "?")»: scrivere riferimento.pin, es. R1.2.") }
            let id = try componentID(String(text[..<dot]), in: d)
            let wanted = String(text[text.index(after: dot)...])
            let all = try ElectronicsCommands.pins(of: id, in: d)
            let byNumber = all.filter { $0.number == wanted }
            let found = byNumber.isEmpty ? all.filter { $0.name == wanted } : byNumber
            guard found.count == 1 else { throw CircuitEditError(found.isEmpty ? "Pin sconosciuto: \(text). Vedere circuit_pins." : "Pin ambiguo: \(text).") }
            return found[0].reference
        }
    }

    private func fabricationCheck(_ args: [String: JSONValue]) async throws -> ToolResult {
        guard let doc = document else { throw CircuitEditError("Nessun circuito aperto.") }
        var profile = FabricationProfile()
        if let v = args["solder_mask_expansion"]?.number { profile.solderMaskExpansion = v }
        if let v = args["paste_inset"]?.number { profile.pasteInset = v }
        if let v = args["tent_vias"]?.bool { profile.tentVias = v }
        var variant: UUID?
        if let given = args["variant"]?.string {
            guard let v = doc.design.variants.first(where: { $0.id.uuidString.lowercased() == given.lowercased() || $0.name == given }) else {
                throw CircuitEditError("Variante sconosciuta: \(given). Le varianti sono in circuit_info.")
            }
            variant = v.id
        }
        let token = designRevision, chosen = variant, revision = doc.revision, settings = profile
        let checked = await Self.offMain { () -> Result<FabricationPreview, CircuitEditError> in
            do { return .success(try ElectronicsFabrication.preview(document: doc, expectedRevision: revision, profile: settings, variantID: chosen)) }
            catch { return .failure(CircuitEditError(Self.describe(error))) }
        }
        try Task.checkCancellation()
        guard designRevision == token else { throw CircuitEditError("Il circuito è cambiato durante la verifica: ripeterla.") }
        let p = try checked.get()
        return result(p.canExport ? "Pronta per la produzione (\(p.issues.count) avvisi)" : "Non esportabile: \(p.issues.filter { $0.severity == .error }.count) errori", [
            "can_export": .bool(p.canExport), "variant": chosen.map { .string($0.uuidString.lowercased()) } ?? .null,
            "profile": ["solder_mask_expansion": .number(p.profile.solderMaskExpansion), "paste_inset": .number(p.profile.pasteInset), "tent_vias": .bool(p.profile.tentVias)],
            "layers": .array(p.layers.map { ["file": .string($0.kind.fileName), "objects": .number(Double($0.objects.count))] }),
            "holes": .number(Double(p.drills.count)),
            "issues": .array(p.issues.map(Self.describe)),
            "export": "L'export dei file si fa nell'app: CIRCUITI › PRODUZIONE › Gerber (cartella nuova, nessuna modifica del circuito).",
        ])
    }

    // MARK: Preview and confirmation

    private func preview(_ args: [String: JSONValue]) async throws -> ToolResult {
        guard let doc = document else { throw CircuitEditError("Nessun circuito aperto.") }
        let (command, subjects) = try command(from: args, design: doc.design)
        let token = designRevision, revision = doc.revision
        let computed = await Self.offMain { () -> Result<ElectronicsCommandPreview, CircuitEditError> in
            do { return .success(try ElectronicsCommands.preview(command, document: doc, expectedRevision: revision)) }
            catch { return .failure(CircuitEditError(Self.describe(error))) }
        }
        try Task.checkCancellation()
        guard designRevision == token else { throw CircuitEditError("Il circuito è cambiato durante l'anteprima: rileggere circuit_info e rifarla.") }
        let p: ElectronicsCommandPreview
        switch computed {
        case .success(let value): p = value
        case .failure(let e): throw CircuitEditError("\(command.title) rifiutato dal motore: \(e.message)")
        }
        let id = UUID().uuidString.lowercased()
        // Only previews of this very circuit can still be confirmed; keep the last few.
        toolPreviews = toolPreviews.filter { $0.value.token == token }
        if toolPreviews.count >= 16 { toolPreviews.removeAll() }
        toolPreviews[id] = ToolPreview(command: command, token: token, canApply: p.canApply, blocking: p.blockingIssues, subjects: subjects)
        let before = Set(issues.map(Self.issueKey))
        let fresh = p.issues.filter { !before.contains(Self.issueKey($0)) }
        let text = p.canApply
            ? "Anteprima «\(command.title)»: applicabile con circuit_apply e preview_id. Nulla è cambiato."
            : "Anteprima «\(command.title)»: bloccata da \(p.blockingIssues.count) errori sul rame. Nulla è cambiato."
        return result(text, [
            "preview_id": .string(id), "title": .string(command.title), "can_apply": .bool(p.canApply),
            "blocking_issues": .array(p.blockingIssues.map(Self.describe)),
            "new_issues": .array(fresh.map(Self.describe)),
            "errors_after": .number(Double(p.issues.filter { $0.severity == .error }.count)),
            "connections_to_route_after": .number(Double(p.board.airwires.count)),
            "changed": false,
        ])
    }

    private func applyPreview(_ args: [String: JSONValue]) async throws -> ToolResult {
        guard let id = args["preview_id"]?.string?.lowercased(), let stored = toolPreviews[id] else {
            throw CircuitEditError("Anteprima sconosciuta o scaduta: rifarla con circuit_preview.")
        }
        guard stored.token == designRevision, let doc = document else {
            toolPreviews[id] = nil
            throw CircuitEditError("Anteprima fatta su un altro stato del circuito: rifarla con circuit_preview.")
        }
        guard stored.canApply else {
            throw CircuitEditError("\(stored.command.title) bloccato dal controllo del rame: " + stored.blocking.map { "\($0.subject): \($0.message)" }.joined(separator: "; "))
        }
        toolPreviews.removeAll()
        let revision = doc.revision, steps = doc.past.count
        if case .pcb(let copper) = stored.command {
            // Copper runs off the main thread, like the workspace; the refusal comes back as text.
            let saved = report
            var said = ""
            report = { said = $0; saved($0) }
            let done = await runPCB(copper, expectedRevision: revision)
            report = saved
            guard done else { throw CircuitEditError(said.isEmpty ? "\(stored.command.title) non applicato." : said) }
        } else {
            try apply(stored.command, expectedRevision: revision)
        }
        // A change that changed nothing (a move to where it already is) is no step: nothing to own.
        guard let after = document, after.revision != revision, after.past.count == steps + 1, let step = after.past.last else {
            return result("\(stored.command.title): nessun cambiamento", ["changed": false, "title": .string(stored.command.title)])
        }
        assistantSteps.removeAll { $0.epoch != documentEpoch || $0.position >= steps }
        assistantSteps.append(AssistantStep(epoch: documentEpoch, position: steps, edit: step))
        if let component = stored.subjects.first(where: { s in design?.components.contains { $0.id == s } == true }) {
            selection = component; canvas = .board
        }
        return result("\(stored.command.title): fatto (un passo di Annulla)", ["changed": true, "title": .string(stored.command.title)],
                      changed: stored.subjects)
    }

    private func restore(redo: Bool) throws -> ToolResult {
        guard redo ? assistantCanRedo : assistantCanUndo else {
            throw CircuitEditError(redo ? "Niente da ripetere dell'assistente (o il circuito è cambiato dopo)."
                                        : "Il prossimo passo da annullare non è dell'assistente: non lo annullo.")
        }
        let revision = document?.revision
        if redo { self.redo() } else { undo() }
        guard document?.revision != revision else { throw CircuitEditError("Annulla/Ripeti non riuscito.") }
        toolPreviews.removeAll()
        return result(redo ? "Ripetuto" : "Annullato", ["changed": true])
    }

    // MARK: Commands from arguments

    private func command(from args: [String: JSONValue], design d: ElectronicsDesign) throws -> (ElectronicsCommand, [UUID]) {
        guard let action = args["action"]?.string else { throw CircuitEditError("Parametro richiesto: action.") }
        // Fields of another action are a mistake to correct, not something to ignore silently.
        if let allowed = Self.actionFields[action] {
            let extra = Set(args.keys).subtracting(allowed + ["action", "expected_revision"])
            if !extra.isEmpty {
                throw CircuitEditError("\(action) usa solo: \(allowed.joined(separator: ", ")). Non valgono qui: \(extra.sorted().joined(separator: ", ")).")
            }
        }
        func number(_ key: String) throws -> Double {
            guard let v = args[key]?.number, v.isFinite else { throw CircuitEditError("Per \(action) serve \(key) (numero, mm).") }
            return v
        }
        func component() throws -> UUID {
            guard let given = args["component"]?.string else { throw CircuitEditError("Per \(action) serve component (riferimento come R1, o id).") }
            return try componentID(given, in: d)
        }
        func placed(_ id: UUID) throws -> ComponentPlacement {
            guard let p = d.board.placements.first(where: { $0.componentID == id }) else { throw CircuitEditError("Il componente non è ancora posato sul PCB.") }
            return p
        }
        func net() throws -> UUID {
            guard let given = args["net"]?.string else {
                throw CircuitEditError(action == "rename_net" ? "rename_net vuole net (nome attuale) e name (nome nuovo), es. {action: rename_net, net: \"N1\", name: \"VCC\"}."
                                                              : "Per \(action) serve net (nome o id).")
            }
            let matches = d.nets.filter { $0.id.uuidString.lowercased() == given.lowercased() || $0.name == given }
            guard matches.count == 1 else { throw CircuitEditError(matches.isEmpty ? "Rete sconosciuta: \(given)." : "Nome di rete ambiguo: \(given); usare l'id.") }
            return matches[0].id
        }
        func layer() throws -> Int {
            switch args["layer"]?.string ?? "top" {
            case "top": return 0
            case "bottom": return layerCount - 1
            case let other: throw CircuitEditError("Strato sconosciuto: \(other) (top o bottom).")
            }
        }
        switch action {
        case "move_component":
            let id = try component(); _ = try placed(id)
            return (.moveComponent(id: id, to: PCBPoint(try number("x"), try number("y"))), [id])
        case "rotate_component":
            let id = try component(); _ = try placed(id)
            return (.rotateComponent(id: id, by: try number("degrees")), [id])
        case "flip_component":
            let id = try component(); _ = try placed(id)
            return (.flipComponent(id), [id])
        case "remove_component":
            let id = try component()
            return (.removeComponent(id), [id])
        case "set_board":
            let w = try number("width"), h = try number("height")
            guard w > 0, h > 0 else { throw CircuitEditError("Larghezza e altezza devono essere positive.") }
            let thickness = try args["thickness"] == nil ? d.board.thickness : number("thickness")
            return (.setBoard(outline: [PCBPoint(0, 0), PCBPoint(w, 0), PCBPoint(w, h), PCBPoint(0, h)],
                              thickness: thickness, assemblyOrigin: d.board.assemblyOrigin), [])
        case "rename_net":
            let id = try net()
            guard let name = args["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CircuitEditError("rename_net vuole net (nome attuale) e name (nome nuovo), es. {action: rename_net, net: \"N1\", name: \"VCC\"}.")
            }
            return (.renameNet(id: id, name: name), [id])
        case "add_track":
            let id = try net()
            guard let raw = args["points"]?.array, raw.count >= 2 else { throw CircuitEditError("Per add_track servono almeno due points {x, y}.") }
            let points = try raw.map { p -> PCBPoint in
                guard let x = p["x"]?.number, let y = p["y"]?.number, x.isFinite, y.isFinite else { throw CircuitEditError("Ogni punto vuole x e y (mm).") }
                return PCBPoint(x, y)
            }
            let width = try args["width"] == nil ? minimumTrackWidth(net: id) : number("width")
            let track = PCBTrack(netID: id, layer: try layer(), width: width, points: points)
            return (.pcb(.addTrack(track)), [track.id])
        case "add_via":
            let id = try net()
            var via = PCBVia(netID: id, position: PCBPoint(try number("x"), try number("y")))
            if args["diameter"] != nil { via.diameter = try number("diameter") }
            if args["drill"] != nil { via.drill = try number("drill") }
            return (.pcb(.addVia(via)), [via.id])
        case "add_component":
            guard let given = args["device"]?.string,
                  let choice = deviceChoices.first(where: { Self.deviceKey($0) == given || $0.name == given }) else {
                throw CircuitEditError("Per add_component serve device da circuit_library.")
            }
            let reference = args["reference"]?.string ?? nextReference(prefix: choice.prefix)
            guard !d.components.contains(where: { $0.reference == reference }) else { throw CircuitEditError("Riferimento già usato: \(reference).") }
            let xs = d.board.outline.map(\.x), ys = d.board.outline.map(\.y)
            let at = PCBPoint(try args["x"] == nil ? ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2 : number("x"),
                              try args["y"] == nil ? ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2 : number("y"))
            let side: BoardSide = args["side"]?.string == "bottom" ? .bottom : .top
            let placing = Placing(device: choice.key, starterID: choice.starterID, name: choice.name, prefix: choice.prefix,
                                  reference: reference, value: args["value"]?.string ?? choice.defaultValue, side: side)
            let command = placeCommand(placing, at: at)
            return (command, [placing.componentID])
        case "connect":
            let pins = try pinReferences(args, in: d)
            guard Set(pins).count == pins.count, pins.count >= 2 || args["net"] != nil else {
                throw CircuitEditError("connect vuole almeno due pin diversi, o un pin e net.")
            }
            let net: CircuitNet
            if let name = args["net"]?.string {
                let found = d.nets.filter { $0.name == name || $0.id.uuidString.lowercased() == name.lowercased() }
                guard found.count <= 1 else { throw CircuitEditError("Nome di rete ambiguo: \(name); usare l'id.") }
                net = found.first ?? CircuitNet(name: name)
            } else {
                // The net one of the pins is already on, or a new one (N1, N2…), as the workspace does.
                let current = Set(pins.compactMap { p in d.connections.first { $0.pin == p }?.netID })
                guard current.count <= 1 else { throw CircuitEditError("I pin sono già su reti diverse: scollegarne uno o indicare net.") }
                if let id = current.first, let existing = d.nets.first(where: { $0.id == id }) { net = existing }
                else {
                    var k = 1
                    while d.nets.contains(where: { $0.name == "N\(k)" }) { k += 1 }
                    net = CircuitNet(name: "N\(k)")
                }
            }
            return (.connect(pins: pins, net: net), pins.map(\.componentID))
        case "disconnect":
            let pins = try pinReferences(args, in: d)
            return (.disconnect(pins), pins.map(\.componentID))
        case "no_connect":
            let pins = try pinReferences(args, in: d)
            return (.markNoConnect(pins), pins.map(\.componentID))
        case "remove_copper":
            guard let given = args["id"]?.string?.lowercased(), let copper = d.board.copper else { throw CircuitEditError("Per remove_copper serve id (di pista, via, piano o area vietata).") }
            if let t = copper.tracks.first(where: { $0.id.uuidString.lowercased() == given }) { return (.pcb(.removeTrack(t.id)), [t.id]) }
            if let v = copper.vias.first(where: { $0.id.uuidString.lowercased() == given }) { return (.pcb(.removeVia(v.id)), [v.id]) }
            if let z = copper.zones.first(where: { $0.id.uuidString.lowercased() == given }) { return (.pcb(.removeZone(z.id)), [z.id]) }
            if let k = copper.keepouts.first(where: { $0.id.uuidString.lowercased() == given }) { return (.pcb(.removeKeepout(k.id)), [k.id]) }
            throw CircuitEditError("Nessuna pista, via, piano o area vietata con id \(given).")
        default:
            throw CircuitEditError("Azione sconosciuta: \(action).")
        }
    }

    /// The fields each `circuit_preview` action takes (the others are refused with this list).
    nonisolated static let actionFields: [String: [String]] = [
        "add_component": ["device", "reference", "value", "x", "y", "side"],
        "connect": ["pins", "net"], "disconnect": ["pins"], "no_connect": ["pins"],
        "move_component": ["component", "x", "y"], "rotate_component": ["component", "degrees"],
        "flip_component": ["component"], "remove_component": ["component"],
        "set_board": ["width", "height", "thickness"], "rename_net": ["net", "name"],
        "add_track": ["net", "points", "layer", "width"], "add_via": ["net", "x", "y", "diameter", "drill"],
        "remove_copper": ["id"],
    ]

    // MARK: Results

    private func result(_ text: String, _ fields: [String: JSONValue], error: Bool = false, changed: [UUID] = []) -> ToolResult {
        var data = fields
        data["revision"] = .string(designRevision)
        data["can_undo"] = .bool(assistantCanUndo)
        data["can_redo"] = .bool(assistantCanRedo)
        data["undo_title"] = assistantCanUndo ? document?.past.last.map { .string($0.title) } ?? .null : .null
        return ToolResult(text: text, structured: .object(data), isError: error, changedFeatures: changed)
    }

    private func netName(_ id: UUID) -> String { design?.nets.first { $0.id == id }?.name ?? id.uuidString.lowercased() }
    private func reference(_ id: UUID) -> String { design?.components.first { $0.id == id }?.reference ?? id.uuidString.lowercased() }

    /// The schema subset the catalogue uses: type, enum, minimum/maximum, length, items, object
    /// properties. Unknown keys inside objects are refused like at the top level.
    nonisolated static func validate(_ value: JSONValue, _ schema: JSONValue, _ path: String) throws {
        func fail(_ what: String) -> CircuitEditError { CircuitEditError("\(path): \(what).") }
        switch schema["type"]?.string {
        case "string":
            guard let s = value.string else { throw fail("deve essere una stringa") }
            if let options = schema["enum"]?.array?.compactMap(\.string), !options.contains(s) { throw fail("valori ammessi \(options.joined(separator: ", "))") }
            if let n = schema["minLength"]?.number, Double(s.count) < n { throw fail("troppo corto") }
            if let n = schema["maxLength"]?.number, Double(s.count) > n { throw fail("troppo lungo") }
        case "number":
            guard let x = value.number, x.isFinite else { throw fail("deve essere un numero") }
            if let n = schema["minimum"]?.number, x < n { throw fail("almeno \(n)") }
            if let n = schema["maximum"]?.number, x > n { throw fail("al massimo \(n)") }
        case "boolean":
            guard value.bool != nil else { throw fail("deve essere true o false") }
        case "array":
            guard let items = value.array else { throw fail("deve essere un elenco") }
            if let n = schema["minItems"]?.number, Double(items.count) < n { throw fail("almeno \(Int(n)) elementi") }
            if let n = schema["maxItems"]?.number, Double(items.count) > n { throw fail("al massimo \(Int(n)) elementi") }
            for (i, item) in items.enumerated() { try validate(item, schema["items"] ?? .null, "\(path)[\(i)]") }
        case "object":
            guard case let .object(o) = value else { throw fail("deve essere un oggetto") }
            let properties: [String: JSONValue]
            if case let .object(p)? = schema["properties"] { properties = p } else { properties = [:] }
            if let extra = o.keys.first(where: { properties[$0] == nil }) { throw fail("chiave sconosciuta \(extra)") }
            for key in schema["required"]?.array?.compactMap(\.string) ?? [] where o[key] == nil { throw fail("manca \(key)") }
            for (key, v) in o { try validate(v, properties[key] ?? .null, "\(path).\(key)") }
        default: break
        }
    }

    nonisolated static func point(_ p: PCBPoint) -> JSONValue { ["x": .number(p.x), "y": .number(p.y)] }

    nonisolated static func describe(_ issue: ElectronicsIssue) -> JSONValue {
        var o: [String: JSONValue] = ["severity": .string(issue.severity.rawValue), "code": .string(issue.code),
                                      "subject": .string(issue.subject), "message": .string(issue.message)]
        if let ids = issue.subjectIDs { o["subject_ids"] = .array(ids.map { .string($0.uuidString.lowercased()) }) }
        if let p = issue.position { o["position"] = point(p) }
        return .object(o)
    }

    nonisolated static func issueKey(_ issue: ElectronicsIssue) -> String {
        "\(issue.code)|\(issue.subject)|\(issue.message)|\(issue.subjectIDs ?? [])"
    }
}

/// The CIRCUITI tools as MCP and the chat see them: prefix `circuit_`, the circuit open in the
/// CIRCUITI workspace, millimetres, board seen from above (Y up).
enum CircuitToolCatalog {
    static let tools: [ToolSpec] = {
        let revision: JSONValue = ["type": "string", "description": "Exact `revision` token from the latest circuit_* result. It names this circuit, this open file and its revision: stale tokens are rejected; reread circuit_info."]
        let coordinate: JSONValue = ["type": "number", "minimum": -10000, "maximum": 10000]
        let size: JSONValue = ["type": "number", "minimum": 0.01, "maximum": 10000]
        let point: JSONValue = object(["x": coordinate, "y": coordinate], required: ["x", "y"])
        func tool(_ key: String, _ title: String, _ description: String, _ properties: [String: JSONValue] = [:],
                  required: [String] = [], write: Bool = false) -> ToolSpec {
            var p = properties
            if write { p["expected_revision"] = revision }
            return ToolSpec(name: key, title: title,
                description: description + " Circuit open in CIRCUITI; mm, board seen from above. " + (write ? "Pass expected_revision; sequence writes using each returned revision." : "Read-only; returns the current revision token."),
                inputSchema: object(p, required: required + (write ? ["expected_revision"] : [])), isReadOnly: !write)
        }
        return [
            tool("circuit_info", "Circuito", "The open circuit: identity, board outline and copper layers, components (id, reference, value, position, rotation, side), nets, tracks, vias, variants, connections still to route and error/warning counts."),
            tool("circuit_issues", "Controlli circuito", "Every electrical, placement and copper (DRC) issue of the open circuit, with subject ids and board position."),
            tool("circuit_library", "Libreria circuito", "Devices that can be added with circuit_preview add_component: device key, name, reference prefix, default value and pins (number, name, electrical type). Generic models first; verify footprint and pinout against the real part."),
            tool("circuit_pins", "Pin componente", "Pins of one component: «REF.number» names to use in connect/disconnect/no_connect, electrical type, net and no-connect mark.", [
                "component": ["type": "string", "description": "Reference (R1) or id."],
            ], required: ["component"]),
            tool("circuit_fabrication_check", "Verifica produzione", "Fabrication preflight (two-layer Gerber X2, Excellon drill, BOM/CPL) without writing files: can_export, layers, holes and issues for an optional assembly variant and profile. Export itself is done by the user in the app.", [
                "variant": ["type": "string", "description": "Assembly variant name or id from circuit_info; omit for all components."],
                "solder_mask_expansion": ["type": "number", "minimum": 0, "maximum": 5],
                "paste_inset": ["type": "number", "minimum": 0, "maximum": 5],
                "tent_vias": ["type": "boolean"],
            ]),
            tool("circuit_preview", "Anteprima modifica circuito", "Actions: add_component {device (from circuit_library), reference?, value?, x?, y?, side?} (placed on the board, default centre); connect {pins [R1.1, C1.2…], net?} (net name or id; new net N1… if omitted and no pin is on a net); disconnect {pins}; no_connect {pins} (mark unused pins); move_component {component, x, y}; rotate_component {component, degrees (CCW)}; flip_component {component} (other board side); remove_component {component}; set_board {width, height, thickness?} (rectangle from 0,0); rename_net {net, name}; add_track {net, points [{x,y}…], layer top|bottom, width?} (width defaults to the net's minimum); add_via {net, x, y, diameter?, drill?}; remove_copper {id} (track, via, plane or keepout). Returns preview_id, can_apply, blocking_issues, new_issues; nothing changes until circuit_apply with that preview_id. component = reference (R1) or id; net = name or id. Copper errors created by the change block it; existing diagnostics do not.", [
                "action": ["type": "string", "enum": ["add_component", "connect", "disconnect", "no_connect", "move_component", "rotate_component", "flip_component", "remove_component", "set_board", "rename_net", "add_track", "add_via", "remove_copper"]],
                // Short (≤ 60 characters: the small on-device model sees them whole) and naming the
                // actions each field belongs to.
                "component": ["type": "string", "description": "R1 or id: move/rotate/flip/remove_component"],
                "net": ["type": "string", "description": "Existing net name: rename_net, connect, add_track/via"],
                "name": ["type": "string", "minLength": 1, "maxLength": 120, "description": "rename_net: the NEW net name"],
                "id": ["type": "string", "description": "remove_copper: track/via/plane/keepout id"],
                "device": ["type": "string", "description": "add_component: device from circuit_library"],
                "reference": ["type": "string", "minLength": 1, "maxLength": 32, "description": "add_component only: new reference, e.g. R3"],
                "value": ["type": "string", "maxLength": 64, "description": "add_component only: value, e.g. 10k"],
                "side": ["type": "string", "enum": ["top", "bottom"], "description": "add_component only: board side"],
                "pins": ["type": "array", "items": ["type": "string", "minLength": 3, "maxLength": 64], "minItems": 1, "maxItems": 64,
                         "description": "connect/disconnect/no_connect: [\"R1.2\", \"C1.1\"]"],
                "x": coordinate, "y": coordinate, "degrees": ["type": "number", "minimum": -360, "maximum": 360, "description": "rotate_component: CCW degrees"],
                "width": size, "height": size, "thickness": size, "diameter": size, "drill": size,
                "layer": ["type": "string", "enum": ["top", "bottom"], "description": "add_track: copper layer"],
                "points": ["type": "array", "items": point, "minItems": 2, "maxItems": 64, "description": "add_track: path [{x, y}, …]"],
            ], required: ["action"], write: true),
            tool("circuit_apply", "Applica modifica circuito", "Apply exactly the change previewed as preview_id: one undo step. Refused if the circuit changed since the preview (other edit, undo, another file opened) or if the preview was blocked.", [
                "preview_id": ["type": "string"],
            ], required: ["preview_id"], write: true),
            tool("circuit_undo", "Annulla assistente (circuito)", "Undo the latest change the assistant applied to the circuit, only if nothing changed after it.", write: true),
            tool("circuit_redo", "Ripeti assistente (circuito)", "Redo the latest assistant change undone with circuit_undo.", write: true),
        ]
    }()

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
}
