public import CmuxAgentChat
import Foundation

/// Collapses runs of agent "work" rows so the transcript reads as prose.
///
/// A coding-agent session is mostly tool calls: reads, greps, edits, shell
/// commands. Rendered one row each they bury the handful of sentences the
/// agent actually said, which is the thing the user opened the phone to read.
/// Focus mode folds each consecutive run of work rows into a single
/// "Working…" summary the user can expand on demand.
///
/// A value with an explicit `minimumGroupSize` rather than a namespace of
/// static helpers, so the fold is configurable and unit-testable without a
/// view, and so the transcript's diffing still sees stable values.
public struct SupermuxChatFocusGrouping: Sendable {
    /// One entry in the focus-mode transcript.
    public enum Item: Identifiable, Equatable {
        /// A row shown as-is (prose, user prompts, questions, permissions…).
        case row(ChatTranscriptRow)
        /// A collapsed run of consecutive work rows.
        case workGroup(WorkGroup)

        public var id: String {
            switch self {
            case .row(let row): return row.id
            case .workGroup(let group): return group.id
            }
        }
    }

    /// A folded run of consecutive work rows.
    public struct WorkGroup: Identifiable, Equatable, Sendable {
        /// Stable identity, derived from the run's first row so the group keeps
        /// its identity — and the user's expanded disclosure — as later rows
        /// stream into the same run.
        public let id: String
        /// The folded rows, in transcript order.
        public let rows: [ChatTranscriptRow]

        /// Creates a work group.
        public init(id: String, rows: [ChatTranscriptRow]) {
            self.id = id
            self.rows = rows
        }

        /// How many rows the summary stands for.
        public var count: Int { rows.count }
    }

    /// Runs shorter than this stay expanded: folding a single tool call costs
    /// the user a tap and saves nothing.
    public let minimumGroupSize: Int

    /// Creates a grouping.
    ///
    /// - Parameter minimumGroupSize: Shortest run that may fold.
    public init(minimumGroupSize: Int = 2) {
        self.minimumGroupSize = max(2, minimumGroupSize)
    }

    /// Folds `rows` into focus-mode items.
    ///
    /// - Parameters:
    ///   - rows: The transcript rows, oldest first.
    ///   - isEnabled: When `false`, every row passes through untouched, so the
    ///     caller can bind this straight to the setting.
    /// - Returns: The items to render.
    public func items(
        for rows: [ChatTranscriptRow],
        isEnabled: Bool = true
    ) -> [Item] {
        guard isEnabled else { return rows.map(Item.row) }

        var items: [Item] = []
        var pending: [ChatTranscriptRow] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            if pending.count >= minimumGroupSize, let first = pending.first {
                items.append(.workGroup(WorkGroup(id: "work-\(first.id)", rows: pending)))
            } else {
                items.append(contentsOf: pending.map(Item.row))
            }
            pending.removeAll()
        }

        for row in rows {
            if Self.isWorkRow(row) {
                pending.append(row)
            } else {
                flushPending()
                items.append(.row(row))
            }
        }
        flushPending()
        return items
    }

    /// Whether a row is agent "work" rather than something the user reads or
    /// answers.
    ///
    /// Deliberately conservative. Prose and user prompts are the conversation;
    /// questions and permission requests BLOCK the agent, so hiding them would
    /// strand the session behind a disclosure the user has no reason to open;
    /// status rows and attachments are rare enough that folding them buys
    /// nothing.
    public static func isWorkRow(_ row: ChatTranscriptRow) -> Bool {
        guard case .message(let snapshot) = row else { return false }
        switch snapshot.message.kind {
        case .toolUse, .thought, .terminal, .fileEdit:
            return true
        case .prose, .question, .permissionRequest, .status, .attachment, .unsupported:
            return false
        }
    }
}
