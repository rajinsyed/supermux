import Foundation

/// Coordinates periodic and typing-debounced session autosave work.
///
/// The application supplies snapshot fingerprinting and persistence closures so
/// snapshot construction remains owned by ``AppDelegate`` while timer, retry,
/// generation, and skip-state transitions live in one focused object.
@MainActor
final class SessionAutosaveCoordinator {
    typealias Fingerprint = @MainActor (
        RestorableAgentSessionIndex,
        SurfaceResumeBindingIndex
    ) -> Int?
    typealias Save = @MainActor (
        RestorableAgentSessionIndex,
        SurfaceResumeBindingIndex
    ) -> Bool
    typealias TTYDeviceBindings = @MainActor () -> [
        SurfaceResumeBindingIndex.PanelKey: Int64
    ]
    typealias SaveCurrentSnapshot = @MainActor () -> Bool

    private let isTerminatingApp: @MainActor () -> Bool
    private let isStartupSessionRestorePending: @MainActor () -> Bool
    private let currentTTYDeviceBindings: TTYDeviceBindings
    private let fingerprint: Fingerprint
    private let save: Save
    private let saveCurrentSnapshot: SaveCurrentSnapshot
    private let onTimerTick: @MainActor () -> Void

    private static let typingQuietPeriod: TimeInterval = 0.65
    // SUPERMUX:begin autosave-resume-indexes-reuse (a tick reuses recent process-detected indexes)
    /// How long an autosave tick reuses the last complete process-detected
    /// resume indexes for the same terminals. Loading them takes a census of
    /// every process on the Mac with its arguments and environment plus a
    /// scan of the agent hook stores and transcripts, which on a Mac running
    /// many agents cost more than everything else an idle cmux does; one
    /// every 8 s tick is not needed for crash-restore state. A terminal added
    /// or removed (a different TTY binding set) reloads at once.
    private static let resumeIndexesReuseInterval: TimeInterval = 30
    // SUPERMUX:end autosave-resume-indexes-reuse

    private var timer: DispatchSourceTimer?
    private struct ActiveAttempt {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var deferredRetryTask: Task<Void, Never>?
    private var activeAttempt: ActiveAttempt?
    private var processDetectedSaveGeneration: UInt64 = 0
    // SUPERMUX:begin autosave-resume-indexes-reuse
    private var reusableResumeIndexes: (
        indexes: ProcessDetectedResumeIndexes,
        ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64],
        loadedAt: TimeInterval
    )?
    // SUPERMUX:end autosave-resume-indexes-reuse
    private var lastFingerprint: Int?
    private var lastPersistedAt = Date.distantPast
    private(set) var lastTypingActivityAt: TimeInterval = 0
    private var todoStatePersistenceCoordinator: SessionTodoStatePersistenceCoordinator?

    init(
        isTerminatingApp: @escaping @MainActor () -> Bool,
        isStartupSessionRestorePending: @escaping @MainActor () -> Bool,
        currentTTYDeviceBindings: @escaping TTYDeviceBindings,
        fingerprint: @escaping Fingerprint,
        save: @escaping Save,
        saveCurrentSnapshot: @escaping SaveCurrentSnapshot,
        onTimerTick: @escaping @MainActor () -> Void = {}
    ) {
        self.isTerminatingApp = isTerminatingApp
        self.isStartupSessionRestorePending = isStartupSessionRestorePending
        self.currentTTYDeviceBindings = currentTTYDeviceBindings
        self.fingerprint = fingerprint
        self.save = save
        self.saveCurrentSnapshot = saveCurrentSnapshot
        self.onTimerTick = onTimerTick
    }

    deinit {
        Self.cancelScheduledWork(
            timer: timer,
            deferredRetryTask: deferredRetryTask,
            activeTask: activeAttempt?.task
        )
    }

