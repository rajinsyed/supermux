import Foundation
public import SupermuxClaudeHarness

/// One rendered transcript row.
///
/// Rows are a *projection* of the typed protocol lines, not a second source of
/// truth: the builder rewrites a row in place when later lines refine it (a
/// streaming text block completing, a tool call receiving its result), so the
/// list identity stays stable and SwiftUI animates instead of re-inserting.
public struct SupermuxHarnessRow: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A prompt the user sent (the CLI's replayed `user` line).
        case userPrompt(text: String)
        /// Assistant prose; `isStreaming` while the block is still open.
        case assistantProse(text: String, isStreaming: Bool)
        /// An extended-thinking block.
        case thinking(text: String, isStreaming: Bool)
        /// A tool invocation with its lifecycle state.
        case toolCall(SupermuxHarnessToolCall)
        /// The terminal `result` line's cost/duration summary.
        case result(SupermuxHarnessResultSummary)
        /// A launcher/protocol/process notice.
        case notice(SupermuxHarnessNotice)
    }

    public let id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// A tool invocation and everything known about it.
public struct SupermuxHarnessToolCall: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case running
        case succeeded
        case failed
    }

    /// The `tool_use_id`.
    public let id: String
    public let name: String
    public var input: ClaudeJSONValue
    public var status: Status
    /// Flattened textual result, for the expandable detail body.
    public var resultText: String?
    /// The root `tool_use_result` payload, when the CLI sent one.
    public var toolUseResult: ClaudeJSONValue?

    public init(
        id: String,
        name: String,
        input: ClaudeJSONValue,
        status: Status,
        resultText: String? = nil,
        toolUseResult: ClaudeJSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.status = status
        self.resultText = resultText
        self.toolUseResult = toolUseResult
    }

    /// The humanized present/past-tense label pair for this tool.
    public var labels: ClaudeToolHumanizer.Labels {
        ClaudeToolHumanizer.labels(for: name)
    }

    /// The single most identifying input value, shown beside the label
    /// (a path for file tools, the command for Bash, the pattern for search).
    public var subject: String? {
        for key in ["file_path", "path", "notebook_path", "command", "pattern", "url", "query", "description"] {
            if let value = input[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// The to-do list carried by a `TodoWrite` call, if this is one.
    public var todos: [SupermuxHarnessTodo] {
        guard name == "TodoWrite", let items = input["todos"]?.arrayValue else { return [] }
        // Position-based identity: two identically-worded steps must not
        // collide in the card's ForEach.
        return items.enumerated().compactMap { index, value in
            SupermuxHarnessTodo(index: index, value: value)
        }
    }

    /// The unified diff this call produced, when its result carries a patch.
    public var diff: SupermuxHarnessDiff? {
        SupermuxHarnessDiff.from(toolUseResult: toolUseResult)
    }
}

/// One `TodoWrite` entry.
public struct SupermuxHarnessTodo: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id: Int
    public let content: String
    public let state: State

    init?(index: Int, value: ClaudeJSONValue) {
        guard let object = value.objectValue else { return nil }
        let content = object["content"]?.stringValue
            ?? object["activeForm"]?.stringValue
            ?? ""
        guard !content.isEmpty else { return nil }
        self.id = index
        self.content = content
        self.state = State(rawValue: object["status"]?.stringValue ?? "pending") ?? .pending
    }

    public init(id: Int, content: String, state: State) {
        self.id = id
        self.content = content
        self.state = state
    }
}

/// The cost/usage summary of one completed turn.
public struct SupermuxHarnessResultSummary: Sendable, Equatable {
    public let totalCostUSD: Double?
    public let durationMs: Int?
    public let numTurns: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let isError: Bool
    public let terminalReason: String?

    public init(result: ClaudeResult) {
        self.totalCostUSD = result.totalCostUSD
        self.durationMs = result.durationMs
        self.numTurns = result.numTurns
        self.inputTokens = result.usage?.inputTokens
        self.outputTokens = result.usage?.outputTokens
        self.cacheReadTokens = result.usage?.cacheReadInputTokens
        self.isError = result.isError ?? false
        self.terminalReason = result.terminalReason
    }

    public init(
        totalCostUSD: Double?,
        durationMs: Int?,
        numTurns: Int?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        isError: Bool,
        terminalReason: String?
    ) {
        self.totalCostUSD = totalCostUSD
        self.durationMs = durationMs
        self.numTurns = numTurns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.isError = isError
        self.terminalReason = terminalReason
    }
}

/// A non-message notice: launcher output, protocol diagnostic, process end.
public struct SupermuxHarnessNotice: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case info
        case warning
        case error
    }

    public let severity: Severity
    public let title: String
    public let detail: String?

    public init(severity: Severity, title: String, detail: String? = nil) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
