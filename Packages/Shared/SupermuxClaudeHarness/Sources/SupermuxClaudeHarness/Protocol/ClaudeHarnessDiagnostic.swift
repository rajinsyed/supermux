import Foundation

/// A non-fatal protocol observation surfaced to the session log.
///
/// Diagnostics never terminate a live session; they exist so silent oddities
/// (launcher banners, malformed lines, unanswerable control requests) remain
/// visible instead of disappearing.
public enum ClaudeHarnessDiagnostic: Sendable, Equatable {
    /// A non-JSON stdout line, e.g. the ccx ANSI banner (already stripped).
    case launcherNotice(String)
    /// A `{`-prefixed line that failed JSON parsing.
    case malformedLine(String)
    /// A stdout line exceeding the byte bound; content was discarded.
    case oversizedLine(byteCount: Int)
    /// A structurally valid line with an unrecognized top-level type.
    case unknownLine(rawType: String?)
    /// An inbound `control_request` was decoded and deliberately not answered
    /// (permissions are always skipped; no answer path exists).
    case inboundControlRequestIgnored(subtype: String?, requestID: String?)
    /// A `control_response` for an ID that is not pending (late or unknown).
    case unmatchedControlResponse(requestID: String?)
    /// Accumulated `input_json_delta` fragments failed to decode at
    /// `content_block_stop`; the raw partial text is preserved on the block.
    case toolInputUndecodable(toolUseID: String?, messageID: String?)
    /// The authoritative `assistant` line's tool input differed from the
    /// reassembled streamed input; the authoritative input wins.
    case toolInputMismatch(toolUseID: String)
    /// A resumed process reported a different provider session ID than the
    /// persisted resume identity; the process is not attached to the session.
    case resumeSessionMismatch(expected: String, observed: String)
    /// The explicit initialize control failed or timed out. The session remains
    /// usable by dispatching the first queued user frame while handshaking.
    case initializeFallback(message: String)
}
