import Foundation
public import SupermuxMobileCore

/// One to-do row parsed out of a `TodoWrite` tool card.
public struct SupermuxClaudeTodo: Identifiable, Equatable, Sendable {
    /// Lifecycle of one to-do.
    public enum Status: String, Equatable, Sendable {
        /// Not started.
        case pending
        /// Currently being worked on.
        case inProgress = "in_progress"
        /// Done.
        case completed
    }

    /// Position in the list, which is also its identity: `TodoWrite` rewrites
    /// the WHOLE list each call and gives its entries no ids of their own.
    public let id: Int
    /// The to-do's text.
    public let title: String
    /// The to-do's status.
    public let status: Status

    /// Creates a to-do row.
    /// - Parameters:
    ///   - id: Position in the list.
    ///   - title: The to-do's text.
    ///   - status: The to-do's status.
    public init(id: Int, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// Parses and summarizes the `TodoWrite` tool's payload.
///
/// lint:allow namespace-enum — stateless parsing helpers.
public enum SupermuxClaudeTodoPresentation {
    /// The protocol tool name that carries a to-do list.
    public static let toolName = "TodoWrite"

    /// Whether a tool card is a to-do list.
    /// - Parameter tool: The bounded tool summary.
    public static func isTodoList(_ tool: SupermuxClaudeToolDTO) -> Bool {
        tool.name == toolName
    }

    /// Parses the to-dos out of a tool's input summary.
    ///
    /// Returns an empty array rather than throwing for ANY shape it does not
    /// recognize: the payload is bounded and re-summarized Mac-side, and a
    /// transcript that refuses to render because one card's JSON changed
    /// shape would be a far worse failure than a card that renders as a plain
    /// tool row.
    ///
    /// - Parameter tool: The bounded tool summary.
    public static func todos(in tool: SupermuxClaudeToolDTO) -> [SupermuxClaudeTodo] {
        guard isTodoList(tool),
              let summary = tool.inputSummary,
              let data = summary.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["todos"] as? [[String: Any]] else {
            return []
        }
        return entries.enumerated().compactMap { index, entry in
            guard let title = (entry["content"] as? String) ?? (entry["activeForm"] as? String),
                  !title.isEmpty else { return nil }
            let status = (entry["status"] as? String)
                .flatMap(SupermuxClaudeTodo.Status.init(rawValue:)) ?? .pending
            return SupermuxClaudeTodo(id: index, title: title, status: status)
        }
    }

    /// Completed fraction, for the card's progress ring. `0` for an empty
    /// list, so the ring is never asked to divide by zero.
    /// - Parameter todos: The parsed to-dos.
    public static func progress(_ todos: [SupermuxClaudeTodo]) -> Double {
        guard !todos.isEmpty else { return 0 }
        let done = todos.count { $0.status == .completed }
        return Double(done) / Double(todos.count)
    }

    /// The card's "3 of 7" counter.
    /// - Parameter todos: The parsed to-dos.
    public static func counter(_ todos: [SupermuxClaudeTodo]) -> String {
        let done = todos.count { $0.status == .completed }
        return String(
            localized: "supermux.claude.todos.counter",
            defaultValue: "\(done) of \(todos.count)",
            bundle: .module
        )
    }
}
