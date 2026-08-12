public import Foundation
public import SupermuxClaudeHarness

/// The view-facing state of one Claude harness panel.
///
/// Owned by the fork's panel registry, **never** by a `@State`/`@StateObject`
/// in the mount: `AgentSessionPanelView` renders `Color.clear` when the panel
/// is not visible, so a view-owned model would tear the running `claude`
/// process down every time the user switched tabs.
///
/// Streaming discipline: session changes are applied to the (observation-
/// ignored) row builder immediately, but published to SwiftUI at most once per
/// ``coalescingInterval``. A fast local pipe emits far more deltas than a
/// display can show, and re-rendering per delta is what makes a native
/// transcript feel slower than a terminal.
@MainActor
@Observable
public final class SupermuxHarnessViewModel {
    /// Whether the panel is showing the new-session form or a live session.
    public enum Phase: Sendable, Equatable {
        /// No session yet: the setup form is showing.
        case setup
        /// A session exists (starting, running, or ended).
        case session
    }

    /// One UI update per frame at 60Hz.
    public static let coalescingInterval = Duration.milliseconds(16)

    // MARK: - Published state

    public private(set) var phase: Phase = .setup
    public private(set) var rows: [SupermuxHarnessRow] = []
    public private(set) var processPhase: ClaudeProcessPhase = .dormant
    public private(set) var turnPhase: ClaudeTurnPhase = .idle
    public private(set) var queue: [ClaudeQueuedInput] = []
    public private(set) var initialization: ClaudeSystemInitialization?
    public private(set) var latestResult: ClaudeResult?
    public private(set) var availableModels: [ClaudeModelDescriptor] = []
    public private(set) var isLoadingModels = false
    /// A user-visible failure that is not part of the transcript (spawn errors,
    /// control rejections). Cleared by the next successful action.
    public private(set) var startupError: String?

    /// The working directory the session runs in.
    public private(set) var workingDirectory: String
    /// The launcher this session uses (or will use).
    public private(set) var launcher: ClaudeLauncher?
    public private(set) var selectedModel: String?
    public private(set) var effortLevel: String?
    public private(set) var fastMode = false
    public private(set) var maxThinkingTokens: Int?
    /// The first prompt, used to derive the tab title exactly once.
    public private(set) var derivedTitle: String?

    /// The composer's live text (bound by the composer view).
    public var draft: String = ""

    // MARK: - Collaborators

    @ObservationIgnored private let registry: ClaudeSessionRegistry
    @ObservationIgnored private let store: SupermuxHarnessSessionStore
    @ObservationIgnored private let resolver: ClaudeLauncherResolver
    @ObservationIgnored public let panelID: UUID
    @ObservationIgnored private(set) public var stableSurfaceID: UUID?
    @ObservationIgnored private var session: ClaudeSession?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var builder = SupermuxHarnessRowBuilder()
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var needsFlush = false
    /// Called once when the first prompt yields a tab title.
    @ObservationIgnored public var onDerivedTitle: ((String) -> Void)?

    public init(
        panelID: UUID,
        workingDirectory: String,
        registry: ClaudeSessionRegistry,
        store: SupermuxHarnessSessionStore,
        resolver: ClaudeLauncherResolver = ClaudeLauncherResolver()
    ) {
        self.panelID = panelID
        self.workingDirectory = workingDirectory
        self.registry = registry
        self.store = store
        self.resolver = resolver
    }

    deinit {
        observationTask?.cancel()
        flushTask?.cancel()
    }

    // MARK: - Derived state

    /// Whether a turn is in flight (composer shows Stop instead of Send).
    public var isBusy: Bool {
        switch turnPhase {
        case .dispatching, .active, .interrupting: return true
        case .idle, .uncertain: return false
        }
    }

    /// Whether the process is alive and initialized.
    public var isRunning: Bool {
        if case .running = processPhase { return true }
        return false
    }

    /// Slash commands advertised by `system.init`, for composer autocomplete.
    public var slashCommands: [String] { initialization?.slashCommands ?? [] }

    /// The model descriptor matching the active model, when known.
    public var activeModelDescriptor: ClaudeModelDescriptor? {
        guard let selectedModel else { return nil }
        return availableModels.first { $0.value == selectedModel }
    }

