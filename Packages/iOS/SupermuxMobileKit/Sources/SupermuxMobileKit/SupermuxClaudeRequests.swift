import Foundation
public import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.claude.*` harness methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping ``SupermuxMacClient`` sends is what fakes record and tests
/// assert against. Optional params are omitted rather than sent as defaults,
/// matching the Mac handlers' present-key expectations.
///
/// Permission answering is deliberately absent: every harness session runs
/// with permissions skipped, so no `answer_permission` request type exists.

/// `mobile.supermux.claude.sessions.list`: `{}`.
public struct SupermuxClaudeSessionsListRequest: Equatable, Sendable {
    /// Creates the request.
    public init() {}

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionsList.rawValue }

    /// The exact wire params (none).
    public var wireParams: [String: Any] { [:] }
}

/// `mobile.supermux.claude.session.create`:
/// `{cwd, project_id?, launcher, model?, effort?, fast_mode, thinking_budget?, initial_prompt?}`.
public struct SupermuxClaudeSessionCreateRequest: Equatable, Sendable {
    /// The typed body (shared with the Mac through `SupermuxMobileCore`).
    public let body: SupermuxClaudeSessionCreateRequestDTO

    /// Creates the request.
    /// - Parameter body: The session-creation parameters.
    public init(body: SupermuxClaudeSessionCreateRequestDTO) {
        self.body = body
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionCreate.rawValue }

    /// The exact wire params, encoded from the shared DTO so the phone can
    /// never drift from the contract's snake_case key names.
    public var wireParams: [String: Any] { SupermuxClaudeWireEncoding.params(body) }
}

/// `mobile.supermux.claude.session.get`: `{session_id}`.
public struct SupermuxClaudeSessionGetRequest: Equatable, Sendable {
    /// Stable harness session identifier.
    public let sessionID: String

    /// Creates the request.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionGet.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { ["session_id": sessionID] }
}

/// `mobile.supermux.claude.session.resume`: `{session_id}`.
///
/// The Mac relaunches with the session's PERSISTED launcher; the phone never
/// re-sends one, so a ccx session can never silently resume as plain Claude.
public struct SupermuxClaudeSessionResumeRequest: Equatable, Sendable {
    /// Stable harness session identifier.
    public let sessionID: String

    /// Creates the request.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionResume.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { ["session_id": sessionID] }
}

/// `mobile.supermux.claude.session.end`: `{session_id}` — graceful stop that
/// keeps the session in the list for inspection and resume.
public struct SupermuxClaudeSessionEndRequest: Equatable, Sendable {
    /// Stable harness session identifier.
    public let sessionID: String

    /// Creates the request.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionEnd.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { ["session_id": sessionID] }
}

/// `mobile.supermux.claude.session.delete`: `{session_id}` — removes the
/// session record entirely (ends it first if still running).
public struct SupermuxClaudeSessionDeleteRequest: Equatable, Sendable {
    /// Stable harness session identifier.
    public let sessionID: String

    /// Creates the request.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSessionDelete.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { ["session_id": sessionID] }
}

/// `mobile.supermux.claude.send`: `{session_id, text, attachments?}`.
///
/// The Mac owns the ONLY input queue (`cmux-shared-behavior`): sending while a
/// turn is working enqueues Mac-side and answers `{queued, queue_position}`.
/// The phone never keeps its own optimistic queue copy.
public struct SupermuxClaudeSendRequest: Equatable, Sendable {
    /// The typed body.
    public let body: SupermuxClaudeSendRequestDTO

    /// Creates the request.
    /// - Parameter body: The prompt submission.
    public init(body: SupermuxClaudeSendRequestDTO) {
        self.body = body
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSend.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { SupermuxClaudeWireEncoding.params(body) }
}

/// `mobile.supermux.claude.interrupt`: `{session_id}` — a protocol interrupt
/// control, never a signal.
public struct SupermuxClaudeInterruptRequest: Equatable, Sendable {
    /// Stable harness session identifier.
    public let sessionID: String

    /// Creates the request.
    /// - Parameter sessionID: Stable harness session identifier.
    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeInterrupt.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { ["session_id": sessionID] }
}

/// `mobile.supermux.claude.set_option`: `{session_id, option, value}`.
///
/// The reply carries the RECONCILED value the Mac observed, which is what the
/// phone stores — never the requested value.
public struct SupermuxClaudeSetOptionRequest: Equatable, Sendable {
    /// The typed body.
    public let body: SupermuxClaudeSetOptionRequestDTO

    /// Creates the request.
    /// - Parameter body: The option mutation.
    public init(body: SupermuxClaudeSetOptionRequestDTO) {
        self.body = body
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeSetOption.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] { SupermuxClaudeWireEncoding.params(body) }
}

/// `mobile.supermux.claude.options`: `{session_id?}` — model catalog, effort
/// levels, slash commands, and launcher availability.
public struct SupermuxClaudeOptionsRequest: Equatable, Sendable {
    /// Optional session for model-specific current options.
    public let sessionID: String?

    /// Creates the request.
    /// - Parameter sessionID: Optional stable harness session identifier.
    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeOptions.rawValue }

    /// The exact wire params (`session_id` present only when set).
    public var wireParams: [String: Any] {
        guard let sessionID else { return [:] }
        return ["session_id": sessionID]
    }
}

/// `mobile.supermux.claude.history`: `{session_id, before_seq?, limit}`.
public struct SupermuxClaudeHistoryRequest: Equatable, Sendable {
    /// The typed body.
    public let body: SupermuxClaudeHistoryRequestDTO

    /// Creates the request.
    /// - Parameter body: The history-page parameters.
    public init(body: SupermuxClaudeHistoryRequestDTO) {
        self.body = body
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeHistory.rawValue }

    /// The exact wire params (`before_seq` present only when set).
    public var wireParams: [String: Any] { SupermuxClaudeWireEncoding.params(body) }
}

/// `mobile.supermux.claude.tool_payload`: `{session_id, message_id, offset?}`
/// — one ≤3 MiB chunk of an untruncated tool output or diff. Push events
/// never carry these bodies.
public struct SupermuxClaudeToolPayloadRequest: Equatable, Sendable {
    /// The typed body.
    public let body: SupermuxClaudeToolPayloadRequestDTO

    /// Creates the request.
    /// - Parameter body: The chunk parameters.
    public init(body: SupermuxClaudeToolPayloadRequestDTO) {
        self.body = body
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeToolPayload.rawValue }

    /// The exact wire params (`offset` present only when set).
    public var wireParams: [String: Any] { SupermuxClaudeWireEncoding.params(body) }
}

/// `mobile.supermux.claude.watch`: `{enable, client_id}` — the leased gate on
/// the per-message event firehose (TTL 120 s Mac-side, heartbeat at 60 s).
/// Session-list pokes are always on and need no lease.
public struct SupermuxClaudeWatchRequest: Equatable, Sendable {
    /// Whether to acquire/renew or release the lease.
    public let enable: Bool
    /// This device's stable watch-session id, for the Mac's per-client refcount.
    public let clientID: String

    /// Creates the request.
    /// - Parameters:
    ///   - enable: Whether to acquire/renew or release the lease.
    ///   - clientID: This device's stable watch-session id.
    public init(enable: Bool, clientID: String) {
        self.enable = enable
        self.clientID = clientID
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.claudeWatch.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["enable": enable, "client_id": clientID]
    }
}

/// Encodes a shared wire DTO into the `[String: Any]` params dictionary the
/// RPC client sends.
///
/// The DTOs in `SupermuxMobileCore` already own every wire key name (and its
/// omit-when-nil behavior). Round-tripping through `JSONEncoder` reuses those
/// declarations verbatim instead of restating them here, which is exactly the
/// drift the fork's wire tests exist to catch.
///
/// lint:allow namespace-enum — a single stateless encoding helper shared by
/// the request values above; nothing to instantiate or inject.
public enum SupermuxClaudeWireEncoding {
    /// Encodes a DTO to wire params.
    ///
    /// Returns `[:]` if the value somehow fails to encode: the request layer
    /// has no error channel, and the Mac rejects an empty body with a typed
    /// wire error the caller already surfaces.
    ///
    /// - Parameter value: The DTO to encode.
    /// - Returns: The JSON object as an RPC params dictionary.
    public static func params(_ value: some Encodable) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
