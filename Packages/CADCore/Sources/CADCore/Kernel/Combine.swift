import Foundation

/// «Combina» (Fusion's Combine): tool bodies joined to, cut from or intersected with a target
/// body; the tools disappear unless kept.
public struct CombineSpec: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        case join, cut, intersect
        public var label: String {
            switch self { case .join: "Unisci"; case .cut: "Taglia"; case .intersect: "Interseca" }
        }
    }
    /// The body that is changed (its source feature).
    public var target: UUID
    /// The bodies used on it (their source features).
    public var tools: [UUID]
    public var operation: Operation
    /// The tools stay as bodies of their own (Fusion's «Mantieni corpi strumento»).
    public var keepTools: Bool

    public init(target: UUID, tools: [UUID], operation: Operation = .join, keepTools: Bool = false) {
        self.target = target; self.tools = tools; self.operation = operation; self.keepTools = keepTools
    }

    public func validate() throws {
        guard !tools.isEmpty else { throw KernelError.invalidParameter("combina: nessun corpo strumento") }
        guard !tools.contains(target) else { throw KernelError.invalidParameter("combina: il corpo obiettivo non può essere anche strumento") }
    }
}
