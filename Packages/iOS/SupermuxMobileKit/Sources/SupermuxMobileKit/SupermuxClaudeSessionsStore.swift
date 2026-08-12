public import Foundation
import Observation
import OSLog
public import SupermuxMobileCore

/// Main-actor state for the phone's Claude harness session list: the Mac's
/// sessions, event-driven refetches, and the create/resume/end/delete
/// actions.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected, so the
/// store is unit-testable against a fake. Inert without `supermux.claude.v1`.
///
/// **The Mac is the source of truth.** `supermux.claude.sessions_updated` is
/// a payload-light poke, so every mutation is followed by a refetch rather
/// than a local edit — one mutation path, no per-entry-point optimistic copy
/// (`cmux-shared-behavior`). The only local state that outlives a refetch is
/// ``openedSessionIDs``, which is a phone-local read marker the Mac neither
/// knows nor needs.
@MainActor
@Observable
public final class SupermuxClaudeSessionsStore {
    /// The Mac's sessions, newest activity first.
    public private(set) var sessions: [SupermuxClaudeSessionDTO] = []

    /// The registry version of the last applied snapshot. An older reply is
    /// discarded rather than allowed to undo a newer one.
    public private(set) var stateVersion: UInt64 = 0

    /// Whether at least one fetch has succeeded (drives placeholder vs list).
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up.
    public private(set) var isConnected = false

    /// Whether a fetch is in flight (drives the pull-to-refresh spinner).
    public private(set) var isRefreshing = false

    /// Whether a create/resume/end/delete round trip is on the wire.
    public private(set) var isMutating = false

    /// Diagnostic description of the most recent failure. The UI uses its
    /// presence to show localized recovery copy and must never render this
    /// raw transport text. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    /// Sessions this phone has opened at least once, so a finished session
    /// the user already read stops showing its "finished, not opened" dot.
    /// Phone-local by design: read state is per-device, not Mac state.
    public private(set) var openedSessionIDs: Set<String> = []

    private static let logger = Logger(subsystem: "dev.supermux.ios", category: "claude-sessions")

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Cancellable reconnect-backoff sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    /// The fetch currently on the wire, so concurrent callers join it.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// The most recently requested conversation store (see
    /// ``conversationStore(for:)``).
    @ObservationIgnored private var cachedConversationStore: SupermuxClaudeConversationStore?

    /// Whether the phone shows the Claude harness at all: gated on the host
    /// advertising `supermux.claude.v1`.
    public var showsClaudeHarness: Bool { capabilities.supportsClaudeHarness }

