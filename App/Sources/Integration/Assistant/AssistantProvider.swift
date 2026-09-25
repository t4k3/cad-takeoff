import Foundation

// Provider-agnostic contract for the in-app assistant (T52). Claude implements it in
// ClaudeProvider.swift; Codex implements OpenAI in OpenAIProvider.swift (T53).

/// A tool call requested by the model in the current turn.
struct ToolCallRequest: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    /// nil when the streamed arguments were not valid JSON (the call must not run).
    let arguments: JSONValue?
    let rawArguments: String
}

/// Streaming events emitted while the model answers.
enum AssistantEvent: Sendable {
    case textDelta(String)
    /// Readable summary of the model's reasoning, when the provider exposes one.
    case thinkingDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolArgumentsDelta(id: String, partial: String)
    case usage(input: Int, output: Int)
    /// The provider served the turn with a different model (e.g. a fallback).
    case servedBy(model: String)
}

enum AssistantStop: Sendable, Equatable {
    case done
    case toolCalls([ToolCallRequest])
    case refused(String?)
    case truncated
}

struct AssistantError: LocalizedError, Sendable {
    var message: String
    var retryable = false
    var errorDescription: String? { message }
}

/// One conversation with one LLM. The provider owns its own history format so it can
/// replay provider-specific blocks (e.g. Claude thinking signatures) unchanged.
@MainActor
protocol AssistantProvider: AnyObject {
    /// "Claude", "ChatGPT"…
    var displayName: String { get }
    /// Model shown in the UI.
    var modelName: String { get }
    /// false when e.g. no API key is configured; `setupHint` explains what to do.
    var isConfigured: Bool { get }
    var setupHint: String { get }

    func reset()
    /// Appends a user message to the history.
    func addUserMessage(_ text: String)
    /// Appends results for the tool calls of the previous turn (all in one message).
    func addToolResults(_ results: [(ToolCallRequest, ToolResult)])
    /// Streams one model turn over the current history.
    func runTurn(system: String, tools: [ToolSpec], onEvent: @escaping (AssistantEvent) -> Void) async throws -> AssistantStop
}