    /// The effort levels the active model supports (empty when unsupported).
    public var supportedEffortLevels: [String] {
        activeModelDescriptor?.supportedEffortLevels ?? []
    }

    public var supportsFastMode: Bool {
        activeModelDescriptor?.supportsFastMode ?? false
    }

    // MARK: - Adoption

    /// Binds the panel's persisted identity. Called from `.task`, never at
    /// construction: upstream adopts the restored stable surface id *after*
    /// `newAgentSessionSurface` returns.
    public func adopt(stableSurfaceID: UUID) async {
        guard self.stableSurfaceID != stableSurfaceID else { return }
        self.stableSurfaceID = stableSurfaceID
        guard session == nil, let record = await store.load(stableSurfaceID: stableSurfaceID) else {
            return
        }
        workingDirectory = record.workingDirectory
        launcher = record.launcher
        selectedModel = record.model
        effortLevel = record.effortLevel
        fastMode = record.fastMode
        maxThinkingTokens = record.maxThinkingTokens
        derivedTitle = record.derivedTitle
        resumableSessionID = record.claudeSessionID
        restorableQueueEntries = record.queueEntries
    }

    /// The provider session id a restored panel can resume, when one exists.
    public private(set) var resumableSessionID: String?

    /// Queue entries persisted before the app last quit, awaiting restoration
    /// into the next session this panel starts.
    @ObservationIgnored private var restorableQueueEntries: [ClaudeQueuedInput] = []

    // MARK: - Configuration (setup form)

    public func setWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    public func setLauncher(_ launcher: ClaudeLauncher) {
        self.launcher = launcher
        startupError = nil
    }

    /// Resolves a launcher kind (with an optional explicit path) and selects it.
    public func selectLauncher(kind: ClaudeLauncher.Kind, path: String? = nil) {
        do {
            launcher = try resolver.resolve(kind: kind, explicitPath: path)
            startupError = nil
        } catch {
            launcher = nil
            startupError = Self.describe(launcherError: error)
        }
    }

    /// Whether a launcher of this kind is available, for the setup picker.
    public func isLauncherAvailable(kind: ClaudeLauncher.Kind) -> Bool {
        (try? resolver.resolve(kind: kind)) != nil
    }

    public func setModelSelection(_ model: String?) {
        selectedModel = model
    }

    // MARK: - Lifecycle

    /// Starts a fresh session, or resumes the persisted one when `resume` is
    /// set and a provider session id was persisted.
    public func start(resume: Bool = false) async {
        guard session == nil else { return }
        guard let launcher else {
            startupError = String(
                localized: "supermux.harness.error.launcherNotSelected",
                defaultValue: "Choose how to launch Claude Code first."
            )
            return
        }
        let identity: ClaudeSpawnArguments.SessionIdentity
        if resume, let resumableSessionID {
            identity = .resume(sessionID: resumableSessionID)
        } else {
            identity = .new(sessionID: UUID().uuidString.lowercased())
        }
        // The registry key MUST be the persisted record key (the stable
        // surface ID): the mobile host looks live sessions up by
        // `record.stableSurfaceID`, so a random key would make the phone
        // report an active desktop session as ended — and let a phone-side
        // resume spawn a second child for the same provider session. The
        // panel ID is the fallback for panels whose stable ID has not been
        // adopted yet (no record exists, so no cross-device lookup either).
        let configuration = ClaudeSessionConfiguration(
            id: stableSurfaceID ?? panelID,
            launcher: launcher,
            workingDirectory: workingDirectory,
            identity: identity,
            model: selectedModel,
            effort: effortLevel
        )
        let persistence = stableSurfaceID.map {
            SupermuxHarnessSessionPersistence(store: store, stableSurfaceID: $0)
        }
        do {
            // A live session under this key can already exist (the phone
            // resumed this panel's session while the desktop was showing the
            // setup form). Attach to a running one; replace a dead one.
            if let existing = registry.session(id: configuration.id) {
                switch await existing.processPhase {
                case .dormant, .spawning, .handshaking, .running, .stopping:
                    self.session = existing
                    self.sessionID = configuration.id
                    phase = .session
                    startupError = nil
                    restorableQueueEntries = []
                    observe(existing)
                    await loadModels()
                    return
                case .exited, .failed:
                    await registry.remove(id: configuration.id)
                }
            }
            let session = try await registry.create(
                configuration: configuration, persistence: persistence
            )
            self.session = session
            self.sessionID = configuration.id
            phase = .session
            startupError = nil
            // Restore unsent/uncertain prompts persisted before the app last
            // quit, so they are not silently overwritten by the fresh session's
            // first (empty-queue) persistence snapshot.
            let restorable = restorableQueueEntries
            restorableQueueEntries = []
            if !restorable.isEmpty {
                await session.restoreQueue(entries: restorable)
            }
            await persistRecord()
            observe(session)
            await loadModels()
            await applyRestoredControls(to: session)
        } catch {
            startupError = Self.describe(launcherError: error)
        }
    }

