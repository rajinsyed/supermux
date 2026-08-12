public import SupermuxMobileCore

/// The phone's ordered view of one Claude harness transcript.
///
/// Pure value type, deliberately free of any transport or actor concern, so
/// the ordering and gap rules that make the push plane safe are unit-testable
/// without a store, a stream, or a clock.
///
/// **The invariant.** Messages are unique by ``SupermuxClaudeChatMessageDTO/id``
/// and ordered by ``SupermuxClaudeChatMessageDTO/seq``. Append and update are
/// therefore the same operation applied twice-safely: re-delivering a message
/// the transcript already holds replaces it in place instead of duplicating
/// it. That is what lets the store re-anchor from history and then keep
/// applying frames that overlap the page it just loaded.
public struct SupermuxClaudeTranscript: Sendable, Equatable {
    /// Messages in ascending sequence order.
    public private(set) var messages: [SupermuxClaudeChatMessageDTO] = []

    /// Whether messages older than the loaded window remain on the Mac.
    public var hasMoreHistory = false

    /// Creates an empty transcript.
    public init() {}

    /// The oldest loaded sequence, used as the `before_seq` paging cursor.
    public var oldestSeq: UInt64? { messages.first?.seq }

    /// The newest loaded sequence.
    public var newestSeq: UInt64? { messages.last?.seq }

    /// Inserts or replaces messages, keeping sequence order.
    ///
    /// Used for BOTH `append` and `update` frames: the Mac distinguishes them
    /// so a coalescing observer can say what it meant, but the client's
    /// obligation is identical and stating it once removes a whole class of
    /// duplicate-row bug.
    ///
    /// - Parameter incoming: Messages to merge.
    public mutating func merge(_ incoming: [SupermuxClaudeChatMessageDTO]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in incoming {
            byID[message.id] = message
        }
        messages = byID.values.sorted { lhs, rhs in
            if lhs.seq == rhs.seq { return lhs.id < rhs.id }
            return lhs.seq < rhs.seq
        }
    }

    /// Replaces the whole transcript with an authoritative history page.
    /// - Parameters:
    ///   - page: The page returned by `claude.history`.
    ///   - hasMore: Whether older messages remain.
    public mutating func replace(with page: [SupermuxClaudeChatMessageDTO], hasMore: Bool) {
        messages = []
        merge(page)
        hasMoreHistory = hasMore
    }

    /// Prepends an older history page fetched by paging backwards.
    /// - Parameters:
    ///   - page: The older page.
    ///   - hasMore: Whether still older messages remain.
    public mutating func prepend(_ page: [SupermuxClaudeChatMessageDTO], hasMore: Bool) {
        merge(page)
        hasMoreHistory = hasMore
    }

    /// Drops every message (a `reset` frame, before the re-anchor lands).
    public mutating func clear() {
        messages = []
        hasMoreHistory = false
    }
}

/// What a client must do with one inbound ``SupermuxClaudeEventFrame``.
///
/// Separated from the store so the ordering rule — the part that decides
/// whether the phone's transcript can silently diverge from the Mac's — is
/// testable as a pure function.
public enum SupermuxClaudeFrameDisposition: Sendable, Equatable {
    /// Apply the frame directly; it is the next expected event.
    case apply
    /// Already applied (a duplicate delivery); ignore it.
    case duplicate
    /// A gap: re-anchor from history, then adopt this frame's number.
    case reanchor
}

/// Decides what to do with an inbound frame, given the last applied number.
///
/// - `nil` last-number means nothing has been applied yet, so ANY frame is a
///   re-anchor: the client must load history before it can place the frame.
/// - Exactly-next is the only case that applies directly.
/// - Not-newer is a duplicate; the transport may redeliver.
/// - Anything further ahead means frames were lost (the event queue is
///   allowed to drop under pressure), so pull-authoritative history wins.
///
/// - Parameters:
///   - eventNo: The inbound frame's monotonic number, or `nil` when the
///     payload failed to decode (treated as a gap — an undecodable frame is
///     indistinguishable from a missing one).
///   - lastAppliedEventNo: The last number this client applied.
public func supermuxClaudeFrameDisposition(
    eventNo: UInt64?,
    lastAppliedEventNo: UInt64?
) -> SupermuxClaudeFrameDisposition {
    guard let eventNo else { return .reanchor }
    guard let lastAppliedEventNo else { return .reanchor }
    if eventNo == lastAppliedEventNo + 1 { return .apply }
    if eventNo <= lastAppliedEventNo { return .duplicate }
    return .reanchor
}
