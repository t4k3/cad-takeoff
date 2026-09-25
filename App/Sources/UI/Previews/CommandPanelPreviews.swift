import SwiftUI

// Mock sessions to design the panel before the Model APIs exist (see AGENTS.md: mocks only here).

#Preview("Flangia lamiera (mock)") {
    CommandPanel(session: CommandSession(
        title: "Flangia", symbol: "rectangle.portrait.and.arrow.right",
        fields: [
            .init(id: "edges", label: "Spigoli", kind: .reference(prompt: "Seleziona spigolo", maxCount: 20), value: .references([])),
            .init(id: "height", label: "Altezza", kind: .length(0.1...2000), value: .number(20)),
            .init(id: "angle", label: "Angolo", kind: .angle(0...180), value: .number(90)),
            .init(id: "side", label: "Posizione piega", kind: .choice(["Interna", "Esterna", "Sulla linea"]), value: .index(1)),
            .init(id: "relief", label: "Scarichi automatici", kind: .toggle, value: .flag(true)),
        ],
        onCommit: { _ in }), onClose: {})
    .padding(30)
}

#Preview("Serie circolare (mock)") {
    CommandPanel(session: CommandSession(
        title: "Serie circolare", symbol: "circle.dotted",
        fields: [
            .init(id: "objs", label: "Oggetti", kind: .reference(prompt: "Seleziona corpi", maxCount: 50), value: .references(["b1"])),
            .init(id: "n", label: "Quantità", kind: .count(2...360), value: .number(6)),
            .init(id: "a", label: "Angolo totale", kind: .angle(0...360), value: .number(360)),
        ],
        onCommit: { _ in }), onClose: {})
    .padding(30)
}