    /// Re-applies persisted runtime settings the spawn arguments cannot carry
    /// (fast mode, thinking budget). Without this a resumed CLI would run with
    /// defaults while the controls display the persisted values.
    private func applyRestoredControls(to session: ClaudeSession) async {
        if fastMode {
            do {
                _ = try await session.sendControl(.setFastMode(true))
            } catch {
                fastMode = false
            }
        }
        if let tokens = maxThinkingTokens {
            do {
                _ = try await session.sendControl(.setMaxThinkingTokens(tokens))
            } catch {
                maxThinkingTokens = nil
            }
        }
    }

    /// Terminates the session and forgets it (panel close).
    public func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        flushTask?.cancel()
        flushTask = nil
        guard let sessionID else { return }
        await registry.remove(id: sessionID)
        session = nil
        self.sessionID = nil
    }

    // MARK: - Actions

    /// Sends (or queues) the draft text.
    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session else { return }
        draft = ""
        await session.enqueue(text: text)
        deriveTitleIfNeeded(from: text)
    }

    public func cancelQueued(id: UUID) async {
        await session?.removeQueuedInput(id: id)
    }

    public func resumeQueue() async {
        await session?.resumeQueue()
    }

    /// Interrupts the active turn (a control message, never a signal).
    public func interrupt() async {
        guard let session else { return }
        do {
            try await session.interrupt()
        } catch {
            startupError = "\(error)"
        }
    }

    /// Loads the model list from the CLI.
    public func loadModels() async {
        guard let session, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await session.sendControl(.listModels)
            availableModels = ClaudeModelDescriptor.models(from: response.payload)
            if selectedModel == nil {
                selectedModel = initialization?.model
            }
        } catch {
            // A model list failure is not fatal: the session keeps running with
            // whatever model the CLI already chose.
            availableModels = []
        }
    }

    public func setModel(_ model: String) async {
        guard let session else {
            selectedModel = model
            return
        }
        do {
            _ = try await session.sendControl(.setModel(model))
            selectedModel = model
            await persistRecord()
        } catch {
            startupError = "\(error)"
        }
    }

    public func setEffort(_ level: String) async {
        guard let session else {
            effortLevel = level
            return
        }
        do {
            _ = try await session.sendControl(.setEffort(level))
            effortLevel = level
            await persistRecord()
        } catch {
            startupError = "\(error)"
        }
    }

    public func setFastMode(_ enabled: Bool) async {
        guard let session else {
            fastMode = enabled
            return
        }
        do {
            _ = try await session.sendControl(.setFastMode(enabled))
            fastMode = enabled
            await persistRecord()
        } catch {
            startupError = "\(error)"
        }
    }

    public func setMaxThinkingTokens(_ tokens: Int) async {
        guard let session else {
            maxThinkingTokens = tokens
            return
        }
        do {
            _ = try await session.sendControl(.setMaxThinkingTokens(tokens))
            maxThinkingTokens = tokens
            await persistRecord()
        } catch {
            startupError = "\(error)"
        }
    }

    // MARK: - Observation

    private func observe(_ session: ClaudeSession) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            // Backfill first: a resumed or re-mounted panel must show the lines
            // that streamed before this subscription existed.
            let backfill = await session.transcriptLines
            for line in backfill {
                self.builder.consume(line.line)
            }
            self.processPhase = await session.processPhase
            self.turnPhase = await session.turnPhase
            self.queue = await session.queuedInputs
            self.initialization = await session.systemInitialization
            self.latestResult = await session.latestResult
            self.scheduleFlush()
            for await change in await session.changes() {
                guard !Task.isCancelled else { return }
                self.apply(change)
            }
        }
    }

    private func apply(_ change: ClaudeSessionChange) {
        switch change {
        case .stateChanged(let process, let turn):
            processPhase = process
            turnPhase = turn
            if case .running = process {
                Task { [weak self] in await self?.refreshInitialization() }
            }
        case .line(let transcriptLine):
            builder.consume(transcriptLine.line)
            if case .result = transcriptLine.line {
                Task { [weak self] in await self?.refreshResult() }
            }
        case .queueChanged(let entries):
            queue = entries
        case .diagnostic(let diagnostic):
            if let notice = Self.notice(for: diagnostic) {
                builder.append(notice: notice)
            }
        case .processEnded(let exit, let stderrTail):
            builder.append(
                notice: Self.notice(exit: exit, stderrTail: stderrTail)
            )
        }
        scheduleFlush()
    }

    private func refreshInitialization() async {
        guard let session else { return }
        initialization = await session.systemInitialization
        if selectedModel == nil { selectedModel = initialization?.model }
        await persistRecord()
    }

    private func refreshResult() async {
        guard let session else { return }
        latestResult = await session.latestResult
    }

    /// Publishes accumulated row changes at most once per frame.
    private func scheduleFlush() {
        needsFlush = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: SupermuxHarnessViewModel.coalescingInterval)
            guard let self else { return }
            self.flushTask = nil
            guard self.needsFlush else { return }
            self.needsFlush = false
            self.rows = self.builder.rows
        }
    }

    // MARK: - Persistence

    private func persistRecord() async {
        guard let stableSurfaceID, let launcher else { return }
        let providerSessionID = await session?.claudeSessionID
        // One atomic read-modify-write on the store actor: a separate
        // load + save pair here races the session actor's own persistence
        // sink, and the loser's save would erase the winner's fields
        // (queue delivery states, the provider session ID).
        let workingDirectory = workingDirectory
        let selectedModel = selectedModel
        let effortLevel = effortLevel
        let fastMode = fastMode
        let maxThinkingTokens = maxThinkingTokens
        let derivedTitle = derivedTitle
        let saved = try? await store.update(
            stableSurfaceID: stableSurfaceID,
            default: {
                SupermuxHarnessSessionRecord(
                    stableSurfaceID: stableSurfaceID,
                    launcher: launcher,
                    workingDirectory: workingDirectory
                )
            }
        ) { record in
            record.launcher = launcher
            record.workingDirectory = workingDirectory
            record.claudeSessionID = providerSessionID ?? record.claudeSessionID
            record.model = selectedModel ?? record.model
            record.effortLevel = effortLevel ?? record.effortLevel
            record.fastMode = fastMode
            record.maxThinkingTokens = maxThinkingTokens ?? record.maxThinkingTokens
            record.derivedTitle = derivedTitle ?? record.derivedTitle
            record.lastActiveAt = Date()
        }
        if let saved {
            resumableSessionID = saved.claudeSessionID
        }
    }

    private func deriveTitleIfNeeded(from prompt: String) {
        guard derivedTitle == nil else { return }
        let title = Self.title(fromPrompt: prompt)
        guard !title.isEmpty else { return }
        derivedTitle = title
        onDerivedTitle?(title)
        Task { [weak self] in await self?.persistRecord() }
    }

    /// The tab title derived from a prompt: first line, clipped on a word
    /// boundary so a pasted paragraph does not become the tab name.
    nonisolated static func title(fromPrompt prompt: String) -> String {
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard firstLine.count > 40 else { return firstLine }
        let clipped = firstLine.prefix(40)
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > 16 {
            return String(clipped[clipped.startIndex..<lastSpace]) + "…"
        }
        return clipped + "…"
    }
}
