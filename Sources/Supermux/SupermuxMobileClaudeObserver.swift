import Foundation
import SupermuxClaudeHarness
import SupermuxKit
import SupermuxMobileCore

/// Observes the authoritative Claude registry and publishes coalesced mobile events.
///
/// Both Claude topics are NON-droppable on the mobile event queue, so every
/// emission path here must be rate-bounded: an unbounded emit rate would let a
/// stalled connection overflow the queue's 256-event cap and tear the whole
/// connection down. Pokes go through a leading-plus-trailing coalescer
/// (``pokeWindow``), transcript frames through a per-session trailing window
/// (``frameWindow``), and `state` frames are suppressed unless the state
/// actually changed — worst case is therefore ~4 pokes/s plus ~8 frames/s per
/// session, comfortably inside the queue's budget.
@MainActor
final class SupermuxMobileClaudeObserver {
    /// The poke coalescing window: at most one leading-edge poke per window,
    /// with one trailing poke when changes arrived inside it.
    static let pokeWindow: Duration = .milliseconds(250)
    /// The per-session transcript frame window. At most two transcript frames
    /// (append + update) per window per session, so ≤8 frames/s/session.
    static let frameWindow: Duration = .milliseconds(250)

    private let registry: ClaudeSessionRegistry
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private var registryTask: Task<Void, Never>?
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingEvents: [UUID: Task<Void, Never>] = [:]
    private var deliveredMessages: [UUID: [String: SupermuxClaudeChatMessageDTO]] = [:]
    private var publishedStates: [UUID: SupermuxClaudeSessionState] = [:]
    private var eventNumbers: [UUID: UInt64] = [:]
    private var watching = false
    private var pokeWindowOpen = false
    private var pokeArrivedDuringWindow = false

