public import Foundation
public import SupermuxMobileCore

/// One `supermux.*` event delivered from the paired Mac.
///
/// Events are payload-light pokes (architecture §2): the only payload field
/// any topic carries today is `workspace_id` on `supermux.changes.updated`.
/// Consumers refetch through the matching request method on receipt.
public struct SupermuxMobileEvent: Sendable, Equatable {
    /// The event's topic.
    public let topic: SupermuxMobileTopic
    /// The workspace the event concerns (`supermux.changes.updated` only).
    public let workspaceID: String?

    /// Creates an event (used by tests and fakes).
    /// - Parameters:
    ///   - topic: The event's topic.
    ///   - workspaceID: The workspace the event concerns, if any.
    public init(topic: SupermuxMobileTopic, workspaceID: String? = nil) {
        self.topic = topic
        self.workspaceID = workspaceID
    }

    /// Maps a raw wire envelope to a typed event.
    ///
    /// Returns `nil` for topics outside the `supermux.*` set (the transport
    /// listener may be shared). A missing or malformed payload maps to a
    /// payload-less event — the poke itself is the signal.
    ///
    /// - Parameters:
    ///   - topic: The envelope's raw topic string.
    ///   - payloadJSON: The envelope's raw JSON payload, if any.
    public init?(topic: String, payloadJSON: Data?) {
        guard let parsed = SupermuxMobileTopic(rawValue: topic) else { return nil }
        self.topic = parsed
        if let payloadJSON,
           let payload = try? JSONDecoder().decode(WirePayload.self, from: payloadJSON) {
            self.workspaceID = payload.workspaceID
        } else {
            self.workspaceID = nil
        }
    }

    /// The lenient wire payload: only `workspace_id` is meaningful today;
    /// unknown fields are ignored.
    private struct WirePayload: Decodable {
        let workspaceID: String?

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
        }
    }
}
