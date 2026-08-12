public import Foundation
public import SupermuxMobileCore

/// One `supermux.*` event delivered from the paired Mac.
///
/// Almost every topic is a payload-light poke (architecture §2) — the only
/// payload field they carry is `workspace_id` on `supermux.changes.updated`
/// — and consumers refetch through the matching request method on receipt.
///
/// `supermux.claude.event` is the deliberate exception: transcript deltas are
/// far too frequent to answer with a refetch each, so it carries a compact
/// ``SupermuxClaudeEventFrame`` with a per-session monotonic `event_no`. A
/// consumer that sees a gap in those numbers re-anchors from
/// `claude.history` instead of applying the frame, so the push plane stays an
/// optimization over the pull-authoritative state rather than a second source
/// of truth.
public struct SupermuxMobileEvent: Sendable, Equatable {
    /// The event's topic.
    public let topic: SupermuxMobileTopic
    /// The workspace the event concerns (`supermux.changes.updated` only).
    public let workspaceID: String?
    /// The transcript frame (`supermux.claude.event` only). `nil` on every
    /// other topic, and on a claude event whose payload failed to decode —
    /// the consumer then treats it as a gap and re-anchors.
    public let claudeFrame: SupermuxClaudeEventFrame?

    /// Creates an event (used by tests and fakes).
    /// - Parameters:
    ///   - topic: The event's topic.
    ///   - workspaceID: The workspace the event concerns, if any.
    ///   - claudeFrame: The Claude transcript frame, if any.
    public init(
        topic: SupermuxMobileTopic,
        workspaceID: String? = nil,
        claudeFrame: SupermuxClaudeEventFrame? = nil
    ) {
        self.topic = topic
        self.workspaceID = workspaceID
        self.claudeFrame = claudeFrame
    }

    /// Maps a raw wire envelope to a typed event.
    ///
    /// Returns `nil` for topics outside the `supermux.*` set (the transport
    /// listener may be shared). A missing or malformed payload maps to a
    /// payload-less event — for the poke topics the poke itself is the
    /// signal, and for `supermux.claude.event` a `nil` frame is handled as a
    /// gap by the conversation store.
    ///
    /// - Parameters:
    ///   - topic: The envelope's raw topic string.
    ///   - payloadJSON: The envelope's raw JSON payload, if any.
    public init?(topic: String, payloadJSON: Data?) {
        guard let parsed = SupermuxMobileTopic(rawValue: topic) else { return nil }
        self.topic = parsed
        if parsed == .claudeEvent {
            self.workspaceID = nil
            self.claudeFrame = payloadJSON.flatMap {
                try? JSONDecoder().decode(SupermuxClaudeEventFrame.self, from: $0)
            }
            return
        }
        self.claudeFrame = nil
        if let payloadJSON,
           let payload = try? JSONDecoder().decode(WirePayload.self, from: payloadJSON) {
            self.workspaceID = payload.workspaceID
        } else {
            self.workspaceID = nil
        }
    }

    /// The lenient wire payload for the poke topics: only `workspace_id` is
    /// meaningful today; unknown fields are ignored.
    private struct WirePayload: Decodable {
        let workspaceID: String?

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
        }
    }
}