    init(
        registry: ClaudeSessionRegistry,
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        }
    ) {
        self.registry = registry
        self.emit = emit
        for id in registry.sessionIDs { attach(id: id) }
        registryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let changes = registry.changes()
            for await change in changes {
                switch change {
                case .added(let id): self.attach(id: id)
                case .removed(let id): self.detach(id: id)
                }
                self.schedulePoke()
            }
        }
        schedulePoke()
    }

    deinit {
        registryTask?.cancel()
        for task in sessionTasks.values { task.cancel() }
        for task in pendingEvents.values { task.cancel() }
    }

    /// Enables or disables transcript publication. Enabling forces a full re-anchor.
    func setWatching(_ enabled: Bool) {
        guard watching != enabled else { return }
        watching = enabled
        guard enabled else { return }
        for id in registry.sessionIDs {
            Task { @MainActor [weak self] in await self?.publish(id: id, forceSnapshot: true) }
        }
    }

    private func attach(id: UUID) {
        guard sessionTasks[id] == nil, let session = registry.session(id: id) else { return }
        sessionTasks[id] = Task { @MainActor [weak self] in
            let changes = await session.changes()
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                self.schedulePoke()
                self.scheduleEvent(id: id)
            }
        }
        if watching {
            Task { @MainActor [weak self] in await self?.publish(id: id, forceSnapshot: true) }
        }
    }

    private func detach(id: UUID) {
        sessionTasks.removeValue(forKey: id)?.cancel()
        pendingEvents.removeValue(forKey: id)?.cancel()
        deliveredMessages.removeValue(forKey: id)
        publishedStates.removeValue(forKey: id)
    }

    /// Emits `sessions_updated` immediately when quiet, then at most one
    /// trailing poke per ``pokeWindow`` while changes keep arriving — the
    /// leading edge keeps list latency low, the trailing edge guarantees the
    /// final state of a burst is never suppressed, and the window bounds the
    /// rate on this non-droppable topic no matter how fast protocol lines
    /// stream.
    private func schedulePoke() {
        if pokeWindowOpen {
            pokeArrivedDuringWindow = true
            return
        }
        pokeWindowOpen = true
        emit(SupermuxMobileTopic.claudeSessionsUpdated.rawValue, [:])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pokeWindow)
            guard let self else { return }
            self.pokeWindowOpen = false
            if self.pokeArrivedDuringWindow {
                self.pokeArrivedDuringWindow = false
                self.schedulePoke()
            }
        }
    }

    private func scheduleEvent(id: UUID) {
        guard watching, pendingEvents[id] == nil else { return }
        pendingEvents[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.frameWindow)
            guard let self, !Task.isCancelled else { return }
            self.pendingEvents[id] = nil
            await self.publish(id: id, forceSnapshot: false)
        }
    }

    private func publish(id: UUID, forceSnapshot: Bool) async {
        guard watching, let session = registry.session(id: id) else { return }
        let projection = SupermuxMobileClaudeProjection(lines: await session.transcriptLines)
        let current = Dictionary(uniqueKeysWithValues: projection.messages.map { ($0.id, $0) })
        let state = Self.mobileState(
            process: await session.processPhase,
            turn: await session.turnPhase
        )
        if forceSnapshot {
            deliveredMessages[id] = current
            emitFrame(sessionID: id, frame: .reset)
            if !projection.messages.isEmpty {
                emitFrame(sessionID: id, frame: .append(projection.messages))
            }
            publishedStates[id] = state
            emitFrame(sessionID: id, frame: .state(state))
            return
        }

        let previous = deliveredMessages[id] ?? [:]
        let appended = projection.messages.filter { previous[$0.id] == nil }
        let updated = projection.messages.filter { previous[$0.id] != nil && previous[$0.id] != $0 }
        deliveredMessages[id] = current
        if !appended.isEmpty { emitFrame(sessionID: id, frame: .append(appended)) }
        if !updated.isEmpty { emitFrame(sessionID: id, frame: .update(updated)) }
        // A state frame only when the state moved: re-sending the same state
        // every window would spend the non-droppable budget on no-ops.
        if publishedStates[id] != state {
            publishedStates[id] = state
            emitFrame(sessionID: id, frame: .state(state))
        }
    }

    private func emitFrame(sessionID: UUID, frame: SupermuxClaudeChatEvent) {
        let next = (eventNumbers[sessionID] ?? 0) &+ 1
        eventNumbers[sessionID] = next
        let value = SupermuxClaudeEventFrame(
            sessionID: sessionID.uuidString.lowercased(), eventNo: next, frame: frame
        )
        guard let payload = Self.object(value) else { return }
        emit(SupermuxMobileTopic.claudeEvent.rawValue, payload)
    }

    static func mobileState(
        process: ClaudeProcessPhase,
        turn: ClaudeTurnPhase
    ) -> SupermuxClaudeSessionState {
        switch process {
        case .dormant, .spawning, .handshaking: return .starting
        case .running:
            switch turn {
            case .idle: return .idle
            case .dispatching, .active, .interrupting, .uncertain: return .working
            }
        case .stopping, .exited: return .ended
        case .failed: return .failed
        }
    }

    static func object<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

/// Holder/refcount lease registry for the Claude mobile event firehose.
@MainActor
final class SupermuxMobileClaudeWatchRegistry {
    static let ttl: TimeInterval = 120
    static let sweepInterval: Duration = .seconds(30)

    private let observer: SupermuxMobileClaudeObserver
    private let now: @MainActor () -> Date
    private var leases = SupermuxClaudeWatchLeaseSet()
    private var sweepTask: Task<Void, Never>?

    init(observer: SupermuxMobileClaudeObserver, now: @escaping @MainActor () -> Date = { Date() }) {
        self.observer = observer
        self.now = now
    }

    deinit { sweepTask?.cancel() }

    func watch(clientID: String) -> Date {
        let wasEmpty = !leases.isActive
        let expiration = leases.renew(clientID: clientID, now: now(), ttl: Self.ttl)
        if wasEmpty { observer.setWatching(true) }
        startSweepingIfNeeded()
        return expiration
    }

    func unwatch(clientID: String) {
        leases.release(clientID: clientID)
        stopIfIdle()
    }

    func sweep() {
        leases.sweep(now: now())
        stopIfIdle()
    }

    var isWatching: Bool { leases.isActive }

    private func startSweepingIfNeeded() {
        guard sweepTask == nil, leases.isActive else { return }
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                guard let self, !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    private func stopIfIdle() {
        guard !leases.isActive else { return }
        observer.setWatching(false)
        sweepTask?.cancel()
        sweepTask = nil
    }
}
