public import Foundation
import Observation
import OSLog
public import SupermuxMobileCore

/// Main-actor state for ONE Claude harness conversation on the phone: the
/// transcript, the live event stream with gap recovery, the watch-lease
/// heartbeat, and the send/interrupt/set-option actions.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected.
///
/// **Why this is not `ChatConversationStore`.** The upstream store is written
/// against `ChatEventSource`/`ChatSessionEvent`, and the wire contract for
/// this feature deliberately does NOT reuse `ChatSessionEvent`: the Claude
/// frames are a fork-owned compact type in `SupermuxMobileCore`, which has no
/// `CmuxAgentChat` dependency. Adapting one to the other would mean either
/// adding that dependency to the wire package or writing a lossy translation
/// layer, both of which cost more than the ~200 lines of run loop below —
/// and the translation would have to be maintained on both sides of every
/// future protocol change.
///
/// **Pull-authoritative.** `claude.history` is the source of truth and the
/// event plane is an optimization. Every frame carries a per-session
/// monotonic `event_no`; anything but the exact next number re-anchors from
/// history (``supermuxClaudeFrameDisposition(eventNo:lastAppliedEventNo:)``).
/// Merging is idempotent, so re-applying a frame that overlaps the freshly
/// loaded page is harmless.
///
/// Lifecycle: the chat screen runs ``run()`` inside a `.task`, so the
/// subscription AND the watch heartbeat are structured — cancelled when the
/// screen disappears, at which point one final `claude.watch {enable:false}`
/// goes out (the Mac's 120 s lease TTL is the backstop if that frame is lost).
@MainActor
@Observable
public final class SupermuxClaudeConversationStore {
    /// How often the phone renews the Mac's event-watch lease. Half the
    /// Mac's 120 s TTL, so one lost heartbeat never drops the lease.
    public static let heartbeatInterval: Duration = .seconds(60)

    /// How many messages one history page requests.
    public static let historyPageSize = 100

    /// The ordered transcript.
    public private(set) var transcript = SupermuxClaudeTranscript()

    /// The session snapshot, refreshed on lifecycle events.
    public private(set) var session: SupermuxClaudeSessionDTO?

    /// Whether the first history page has landed.
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up.
    public private(set) var isConnected = false

    /// Whether an older-history page fetch is on the wire.
    public private(set) var isLoadingOlder = false

    /// Whether a send/interrupt/set-option round trip is on the wire.
    public private(set) var isMutating = false

    /// How many history re-anchors have happened. Test-visible and useful as
    /// a diagnostic: a session that re-anchors constantly is one whose event
    /// plane is overflowing, which is a Mac-side coalescing problem.
    public private(set) var reanchorCount = 0

    /// Diagnostic description of the most recent failure. The UI shows
    /// localized recovery copy from its presence and must never render this
    /// raw transport text. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    /// The session this store follows.
    public let sessionID: String

    private static let logger = Logger(subsystem: "dev.supermux.ios", category: "claude-chat")

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    @ObservationIgnored private let heartbeatSleep: (Duration) async -> Void

    /// This store's stable watch-session id, sent as `client_id` on every
    /// `claude.watch` (enable AND disable) so the Mac refcounts watchers per
    /// client — one device closing its chat must not stop another's stream.
    @ObservationIgnored private let watchClientID = UUID().uuidString

    /// The last applied frame number, or `nil` when nothing is anchored yet.
    @ObservationIgnored private var lastAppliedEventNo: UInt64?

    /// Serializes every `claude.watch` send into one FIFO chain, so a torn
    /// down screen's trailing `enable:false` can never overtake a freshly
    /// mounted screen's `enable:true` (push → pop → push).
    @ObservationIgnored private var watchSendChain: Task<Void, Never>?

    /// Whether the phone shows the harness at all.
    public var showsClaudeHarness: Bool { capabilities.supportsClaudeHarness }

    /// Whether the session is currently running a turn (drives the composer's
    /// stop button and the working indicator).
    public var isWorking: Bool {
        switch session?.state {
        case .starting, .working: true
        case .idle, .ended, .failed, nil: false
        }
    }