    /// Creates a sessions store.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - now: Clock seam for the reconnect-health check.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.now = now
        self.idleSleep = idleSleep
    }

    /// Follows the live `supermux.claude.sessions_updated` stream until
    /// cancelled. A no-op without `supermux.claude.v1`.
    ///
    /// No watch lease is taken here: list pokes are low-rate and always on
    /// Mac-side. Only the per-message transcript firehose is leased, and that
    /// lease belongs to ``SupermuxClaudeConversationStore``.
    public func run() async {
        guard capabilities.supportsClaudeHarness else { return }
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST so pokes emitted while the initial fetch is in
            // flight buffer in the stream instead of being dropped.
            let stream = await client.events(topics: [.claudeSessionsUpdated])
            isConnected = true
            let streamStartedAt = now()
            await refresh()
            for await event in stream where event.topic == .claudeSessionsUpdated {
                await refresh()
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Liveness, not traffic, is the health signal — an idle stream can
            // legitimately stay silent for hours.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// Fetches the list once, JOINING any fetch already in flight rather than
    /// issuing a second round trip. Pull-to-refresh, the poke handler, and
    /// the post-mutation refetch all overlap constantly; a dropped caller
    /// would end its spinner having awaited nothing.
    public func refresh() async {
        guard capabilities.supportsClaudeHarness else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        // Unstructured on purpose: the pass belongs to the STORE, so one
        // caller's cancellation cannot abort the fetch others are awaiting.
        let pass = Task { @MainActor in await self.performRefresh() }
        inFlight = pass
        await pass.value
        inFlight = nil
    }

    /// Creates a session and returns the Mac's authoritative snapshot.
    ///
    /// A session that failed to start is still RETURNED, not thrown: its
    /// snapshot carries `state == .failed` and the result carries the
    /// redacted `stderr_excerpt` (the ccx DroidProxy failure path). The
    /// caller shows that honestly instead of a generic error.
    ///
    /// - Parameter body: The creation parameters.
    /// - Returns: The Mac's result, including any startup diagnostic.
    @discardableResult
    public func createSession(
        _ body: SupermuxClaudeSessionCreateRequestDTO
    ) async throws -> SupermuxClaudeSessionResponse {
        try await mutate {
            try await self.client.claudeSessionCreate(SupermuxClaudeSessionCreateRequest(body: body))
        }
    }

    /// Resumes an ended session with its persisted launcher.
    /// - Parameter sessionID: Stable harness session identifier.
    /// - Returns: The Mac's result, including any startup diagnostic.
    @discardableResult
    public func resumeSession(id sessionID: String) async throws -> SupermuxClaudeSessionResponse {
        try await mutate {
            try await self.client.claudeSessionResume(
                SupermuxClaudeSessionResumeRequest(sessionID: sessionID)
            )
        }
    }

    /// Ends a running session, keeping it listed for inspection and resume.
    /// - Parameter sessionID: Stable harness session identifier.
    public func endSession(id sessionID: String) async throws {
        _ = try await mutate {
            try await self.client.claudeSessionEnd(
                SupermuxClaudeSessionEndRequest(sessionID: sessionID)
            )
        }
    }

    /// Deletes a session record entirely.
    /// - Parameter sessionID: Stable harness session identifier.
    public func deleteSession(id sessionID: String) async throws {
        _ = try await mutate {
            try await self.client.claudeSessionDelete(
                SupermuxClaudeSessionDeleteRequest(sessionID: sessionID)
            )
        }
        openedSessionIDs.remove(sessionID)
    }

    /// Fetches the Mac's creation options: model catalog, effort levels,
    /// slash commands, and launcher availability.
    ///
    /// Not cached here on purpose. Launcher availability is a live PATH probe
    /// (`ccx` can be installed or removed between two openings of the sheet)
    /// and the model catalog comes from the CLI, so a stale cache would offer
    /// choices the Mac would then reject.
    ///
    /// - Parameter sessionID: Optional session for model-specific options.
    public func options(sessionID: String? = nil) async throws -> SupermuxClaudeOptionsResponse {
        try await client.claudeOptions(SupermuxClaudeOptionsRequest(sessionID: sessionID))
    }

    /// The conversation store for one session, created on first request and
    /// then reused.
    ///
    /// Caching matters because `navigationDestination`'s builder runs on every
    /// body evaluation of the enclosing stack: constructing a store there
    /// would silently restart the transcript's subscription and re-anchor from
    /// history on unrelated redraws.
    ///
    /// Only the most recent session's store is retained — the flow pushes one
    /// chat at a time, so keeping every store ever visited would accumulate
    /// event subscriptions for screens nobody is looking at.
    ///
    /// - Parameter sessionID: The session to converse with.
    public func conversationStore(for sessionID: String) -> SupermuxClaudeConversationStore {
        if let cachedConversationStore, cachedConversationStore.sessionID == sessionID {
            return cachedConversationStore
        }
        let created = SupermuxClaudeConversationStore(
            client: client,
            capabilities: capabilities,
            sessionID: sessionID
        )
        cachedConversationStore = created
        return created
    }

    /// Marks a session as opened on this device, clearing its
    /// finished-not-opened indicator.
    /// - Parameter sessionID: Stable harness session identifier.
    public func markOpened(id sessionID: String) {
        openedSessionIDs.insert(sessionID)
    }

    /// The list-row indicator for a session, folding the Mac's lifecycle
    /// state together with this device's read marker.
    /// - Parameter session: The session snapshot.
    public func indicator(for session: SupermuxClaudeSessionDTO) -> SupermuxClaudeSessionIndicator {
        SupermuxClaudeSessionIndicator(
            state: session.state,
            hasBeenOpened: openedSessionIDs.contains(session.sessionID)
        )
    }

    // MARK: - Internals

    /// Monotonic request counter: each fetch claims the next value and only
    /// the latest may commit, so a slower earlier-issued list request can
    /// never overwrite a fresher response that already landed.
    @ObservationIgnored private var refreshGeneration = 0

    /// Runs one fetch pass directly, bypassing ``refresh()``'s join.
    ///
    /// Exists so tests can put TWO passes on the wire at once and control the
    /// order they return in; production callers always go through `refresh()`,
    /// which shares a single pass between overlapping callers.
    func performRefreshForTesting() async {
        await performRefresh()
    }

    /// One fetch. Failures keep the last-good list on screen: a dropped
    /// connection must not blank sessions that were true a moment ago.
    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let response = try await client.claudeSessionsList(SupermuxClaudeSessionsListRequest())
            guard generation == refreshGeneration else { return }
            apply(response)
            lastErrorDescription = nil
        } catch {
            guard generation == refreshGeneration else { return }
            let diagnostic = error.localizedDescription
            lastErrorDescription = diagnostic
            Self.logger.error("Claude sessions refresh failed: \(diagnostic, privacy: .private)")
        }
    }

    /// Folds one authoritative snapshot in.
    ///
    /// Deliberately does NOT gate on `state_version`. That number is the Mac's
    /// LIVE-session revision, which legitimately goes DOWN — a session ending
    /// removes its running actor, so the registry's revision drops. Refusing
    /// older versions would therefore freeze the list permanently the first
    /// time a session ended. Ordering between overlapping refetches is handled
    /// by the request generation in ``performRefresh()`` instead, which does
    /// not depend on the server's numbering being monotonic at all.
    ///
    /// The version is still stored, because it is what the UI shows and what
    /// a future coalescing observer would compare against.
    func apply(_ response: SupermuxClaudeSessionsListResponse) {
        stateVersion = response.stateVersion
        sessions = response.sessions.sorted { lhs, rhs in
            let left = lhs.lastActivityAt ?? 0
            let right = rhs.lastActivityAt ?? 0
            if left == right { return lhs.sessionID < rhs.sessionID }
            return left > right
        }
        hasLoaded = true
    }

    /// One mutation at a time: send, then refetch so the list moves without
    /// waiting for the Mac's poke. Errors are recorded AND rethrown so a
    /// sheet can keep its own inline failure state.
    private func mutate<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        isMutating = true
        defer { isMutating = false }
        do {
            let value = try await operation()
            await refresh()
            lastErrorDescription = nil
            return value
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }
}

/// The list-row state indicator for one Claude harness session.
///
/// Deliberately separate from ``SupermuxClaudeSessionState``: `finished`
/// exists only relative to THIS device's read marker, which is not something
/// the Mac tracks.
public enum SupermuxClaudeSessionIndicator: Sendable, Equatable {
    /// Starting up or running a turn.
    case working
    /// Ready for another prompt.
    case idle
    /// Ended after work this device has not opened since.
    case finishedUnopened
    /// Ended and already read on this device.
    case finished
    /// Failed to start, or exited unrecoverably.
    case failed

    /// Derives the indicator from the Mac's state and the local read marker.
    /// - Parameters:
    ///   - state: The Mac's lifecycle state.
    ///   - hasBeenOpened: Whether this device opened the session since it ended.
    public init(state: SupermuxClaudeSessionState, hasBeenOpened: Bool) {
        switch state {
        case .starting, .working:
            self = .working
        case .idle:
            self = .idle
        case .ended:
            self = hasBeenOpened ? .finished : .finishedUnopened
        case .failed:
            self = .failed
        }
    }
}