    nonisolated static func shouldRunSessionAutosaveTick(
        isTerminatingApp: Bool,
        isStartupSessionRestorePending: Bool
    ) -> Bool {
        !isTerminatingApp && !isStartupSessionRestorePending
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    func startIfNeeded() {
        guard timer == nil else { return }
        guard !MacSentryStartupPolicy.isRunningUnderXCTest(environment: ProcessInfo.processInfo.environment) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(
                      isTerminatingApp: self.isTerminatingApp(),
                      isStartupSessionRestorePending: self.isStartupSessionRestorePending()
                  ) else {
                return
            }
            self.run(source: "timer")
            self.onTimerTick()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        let hadActiveAttempt = activeAttempt != nil
        todoStatePersistenceCoordinator?.invalidate()
        Self.cancelScheduledWork(
            timer: timer,
            deferredRetryTask: deferredRetryTask,
            activeTask: activeAttempt?.task
        )
        timer = nil
        deferredRetryTask = nil
        activeAttempt = nil
        if hadActiveAttempt {
            processDetectedSaveGeneration &+= 1
        }
    }

    nonisolated private static func cancelScheduledWork(
        timer: DispatchSourceTimer?,
        deferredRetryTask: Task<Void, Never>?,
        activeTask: Task<Void, Never>?
    ) {
        timer?.cancel()
        deferredRetryTask?.cancel()
        activeTask?.cancel()
    }

    func run(source: String) {
        guard Self.shouldRunSessionAutosaveTick(
            isTerminatingApp: isTerminatingApp(),
            isStartupSessionRestorePending: isStartupSessionRestorePending()
        ) else {
            return
        }
        guard activeAttempt == nil else { return }
        if let remainingQuietPeriod = remainingTypingQuietPeriod() {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                    "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
            )
#endif
            scheduleDeferredRetry(after: remainingQuietPeriod)
            return
        }

        let generation = nextProcessDetectedSaveGeneration()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finish(source: source, generation: generation)
        }
        activeAttempt = ActiveAttempt(generation: generation, task: task)
    }

    /// Schedule a session snapshot after todo edits settle. The save captures
    /// current in-memory state with cached process indexes, keeping todo edits
    /// consistent with simultaneous pane and workspace changes.
    func scheduleTodoStateSave(isApplyingSessionRestore: Bool) {
        guard !isTerminatingApp(),
              !isStartupSessionRestorePending(),
              !isApplyingSessionRestore else { return }
        if todoStatePersistenceCoordinator == nil {
            todoStatePersistenceCoordinator = SessionTodoStatePersistenceCoordinator(
                saveSnapshot: { [weak self] in
                    guard let self, !self.isTerminatingApp() else { return false }
                    return self.saveCurrentSnapshot()
                }
            )
        }
        todoStatePersistenceCoordinator?.enqueue()
    }

    func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    func nextProcessDetectedSaveGeneration() -> UInt64 {
        processDetectedSaveGeneration &+= 1
        return processDetectedSaveGeneration
    }

    func isCurrentProcessDetectedSaveGeneration(_ generation: UInt64) -> Bool {
        generation == processDetectedSaveGeneration
    }

    func updateSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp(), !includeScrollback else { return }
        lastFingerprint = fingerprint
        lastPersistedAt = persistedAt
    }

    private func finish(source: String, generation: UInt64) async {
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var loadMs: Double = 0
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            if activeAttempt?.generation == generation {
                activeAttempt = nil
            }
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "session.autosaveTick.phase",
                totalMs: totalMs,
                thresholdMs: 2.0,
                parts: [
                    ("loadMs", loadMs),
                    ("fingerprintMs", fingerprintMs),
                    ("saveMs", saveMs),
                ],
                extra: "source=\(source)"
            )
            CmuxTypingTiming.logDuration(
                path: "session.autosaveTick",
                startedAt: timingStart,
                extra: "source=\(source)"
            )
        }
#else
        defer {
            if activeAttempt?.generation == generation {
                activeAttempt = nil
            }
        }
#endif

        let now = Date()
#if DEBUG
        let loadStart = ProcessInfo.processInfo.systemUptime
#endif
        let ttyDeviceBindings = currentTTYDeviceBindings()
        // SUPERMUX:begin autosave-resume-indexes-reuse (upstream: `let resumeIndexes = await ProcessDetectedResumeIndexes.load(ttyDeviceBindings: ttyDeviceBindings)`)
        let resumeIndexes = await currentResumeIndexes(for: ttyDeviceBindings)
        // SUPERMUX:end autosave-resume-indexes-reuse
#if DEBUG
        loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
#endif
        guard !Task.isCancelled,
              !isTerminatingApp(),
              activeAttempt?.generation == generation,
              isCurrentProcessDetectedSaveGeneration(generation) else {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=stale_process_detected_scan includeScrollback=0 source=\(source)"
            )
#endif
            return
        }
        let autosaveFingerprint = fingerprint(
            resumeIndexes.restorableAgentIndex,
            resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
#endif
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminatingApp(),
            includeScrollback: false,
            previousFingerprint: lastFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastPersistedAt,
            now: now
        ) {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }

#if DEBUG
        let saveStart = ProcessInfo.processInfo.systemUptime
#endif
        let didSave = save(
            resumeIndexes.restorableAgentIndex,
            resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
#endif
        guard didSave else { return }
        updateSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    // SUPERMUX:begin autosave-resume-indexes-reuse
    /// The process-detected resume indexes for this tick: the last complete
    /// ones while they are recent and the terminals are the same, else fresh.
    private func currentResumeIndexes(
        for ttyDeviceBindings: [SurfaceResumeBindingIndex.PanelKey: Int64]
    ) async -> ProcessDetectedResumeIndexes {
        let now = ProcessInfo.processInfo.systemUptime
        if let reusable = reusableResumeIndexes,
           reusable.ttyDeviceBindings == ttyDeviceBindings,
           now - reusable.loadedAt < Self.resumeIndexesReuseInterval {
            return reusable.indexes
        }
        let indexes = await ProcessDetectedResumeIndexes.load(ttyDeviceBindings: ttyDeviceBindings)
        if indexes.restorableAgentIndex.isComplete, indexes.surfaceResumeBindingIndex.isAvailable {
            reusableResumeIndexes = (indexes, ttyDeviceBindings, now)
        } else {
            reusableResumeIndexes = nil
        }
        return indexes
    }
    // SUPERMUX:end autosave-resume-indexes-reuse

    private func remainingTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.typingQuietPeriod else { return nil }
        return Self.typingQuietPeriod - elapsed
    }

    private func scheduleDeferredRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard deferredRetryTask == nil else { return }
        deferredRetryTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.deferredRetryTask = nil
            self.run(source: "typingQuietRetry")
        }
    }
}