    /// Creates a conversation store for one session.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - sessionID: The harness session to follow.
    ///   - now: Clock seam for the reconnect-health check.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    ///   - heartbeatSleep: Heartbeat interval seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        sessionID: String,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        heartbeatSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.sessionID = sessionID
        self.now = now
        self.idleSleep = idleSleep
        self.heartbeatSleep = heartbeatSleep
    }

    /// Follows the live transcript stream AND renews the watch lease until
    /// cancelled, then releases the lease. A no-op without
    /// `supermux.claude.v1`.
    public func run() async {
        guard capabilities.supportsClaudeHarness else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followEvents() }
            group.addTask { await self.heartbeat() }
        }
        // Reached on cancellation: release the Mac-side watch promptly rather
        // than riding out the TTL, routed through the FIFO chain so a fresh
        // screen's enable cannot be overtaken by this disable.
        sendWatch(enable: false)
    }

    /// Loads one page of older messages, if any remain.
    public func loadOlderHistory() async {
        guard capabilities.supportsClaudeHarness,
              transcript.hasMoreHistory,
              !isLoadingOlder,
              let cursor = transcript.oldestSeq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await client.claudeHistory(SupermuxClaudeHistoryRequest(
                body: SupermuxClaudeHistoryRequestDTO(
                    sessionID: sessionID,
                    beforeSeq: cursor,
                    limit: Self.historyPageSize
                )
            ))
            transcript.prepend(page.messages, hasMore: page.hasMore)
            lastErrorDescription = nil
        } catch {
            record(error, context: "history page")
        }
    }

    /// Submits a prompt. While a turn is running the MAC queues it — the
    /// phone never keeps its own queue, so there is exactly one queue and one
    /// mutation path regardless of which device sent the prompt.
    ///
    /// - Parameters:
    ///   - text: The prompt or slash command.
    ///   - attachments: Optional image attachments.
    /// - Returns: Whether the Mac queued it, and where.
    @discardableResult
    public func send(
        text: String,
        attachments: [SupermuxClaudeAttachmentDTO]? = nil
    ) async throws -> SupermuxClaudeSendResponse {
        try await mutate {
            try await self.client.claudeSend(SupermuxClaudeSendRequest(
                body: SupermuxClaudeSendRequestDTO(
                    sessionID: self.sessionID,
                    text: text,
                    attachments: attachments
                )
            ))
        }
    }

    /// Interrupts the running turn (a protocol control, never a signal).
    public func interrupt() async throws {
        _ = try await mutate {
            try await self.client.claudeInterrupt(
                SupermuxClaudeInterruptRequest(sessionID: self.sessionID)
            )
        }
    }

    /// Sets one session option and adopts the value the MAC reports back.
    ///
    /// The reconciled value is what gets stored: Claude Code may resolve a
    /// requested model or effort to something else, and a phone that kept its
    /// requested value would then be quietly lying about what is running.
    ///
    /// - Parameters:
    ///   - option: The option to mutate.
    ///   - value: The requested value.
    /// - Returns: The reconciled value.
    @discardableResult
    public func setOption(
        _ option: SupermuxClaudeOption,
        to value: SupermuxClaudeOptionValue
    ) async throws -> SupermuxClaudeOptionValue {
        let result = try await mutate {
            try await self.client.claudeSetOption(SupermuxClaudeSetOptionRequest(
                body: SupermuxClaudeSetOptionRequestDTO(
                    sessionID: self.sessionID,
                    option: option,
                    value: value
                )
            ))
        }
        await refreshSession()
        return result.appliedValue
    }

    /// Fetches one message's untruncated tool body, following the chunk
    /// cursor to completion.
    ///
    /// Push frames deliberately carry only bounded summaries, so this is the
    /// only path to a full diff or command output. Each chunk is capped at
    /// 3 MiB Mac-side, well under the transport's frame limit.
    ///
    /// - Parameter messageID: The transcript message to read.
    /// - Returns: The complete payload bytes.
    public func toolPayload(messageID: String) async throws -> Data {
        var assembled = Data()
        var offset: Int64 = 0
        while true {
            let chunk = try await client.claudeToolPayload(SupermuxClaudeToolPayloadRequest(
                body: SupermuxClaudeToolPayloadRequestDTO(
                    sessionID: sessionID,
                    messageID: messageID,
                    offset: offset
                )
            ))
            assembled.append(chunk.data)
            if chunk.eof { break }
            // A non-EOF empty chunk would spin forever; the Mac should never
            // send one, and treating it as the end is the safe reading.
            guard !chunk.data.isEmpty else { break }
            offset += Int64(chunk.data.count)
        }
        return assembled
    }

    // MARK: - Internals

    private func followEvents() async {
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST, then anchor: frames emitted while the history
            // fetch is in flight buffer in the stream and are applied (or
            // discarded as duplicates) after it, instead of being lost.
            let stream = await client.events(topics: [.claudeEvent, .claudeSessionsUpdated])
            isConnected = true
            let streamStartedAt = now()
            await reanchor()
            for await event in stream {
                switch event.topic {
                case .claudeEvent:
                    // The topic is Mac-wide, so frames for other sessions
                    // arrive here too. An UNDECODABLE frame has no session id
                    // to compare, and is deliberately NOT filtered out: it is
                    // handled as a gap, which is the safe reading when we
                    // cannot tell whether it was ours.
                    if let frame = event.claudeFrame, frame.sessionID != sessionID { continue }
                    await handle(frame: event.claudeFrame)
                case .claudeSessionsUpdated:
                    await refreshSession()
                default:
                    continue
                }
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // A reconnect may have missed frames, so the next pass re-anchors
            // from scratch rather than trusting the old number.
            lastAppliedEventNo = nil
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// Applies one inbound frame, or repairs the transcript when it cannot.
    ///
    /// A `nil` frame is an undecodable payload, which is indistinguishable
    /// from a missing one and is therefore handled as a gap.
    func handle(frame: SupermuxClaudeEventFrame?) async {
        switch supermuxClaudeFrameDisposition(
            eventNo: frame?.eventNo,
            lastAppliedEventNo: lastAppliedEventNo
        ) {
        case .duplicate:
            return
        case .reanchor:
            reanchorCount += 1
            // Adopt the triggering frame's number ONLY when the authoritative
            // reload landed. A failed history fetch left the hole unfilled;
            // advancing the anchor anyway would make every later consecutive
            // frame look gapless and the missing events unrecoverable. Leaving
            // the anchor nil keeps every subsequent frame classified as a gap
            // until a reload finally succeeds.
            guard await reanchor(), let frame else { return }
            // The merge is idempotent, so overlapping the page just reloaded
            // is harmless, while skipping the frame would drop content the
            // page predates.
            lastAppliedEventNo = frame.eventNo
            apply(frame.frame)
        case .apply:
            guard let frame else { return }
            lastAppliedEventNo = frame.eventNo
            apply(frame.frame)
        }
    }

    /// Applies one decoded event to local state. `reset` clears and reloads,
    /// since the Mac is telling us our transcript is no longer valid.
    private func apply(_ event: SupermuxClaudeChatEvent) {
        switch event {
        case .append(let messages), .update(let messages):
            transcript.merge(messages)
        case .state(let state):
            // Fold the state into the cached snapshot so the composer reacts
            // immediately; the authoritative snapshot follows on the poke.
            if var session {
                session.state = state
                self.session = session
            }
        case .reset:
            transcript.clear()
            lastAppliedEventNo = nil
            Task { await self.reanchor() }
        case .unknown(let kind):
            // Forward compatibility: a newer Mac may emit event kinds this
            // build cannot place. Ignoring is correct — the transcript stays
            // consistent, just less detailed — but it is worth a breadcrumb.
            Self.logger.debug("Ignoring unknown Claude event kind \(kind, privacy: .public)")
        }
    }

    /// Reloads the newest history page and the session snapshot: the
    /// authoritative recovery from any gap, reset, or reconnect.
    ///
    /// Note the anchor stays `nil` here. History carries no event number, so
    /// the FIRST frame after a reload always re-anchors once more. That costs
    /// one extra page fetch per session that speaks, and buys the guarantee
    /// that a frame dropped between the snapshot and that first delivery
    /// cannot silently leave a hole in the transcript.
    ///
    /// - Returns: Whether the authoritative history page actually landed.
    ///   Callers must not advance the event anchor on `false` — the gap they
    ///   were repairing is still open.
    @discardableResult
    private func reanchor() async -> Bool {
        await refreshSession()
        do {
            let page = try await client.claudeHistory(SupermuxClaudeHistoryRequest(
                body: SupermuxClaudeHistoryRequestDTO(
                    sessionID: sessionID,
                    beforeSeq: nil,
                    limit: Self.historyPageSize
                )
            ))
            transcript.replace(with: page.messages, hasMore: page.hasMore)
            hasLoaded = true
            lastErrorDescription = nil
            return true
        } catch {
            record(error, context: "history anchor")
            return false
        }
    }

    /// Monotonic request counter for ``refreshSession()``: only the latest
    /// request may commit, so a slower earlier snapshot cannot overwrite a
    /// fresher one that already landed.
    ///
    /// The DTO's own `version` is deliberately not used for this. It is the
    /// Mac's live-session revision, which resets when a session ends, so a
    /// version comparison would pin the phone to a stale snapshot exactly when
    /// the session's state last changed.
    @ObservationIgnored private var sessionRequestGeneration = 0

    /// Refetches the session snapshot.
    private func refreshSession() async {
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        do {
            let result = try await client.claudeSessionGet(
                SupermuxClaudeSessionGetRequest(sessionID: sessionID)
            )
            guard generation == sessionRequestGeneration else { return }
            session = result.session
        } catch {
            guard generation == sessionRequestGeneration else { return }
            record(error, context: "session snapshot")
        }
    }

    /// Beat now, then every ``heartbeatInterval``. A failed beat is
    /// non-fatal: the next one retries and the Mac's TTL is the backstop.
    private func heartbeat() async {
        while !Task.isCancelled {
            sendWatch(enable: true)
            await heartbeatSleep(Self.heartbeatInterval)
        }
    }

    private func sendWatch(enable: Bool) {
        let client = self.client
        let clientID = self.watchClientID
        let previous = watchSendChain
        watchSendChain = Task {
            await previous?.value
            _ = try? await client.claudeWatch(
                SupermuxClaudeWatchRequest(enable: enable, clientID: clientID)
            )
        }
    }

    private func mutate<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        isMutating = true
        defer { isMutating = false }
        do {
            let value = try await operation()
            lastErrorDescription = nil
            return value
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    private func record(_ error: any Error, context: String) {
        let diagnostic = error.localizedDescription
        lastErrorDescription = diagnostic
        Self.logger.error("Claude \(context, privacy: .public) failed: \(diagnostic, privacy: .private)")
    }
}
