import Darwin
import Foundation
import SupermuxKit

/// Drives one SupermuxKit Claude harness process for a panel: launch, protocol
/// forwarding, control routing, permission fail-safety, and persisted state.
@MainActor
final class SupermuxHarnessSessionController {
    private final class WeakController {
        weak var value: SupermuxHarnessSessionController?

        init(_ value: SupermuxHarnessSessionController) {
            self.value = value
        }
    }

    private struct SharedModelCatalogProbe {
        let id: UUID
        let task: Task<SupermuxHarnessInitializeCatalog, any Error>
    }

    private struct TaskRecord {
        var taskType: String
        var toolUseID: String?
        var outputFile: String?
    }

    private static var liveControllers: [ObjectIdentifier: WeakController] = [:]
    private static var modelCatalogProbesByBinaryPath: [String: SharedModelCatalogProbe] = [:]

    var eventSink: (([String: Any]) async -> Void)?
    var runningStateSink: ((Bool) -> Void)?
    var titleSink: ((String?) -> Void)?
    var pendingUserInputSink: ((Bool) -> Void)?
    var turnCompletedSink: ((SupermuxHarnessResultFrame) -> Void)?
    var permissionPromptSink: ((String) -> Void)?
    var restoreStateRetirementSink: (() -> Void)?

    private(set) var workingDirectory: String?
    private(set) var snapshot = SessionSupermuxHarnessPanelSnapshot()
    var composerDraft: String?

    private var processSession: (any SupermuxHarnessProcessSessionProtocol)!
    private var controlRouter: SupermuxHarnessControlRouter?
    private let encoder = SupermuxHarnessProtocolEncoder()
    private let binarySetting: SupermuxHarnessBinarySetting
    private let modelCatalogStore: SupermuxHarnessModelCatalogStore
    private let lastUsedModelStore: SupermuxHarnessLastUsedModelStore
    private let projectsRootURL: URL
    private let taskOutputRootURL: URL
    private let taskOutputCanonicalRootURL: URL
    private let fileManager: FileManager
    private let transcriptService: any SupermuxHarnessSubagentTranscriptLoading
    private let modelCatalogProbe: @MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog
    private var modelCatalogProbeTask: Task<Void, Never>?
    private var modelCatalogProbeID: UUID?
    private var isClosed = false
    private var isStartPending = false
    private var binarySettingRevision = 0
    private var cachedCLIStatus: [String: Any]?
    private var taskRecordsByID: [String: TaskRecord] = [:]
    private var sessionFileWatcher: SupermuxHarnessSessionFileWatcher?
    private var lifecycleEventDeliveryTask: Task<Void, Never>?
    private var watchedSessionID: String?
    private var isTurnActive = false

    init(
        workingDirectory: String?,
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        transcriptService: any SupermuxHarnessSubagentTranscriptLoading,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        projectsRootURL: URL? = nil,
        taskOutputRootURL: URL? = nil,
        modelCatalogProbe: (@MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog)? = nil,
        processSessionFactory: @MainActor (
            @escaping SupermuxHarnessProtocolLineSink,
            @escaping SupermuxHarnessStderrSink,
            @escaping SupermuxHarnessLifecycleSink
        ) -> any SupermuxHarnessProcessSessionProtocol = { protocolLineSink, stderrSink, lifecycleSink in
            SupermuxHarnessProcessSession(
                protocolLineSink: protocolLineSink,
                stderrSink: stderrSink,
                lifecycleSink: lifecycleSink
            )
        }
    ) {
        self.fileManager = fileManager
        self.transcriptService = transcriptService
        self.projectsRootURL = projectsRootURL ?? Self.claudeProjectsRootURL
        if let taskOutputRootURL {
            self.taskOutputRootURL = taskOutputRootURL
            taskOutputCanonicalRootURL = taskOutputRootURL.resolvingSymlinksInPath()
        } else {
            self.taskOutputRootURL = URL(
                fileURLWithPath: "/tmp/claude-\(getuid())",
                isDirectory: true
            )
            taskOutputCanonicalRootURL = URL(
                fileURLWithPath: "/private/tmp/claude-\(getuid())",
                isDirectory: true
            )
        }
        binarySetting = SupermuxHarnessBinarySetting(defaults: defaults, fileManager: fileManager)
        modelCatalogStore = SupermuxHarnessModelCatalogStore(defaults: defaults)
        lastUsedModelStore = SupermuxHarnessLastUsedModelStore(defaults: defaults)
        if let modelCatalogProbe {
            self.modelCatalogProbe = modelCatalogProbe
        } else {
            let probe = SupermuxHarnessModelCatalogProbe()
            self.modelCatalogProbe = { plan in
                try await probe.probe(plan: plan)
            }
        }
        self.workingDirectory = workingDirectory ?? restoreState?.workingDirectory
        if var restored = restoreState {
            restored.workingDirectory = self.workingDirectory
            snapshot = restored
        } else {
            snapshot.workingDirectory = self.workingDirectory
        }
        if snapshot.permissionMode == nil {
            snapshot.permissionMode = SessionSupermuxHarnessPanelSnapshot.defaultPermissionMode
        }
        processSession = processSessionFactory(
            { [weak self] line in
                await self?.consumeProtocolLine(line)
            },
            { [weak self] text in
                await self?.eventSink?(["kind": "stderr", "text": text])
            },
            { [weak self] event in
                self?.consumeLifecycleEvent(event)
            }
        )
        Self.liveControllers[ObjectIdentifier(self)] = WeakController(self)
    }

    var isRunning: Bool {
        processSession.isRunning
    }

    var restoreContext: [String: Any]? {
        guard let sessionId = snapshot.sessionId, !sessionId.isEmpty else { return nil }
        var restore: [String: Any] = ["sessionId": sessionId]
        if let model = snapshot.model { restore["model"] = model }
        if let mode = snapshot.permissionMode { restore["permissionMode"] = mode }
        return restore
    }

    func cliStatus() async -> [String: Any] {
        if let cachedCLIStatus { return cachedCLIStatus }
        let status: [String: Any]
        do {
            let plan = try await resolveClaudeLaunchPlan()
            var available: [String: Any] = [
                "available": true,
                "path": plan.executableURL.path,
            ]
            if let version = await Self.claudeVersion(
                executablePath: plan.executableURL.path,
                environment: plan.environment
            ) {
                available["version"] = version
            }
            status = available
        } catch let error as AgentExecutableResolverError {
            status = ["available": false, "error": error.message]
        } catch {
            status = ["available": false, "error": error.localizedDescription]
        }
        guard !isClosed else { return status }
        cachedCLIStatus = status
        return status
    }

    func contextBootstrap() async -> (cliStatus: [String: Any], cachedModels: [[String: Any]]?) {
        let status = await cliStatus()
        guard let binaryPath = status["path"] as? String else {
            return (status, nil)
        }
        let cachedModels = modelCatalogStore.snapshot(forBinaryPath: binaryPath)?.models
            .map(\.rawValue)
        if cachedModels?.isEmpty != false {
            startModelCatalogProbeIfNeeded(expectedBinaryPath: binaryPath)
        }
        return (status, cachedModels?.isEmpty == false ? cachedModels : nil)
    }

    /// The model and effort a flagless `claude` start in this working directory
    /// will actually run, read from the CLI's own settings files in its own
    /// precedence order: project `.claude/settings.local.json`, then project
    /// `.claude/settings.json`, then `~/.claude/settings.json`. Delivered with
    /// `harness.context` so a fresh pane can name the real session-default
    /// model immediately (round-6 item 12) instead of showing the catalog's
    /// generic "Default (recommended)" row until the first init frame — and the
    /// settings `effortLevel` is the only source for which effort an un-picked
    /// session runs at (item 5), since the live catalog ships no per-model
    /// default. Best-effort: unreadable or absent files simply contribute
    /// nothing, and an init frame later outranks whatever this said.
    func settingsDefaults() -> [String: Any]? {
        Self.settingsDefaults(
            workingDirectoryURL: workingDirectoryURL,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser
        )
    }

    /// The `defaults` payload for `harness.context`: the settings-file values,
    /// plus the machine-wide LAST-USED model/effort under `lastUsed`.
    ///
    /// The real CLI forgets a plain `/model` switch on exit ("Set model to …
    /// for this session only" — persisting requires the explicit save-default
    /// gesture, which writes `~/.claude/settings.json` "model"). The user's ask
    /// is stronger than the CLI's own behavior: a new pane should default to
    /// the last model used in ANY session. So the harness records every model a
    /// session actually runs with (init frame, live set_model ack, a start
    /// that carried one) into `SupermuxHarnessLastUsedModelStore`, shared
    /// across every pane through UserDefaults, and the web layer ranks it
    /// above the settings default but below anything session-specific.
    func contextDefaults() -> [String: Any]? {
        var defaults = settingsDefaults() ?? [:]
        if let lastUsed = lastUsedModelStore.snapshot() {
            var payload: [String: Any] = ["model": lastUsed.model]
            if let effort = lastUsed.effort { payload["effort"] = effort }
            defaults["lastUsed"] = payload
        }
        return defaults.isEmpty ? nil : defaults
    }

    /// Records that a session is actually running `model` — the write half of
    /// `contextDefaults()`'s `lastUsed`. A `nil` effort leaves the stored
    /// effort untouched (the wire rarely reports one; the explicit paths do).
    private func recordModelUse(model: String?, effort: String? = nil) {
        guard let model = Self.normalized(model) else { return }
        lastUsedModelStore.store(model: model, effort: Self.normalized(effort))
    }

    /// The pure half of `settingsDefaults()`, split out so tests can point the
    /// "home" at a fixture directory instead of the real account's settings.
    nonisolated static func settingsDefaults(
        workingDirectoryURL: URL?,
        homeDirectoryURL: URL
    ) -> [String: Any]? {
        var candidates: [URL] = []
        if let workingDirectoryURL {
            let project = workingDirectoryURL.appendingPathComponent(".claude", isDirectory: true)
            candidates.append(project.appendingPathComponent("settings.local.json"))
            candidates.append(project.appendingPathComponent("settings.json"))
        }
        candidates.append(
            homeDirectoryURL
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
        var model: String?
        var effort: String?
        for url in candidates {
            guard model == nil || effort == nil else { break }
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if model == nil, let value = normalized(object["model"] as? String) {
                model = value
            }
            if effort == nil, let value = normalized(object["effortLevel"] as? String) {
                effort = value
            }
        }
        guard model != nil || effort != nil else { return nil }
        var defaults: [String: Any] = [:]
        if let model { defaults["model"] = model }
        if let effort { defaults["effort"] = effort }
        return defaults
    }

    func binarySettingState() async -> [String: Any] {
        let status = await cliStatus()
        var setting: [String: Any] = [:]
        if let path = status["path"] as? String { setting["resolvedPath"] = path }
        if let version = status["version"] as? String { setting["version"] = version }
        if let error = status["error"] as? String { setting["error"] = error }
        if let overridePath = binarySetting.overridePath { setting["overridePath"] = overridePath }
        return setting
    }

    func setBinaryPath(_ path: String?) async throws -> [String: Any] {
        try binarySetting.setPath(path)
        await Self.broadcastBinarySettingInvalidation()
        return await binarySettingState()
    }

    func invalidateCLIStatus() {
        cachedCLIStatus = nil
    }

    func start(
        resumeSessionId: String?,
        forkSession: Bool,
        model: String?,
        permissionMode: String?,
        effort: String?
    ) async throws -> String {
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        guard !processSession.isRunning, !isStartPending else {
            throw SupermuxHarnessBridgeError.sessionAlreadyRunning
        }
        isStartPending = true
        defer { isStartPending = false }
        return try await startRun(
            resumeSessionId: resumeSessionId,
            resumeSessionAt: nil,
            forkSession: forkSession,
            model: model,
            permissionMode: permissionMode,
            effort: effort
        )
    }

    func restart(
        resumeSessionId: String?,
        forkSession: Bool,
        model: String?,
        permissionMode: String?,
        effort: String?
    ) async throws -> String {
        try await restartRun(
            resumeSessionId: resumeSessionId,
            resumeSessionAt: nil,
            forkSession: forkSession,
            model: model,
            permissionMode: permissionMode,
            effort: effort
        )
    }

    private func restartRun(
        resumeSessionId: String?,
        resumeSessionAt: String?,
        forkSession: Bool,
        model: String?,
        permissionMode: String?,
        effort: String?
    ) async throws -> String {
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        guard !isStartPending else { throw SupermuxHarnessBridgeError.sessionAlreadyRunning }
        isStartPending = true
        defer { isStartPending = false }

        let stoppedRunID = processSession.activeRunID
        if let router = controlRouter {
            await router.close(denialMessage: Self.stoppedDenialMessage)
            if controlRouter === router {
                controlRouter = nil
            }
        }
        if let stoppedRunID, processSession.activeRunID == stoppedRunID {
            do {
                _ = try await processSession.terminateAndWait(timeout: 10)
            } catch SupermuxHarnessProcessError.notRunning {
                // The fully-drained lifecycle event won the race with the explicit wait.
            } catch {
                throw SupermuxHarnessBridgeError.startFailed(error.localizedDescription)
            }
        }
        guard !processSession.isRunning else {
            throw SupermuxHarnessBridgeError.sessionAlreadyRunning
        }
        return try await startRun(
            resumeSessionId: resumeSessionId,
            resumeSessionAt: resumeSessionAt,
            forkSession: forkSession,
            model: model,
            permissionMode: permissionMode,
            effort: effort
        )
    }

    private func startRun(
        resumeSessionId: String?,
        resumeSessionAt: String?,
        forkSession: Bool,
        model: String?,
        permissionMode: String?,
        effort: String?
    ) async throws -> String {
        guard let directoryPath = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directoryPath.isEmpty else {
            throw SupermuxHarnessBridgeError.workingDirectoryUnavailable
        }
        await lifecycleEventDeliveryTask?.value
        lifecycleEventDeliveryTask = nil
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        taskRecordsByID.removeAll()
        cancelModelCatalogProbe()
        let resolvedPlan = try await resolveClaudeLaunchPlan()
        guard !isClosed, !processSession.isRunning else {
            throw SupermuxHarnessBridgeError.sessionAlreadyRunning
        }

        let resolvedPermissionMode = permissionMode
            .flatMap(SupermuxHarnessPermissionMode.init(rawValue:))
            ?? snapshot.permissionMode.flatMap(SupermuxHarnessPermissionMode.init(rawValue:))
            ?? .bypassPermissions
        var options = SupermuxHarnessLaunchOptions()
        options.model = model
        options.permissionMode = resolvedPermissionMode
        options.resumeSessionID = resumeSessionId
        options.resumeSessionAt = resumeSessionAt
        options.forkSession = forkSession
        options.effort = effort
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: resolvedPlan.executableURL,
            workingDirectoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            environment: resolvedPlan.environment,
            options: options
        )

        let started: SupermuxHarnessStartedProcess
        do {
            started = try processSession.start(plan: plan)
        } catch {
            throw SupermuxHarnessBridgeError.startFailed(error.localizedDescription)
        }
        let runID = started.runID
        let router = SupermuxHarnessControlRouter(sender: { [weak self] frame in
            guard let self else { throw SupermuxHarnessProcessError.notRunning }
            try await self.processSession.send(frame, forRunID: runID)
        })
        controlRouter = router

        if let model { snapshot.model = model }
        // A start that carried a model is a model USE: the machine-wide
        // last-used default follows it, so the next new pane opens on it.
        recordModelUse(model: model, effort: effort)
        snapshot.permissionMode = resolvedPermissionMode.rawValue
        snapshot.sessionId = forkSession ? nil : resumeSessionId
        if resumeSessionId == nil {
            restoreStateRetirementSink?()
        }
        if resumeSessionId == nil || forkSession {
            // A fresh or forked session starts untitled; the CLI titles it after
            // its first turn. Keeping the previous session's title (or rename
            // pin) would mislabel the new conversation, and the old session's
            // watcher would keep pushing the old title over the new one.
            snapshot.title = nil
            snapshot.titleIsCustom = nil
            titleSink?(nil)
            sessionFileWatcher?.cancel()
            sessionFileWatcher = nil
            watchedSessionID = nil
        }
        var event: [String: Any] = ["kind": "runStarted", "runId": started.runID]
        if let resumeSessionId { event["resumedSessionId"] = resumeSessionId }
        await eventSink?(event)
        if resumeSessionId != nil {
            // A resumed session already has a topic title on disk; adopt it now
            // rather than waiting for a write to wake the watcher.
            refreshSessionTitleFromDisk()
        }
        watchSessionFileForTitles()
        let binaryPath = resolvedPlan.executableURL.path
        let binaryRevision = binarySettingRevision
        Task { @MainActor [weak self, weak router] in
            guard let self, let router else { return }
            do {
                let payload = try await router.issue(.initialize)
                guard !self.isClosed,
                      self.controlRouter === router,
                      self.binarySettingRevision == binaryRevision else {
                    return
                }
                await self.consumeInitializeCatalog(payload, binaryPath: binaryPath)
            } catch {
                // The live protocol line is still forwarded; catalog persistence is best-effort.
            }
        }
        return started.runID
    }

    func send(text: String, images: [SupermuxHarnessImage], uuid: String) async throws {
        guard !isClosed, processSession.isRunning else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        let frame = try encoder.userMessage(text: text, images: images, uuid: uuid)
        try await processSession.send(frame)
        setTurnActive(true)
    }

    func interrupt(cancelQueued: Bool) async throws {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await router.issue(.interrupt(cancelQueued: cancelQueued))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
    }

    func cancelQueued(messageUuid: String) async throws {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await router.issue(.cancelAsyncMessage(messageUUID: messageUuid))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
    }

    func stopTask(taskId: String) async throws {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await router.issue(.stopTask(taskID: taskId))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
    }

    func backgroundTask(toolUseId: String?) async throws -> [String: Any] {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        let payload = try await router.issue(.backgroundTasks(toolUseID: toolUseId))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        return ["backgrounded": payload.bool(forKey: "backgrounded") ?? false]
    }

    func stop() async {
        let stoppedRunID = processSession.activeRunID
        if let router = controlRouter {
            await router.close(denialMessage: Self.stoppedDenialMessage)
            if controlRouter === router {
                controlRouter = nil
            }
        }
        guard processSession.activeRunID == stoppedRunID else { return }
        try? processSession.terminate()
    }

    func rewindPreview(userMessageUuid: String) async -> [String: Any] {
        do {
            let router = try await ensureProcessForRewind()
            let payload = try await router.issue(
                .rewindFiles(userMessageID: userMessageUuid, dryRun: true)
            )
            guard !isClosed, controlRouter === router else {
                throw SupermuxHarnessBridgeError.sessionNotRunning
            }
            return Self.normalizedRewindPreview(payload)
        } catch {
            return [
                "canRewind": false,
                "filesChanged": [],
                "insertions": 0,
                "deletions": 0,
                "error": Self.rewindFilesUnavailableMessage,
            ]
        }
    }

    func rewind(
        userMessageUuid: String,
        restoreFiles: Bool,
        resumeAtUuid: String?
    ) async throws -> [String: Any] {
        guard let sessionID = currentSessionID else {
            throw SupermuxHarnessBridgeError.sessionUnavailableForRewind
        }
        var filesRestored = false
        var restoreFailureReason: String?
        if restoreFiles {
            do {
                let router = try await ensureProcessForRewind()
                let payload = try await router.issue(
                    .rewindFiles(userMessageID: userMessageUuid, dryRun: false)
                )
                guard !isClosed, controlRouter === router else {
                    throw SupermuxHarnessBridgeError.sessionNotRunning
                }
                if payload.bool(forKey: "canRewind") == false {
                    restoreFailureReason = Self.rewindFailureReason(from: payload)
                } else {
                    filesRestored = true
                }
            } catch {
                restoreFailureReason = Self.rewindFailureReason(from: error)
            }
            if let restoreFailureReason {
                await eventSink?(["kind": "stderr", "text": restoreFailureReason])
            }
        }

        let normalizedResumeAt = Self.normalized(resumeAtUuid)
        let runID = try await restartRun(
            resumeSessionId: normalizedResumeAt == nil ? nil : sessionID,
            resumeSessionAt: normalizedResumeAt,
            forkSession: false,
            model: snapshot.model,
            permissionMode: snapshot.permissionMode,
            effort: nil
        )
        var reply: [String: Any] = [
            "runId": runID,
            "filesRestored": filesRestored,
        ]
        if let restoreFailureReason {
            reply["reason"] = restoreFailureReason
        }
        return reply
    }

    func setModel(model: String, effort: String?) async throws {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await router.issue(.setModel(model: model, effort: effort))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        snapshot.model = model
        // The CLI acknowledged the switch, so this model is now in USE — the
        // machine-wide last-used default follows the ack, not the request.
        recordModelUse(model: model, effort: effort)
    }

    func setPermissionMode(_ mode: String) async throws {
        guard let permissionMode = SupermuxHarnessPermissionMode(rawValue: mode) else {
            throw SupermuxHarnessBridgeError.missingParameter("mode")
        }
        guard let router = controlRouter else {
            guard !isClosed else { throw SupermuxHarnessBridgeError.sessionNotRunning }
            snapshot.permissionMode = mode
            return
        }
        _ = try await router.issue(.setPermissionMode(permissionMode))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        snapshot.permissionMode = mode
    }

    func respondPermission(
        requestId: String,
        behavior: String,
        updatedInput: [String: Any]?,
        updatedPermissions: [[String: Any]]?,
        message: String?,
        interrupt: Bool
    ) async throws {
        guard let controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        let decision: SupermuxHarnessPermissionDecision
        if behavior == "allow" {
            let input = try SupermuxHarnessJSONObject(rawValue: updatedInput ?? [:])
            let permissions = try updatedPermissions?.map { try SupermuxHarnessJSONObject(rawValue: $0) }
            decision = .allow(updatedInput: input, updatedPermissions: permissions)
        } else {
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = .deny(
                message: (trimmed?.isEmpty == false ? trimmed : nil) ?? Self.defaultDenialMessage,
                interrupt: interrupt
            )
        }
        defer { emitPendingUserInputStateIfChanged() }
        do {
            try await controlRouter.respondToPermission(requestID: requestId, decision: decision)
        } catch SupermuxHarnessControlRouterError.permissionRequestNotFound {
            throw SupermuxHarnessBridgeError.permissionRequestNotFound
        }
    }

    func renameSession(title: String) async throws {
        guard let router = controlRouter else {
            guard !isClosed else { throw SupermuxHarnessBridgeError.sessionNotRunning }
            snapshot.title = title
            snapshot.titleIsCustom = true
            sessionFileWatcher?.cancel()
            sessionFileWatcher = nil
            titleSink?(title)
            return
        }
        _ = try await router.issue(.renameSession(title: title))
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        snapshot.title = title
        snapshot.titleIsCustom = true
        sessionFileWatcher?.cancel()
        sessionFileWatcher = nil
        titleSink?(title)
    }

    func getContextUsage() async throws -> [String: Any] {
        guard let router = controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        let payload = try await router.issue(.getContextUsage)
        guard !isClosed, controlRouter === router else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        return payload.rawValue
    }

    func fileSuggestions(query: String) async -> [String: Any] {
        guard let router = controlRouter, processSession.isRunning else { return ["paths": []] }
        guard let payload = try? await router.issue(.fileSuggestions(query: query)),
              !isClosed,
              controlRouter === router,
              processSession.isRunning else {
            return ["paths": []]
        }
        var result = payload.rawValue
        if result["paths"] == nil {
            result["paths"] = Self.suggestionPaths(from: result)
        }
        return result
    }

    nonisolated static var claudeProjectsRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func listSessions(limit: Int?) async throws -> [[String: Any]] {
        guard let directoryURL = workingDirectoryURL else { return [] }
        let projectsRootURL = self.projectsRootURL
        let sessions = try await Task.detached(priority: .userInitiated) {
            let discovery = SupermuxHarnessSessionDiscovery(
                projectsRootURL: projectsRootURL,
                fileManager: .default
            )
            return try discovery.listSessions(for: directoryURL, limit: limit)
        }.value
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        return sessions.map { session in
            var entry: [String: Any] = [
                "sessionId": session.sessionID,
                "title": session.title,
                "updatedAtMs": Int(session.updatedAt.timeIntervalSince1970 * 1000),
                "messageCount": session.messageCount,
            ]
            if let firstPrompt = session.firstPrompt { entry["firstPrompt"] = firstPrompt }
            if let gitBranch = session.gitBranch { entry["gitBranch"] = gitBranch }
            return entry
        }
    }

    func loadSessionHistory(sessionId: String) async throws -> [String: Any] {
        guard let directoryURL = workingDirectoryURL else {
            throw SupermuxHarnessBridgeError.workingDirectoryUnavailable
        }
        let projectsRootURL = self.projectsRootURL
        let page = try await Task.detached(priority: .userInitiated) {
            let discovery = SupermuxHarnessSessionDiscovery(
                projectsRootURL: projectsRootURL,
                fileManager: .default
            )
            return try discovery.loadHistory(
                for: directoryURL,
                sessionID: sessionId,
                recordLimit: Self.historyRecordLimit
            )
        }.value
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        return [
            "events": page.events.map(\.rawValue),
            "truncated": page.truncated,
        ]
    }

    func loadSubagentTranscript(
        taskId: String?,
        workflowRunId: String?,
        agentId: String?,
        afterRevision: Int?
    ) async throws -> [String: Any] {
        guard let directoryURL = workingDirectoryURL else {
            throw SupermuxHarnessBridgeError.workingDirectoryUnavailable
        }
        guard let sessionID = currentSessionID else {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        let localTaskID = Self.normalized(taskId)
        let runID = Self.normalized(workflowRunId)
        let workflowAgentID = Self.normalized(agentId)
        let address: SupermuxHarnessSubagentTranscriptAddress
        if let localTaskID, runID == nil, workflowAgentID == nil {
            address = .localAgent(
                workingDirectoryURL: directoryURL,
                sessionID: sessionID,
                taskID: localTaskID
            )
        } else if localTaskID == nil, let runID, let workflowAgentID {
            address = .workflowAgent(
                workingDirectoryURL: directoryURL,
                sessionID: sessionID,
                workflowRunID: runID,
                agentID: workflowAgentID
            )
        } else {
            throw SupermuxHarnessBridgeError.invalidRequest
        }

        let update: SupermuxHarnessSubagentTranscriptUpdate
        do {
            update = try await transcriptService.loadTranscript(
                at: address,
                afterRevision: afterRevision
            )
        } catch is SupermuxHarnessSubagentTranscriptReaderError {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        var result: [String: Any] = [
            "revision": update.revision,
            "replace": update.replace,
            "droppedEventCount": update.droppedEventCount,
            "events": update.events.map(\.rawValue),
            "truncated": update.truncated,
            "missing": update.missing,
        ]
        switch update.metadata {
        case .unchanged:
            break
        case .deleted:
            result["meta"] = NSNull()
        case .value(let metadata):
            var meta: [String: Any] = [:]
            if let agentType = metadata.agentType { meta["agentType"] = agentType }
            if let description = metadata.description { meta["description"] = description }
            if let spawnDepth = metadata.spawnDepth { meta["spawnDepth"] = spawnDepth }
            result["meta"] = meta
        }
        return result
    }

    func readTaskOutput(taskId: String) async throws -> [String: Any] {
        guard let record = taskRecordsByID[taskId] else {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        let observedTaskIDs = Set(taskRecordsByID.keys)
        let outputFile = record.outputFile
        let expectedOutputFile = derivedTaskOutputFile(
            taskID: taskId,
            sessionID: currentSessionID
        )
        let taskOutputRootURL = self.taskOutputRootURL
        let taskOutputCanonicalRootURL = self.taskOutputCanonicalRootURL
        let fileManager = self.fileManager
        let page: SupermuxHarnessTaskOutputPage
        do {
            page = try await Task.detached(priority: .userInitiated) {
                let reader = SupermuxHarnessTaskOutputReader(
                    temporaryRootURL: taskOutputRootURL,
                    canonicalRootURL: taskOutputCanonicalRootURL,
                    fileManager: fileManager
                )
                return try reader.read(
                    taskID: taskId,
                    observedTaskIDs: observedTaskIDs,
                    outputFilePath: outputFile,
                    expectedOutputFilePath: expectedOutputFile
                )
            }.value
        } catch is SupermuxHarnessTaskOutputReaderError {
            throw SupermuxHarnessBridgeError.invalidRequest
        }
        guard !isClosed else { throw SupermuxHarnessBridgeError.invalidRequest }
        return [
            "text": page.text,
            "truncated": page.truncated,
            "missing": page.missing,
        ]
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Self.liveControllers.removeValue(forKey: ObjectIdentifier(self))
        cancelModelCatalogProbe()
        sessionFileWatcher?.cancel()
        sessionFileWatcher = nil
        guard let router = controlRouter else {
            processSession.close()
            return
        }
        controlRouter = nil
        Task { @MainActor [self, router] in
            await router.close(denialMessage: Self.closedDenialMessage)
            processSession.close()
        }
    }

    private func resolveClaudeLaunchPlan() async throws -> AgentSessionLaunchPlan {
        var configuredExecutablePaths = AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        if let overridePath = binarySetting.validOverridePath {
            configuredExecutablePaths[.claude] = overridePath
        }
        return try await Task.detached(priority: .userInitiated) {
            let resolver = AgentExecutableResolver(
                configuredExecutablePaths: configuredExecutablePaths
            )
            return try resolver.resolve(.claude)
        }.value
    }

    private func cancelModelCatalogProbe() {
        modelCatalogProbeTask?.cancel()
        modelCatalogProbeTask = nil
        modelCatalogProbeID = nil
    }

    private func startModelCatalogProbeIfNeeded(expectedBinaryPath: String) {
        guard !isClosed, modelCatalogProbeTask == nil else { return }
        let probeID = UUID()
        let binaryRevision = binarySettingRevision
        modelCatalogProbeID = probeID
        modelCatalogProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.modelCatalogProbeID == probeID {
                    self.modelCatalogProbeTask = nil
                    self.modelCatalogProbeID = nil
                }
            }
            do {
                let resolvedPlan = try await self.resolveClaudeLaunchPlan()
                guard !Task.isCancelled,
                      !self.isClosed,
                      self.binarySettingRevision == binaryRevision,
                      resolvedPlan.executableURL.path == expectedBinaryPath else {
                    return
                }
                let probePlan = SupermuxHarnessLaunchPlan(
                    executableURL: resolvedPlan.executableURL,
                    workingDirectoryURL: self.workingDirectoryURL
                        ?? FileManager.default.homeDirectoryForCurrentUser,
                    environment: resolvedPlan.environment
                )
                let sharedProbe = Self.sharedModelCatalogProbe(
                    binaryPath: expectedBinaryPath,
                    plan: probePlan,
                    operation: self.modelCatalogProbe
                )
                let catalog = try await sharedProbe.value
                guard !Task.isCancelled,
                      !self.isClosed,
                      self.binarySettingRevision == binaryRevision else {
                    return
                }
                await self.consumeInitializeCatalog(catalog, binaryPath: expectedBinaryPath)
            } catch {
                // Context remains usable without a catalog; the next pane load can probe again.
            }
        }
    }

    private func consumeInitializeCatalog(
        _ payload: SupermuxHarnessJSONObject,
        binaryPath: String
    ) async {
        await consumeInitializeCatalog(
            SupermuxHarnessInitializeCatalog(response: payload),
            binaryPath: binaryPath
        )
    }

    private func consumeInitializeCatalog(
        _ catalog: SupermuxHarnessInitializeCatalog,
        binaryPath: String
    ) async {
        try? modelCatalogStore.store(catalog.models, forBinaryPath: binaryPath)
        guard !catalog.models.isEmpty else { return }
        await eventSink?([
            "kind": "modelCatalog",
            "models": catalog.models.map(\.rawValue),
        ])
    }

    private static func sharedModelCatalogProbe(
        binaryPath: String,
        plan: SupermuxHarnessLaunchPlan,
        operation: @escaping @MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog
    ) -> Task<SupermuxHarnessInitializeCatalog, any Error> {
        if let existing = modelCatalogProbesByBinaryPath[binaryPath] {
            return existing.task
        }
        let probeID = UUID()
        let task = Task { @MainActor in
            do {
                return try await operation(plan)
            } catch {
                if modelCatalogProbesByBinaryPath[binaryPath]?.id == probeID {
                    modelCatalogProbesByBinaryPath.removeValue(forKey: binaryPath)
                }
                throw error
            }
        }
        modelCatalogProbesByBinaryPath[binaryPath] = SharedModelCatalogProbe(
            id: probeID,
            task: task
        )
        return task
    }

    private static func broadcastBinarySettingInvalidation() async {
        for probe in modelCatalogProbesByBinaryPath.values {
            probe.task.cancel()
        }
        modelCatalogProbesByBinaryPath.removeAll()

        let live = liveControllers.compactMapValues(\.value)
        liveControllers = live.mapValues(WeakController.init)
        for controller in live.values {
            await controller.handleBinarySettingInvalidation()
        }
    }

    private func handleBinarySettingInvalidation() async {
        binarySettingRevision &+= 1
        invalidateBinaryCaches()
        await eventSink?(["kind": "modelCatalog", "models": []])
    }

    private func invalidateBinaryCaches() {
        cachedCLIStatus = nil
        cancelModelCatalogProbe()
        modelCatalogStore.invalidateAll()
    }

    private func ensureProcessForRewind() async throws -> SupermuxHarnessControlRouter {
        if let router = controlRouter, processSession.isRunning {
            return router
        }
        if processSession.isRunning {
            _ = try await processSession.terminateAndWait(timeout: 10)
        }
        guard let sessionID = currentSessionID else {
            throw SupermuxHarnessBridgeError.sessionUnavailableForRewind
        }
        _ = try await start(
            resumeSessionId: sessionID,
            forkSession: false,
            model: snapshot.model,
            permissionMode: snapshot.permissionMode,
            effort: nil
        )
        guard let router = controlRouter else {
            throw SupermuxHarnessBridgeError.sessionNotRunning
        }
        return router
    }

    private var currentSessionID: String? {
        Self.normalized(snapshot.sessionId)
    }

    private var workingDirectoryURL: URL? {
        guard let path = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func consumeTaskRecordFromProtocolLine(_ line: SupermuxHarnessDecodedLine) {
        guard case .user(let frame)? = line.frame,
              let result = frame.toolUseResult else {
            return
        }
        let backgroundTaskID = result.string(forKey: "backgroundTaskId")
        let workflowTaskID = result.string(forKey: "taskId")
        let agentTaskID = result.string(forKey: "agentId")
        guard let taskID = backgroundTaskID ?? workflowTaskID ?? agentTaskID else { return }
        let toolResult = Self.toolResultDetails(from: frame.message.rawValue["content"])
        let inferredTaskType: String
        if let taskType = result.string(forKey: "taskType") {
            inferredTaskType = taskType
        } else if backgroundTaskID != nil {
            inferredTaskType = "local_bash"
        } else if workflowTaskID != nil {
            inferredTaskType = "local_workflow"
        } else {
            inferredTaskType = "local_agent"
        }
        let outputFile = result.string(forKey: "outputFile")
            ?? result.string(forKey: "output_file")
            ?? Self.outputFilePath(from: toolResult.text)
        updateTaskRecord(
            taskID: taskID,
            taskType: inferredTaskType,
            toolUseID: toolResult.toolUseID,
            outputFile: outputFile,
            sessionID: frame.sessionID
        )
    }

    private func consumeTaskRecordFromSystemFrame(_ frame: SupermuxHarnessSystemFrame) {
        if frame.subtype == .backgroundTasksChanged {
            for task in frame.rawObject.objects(forKey: "tasks") ?? [] {
                guard let taskID = task.string(forKey: "task_id") else { continue }
                updateTaskRecord(
                    taskID: taskID,
                    taskType: task.string(forKey: "task_type"),
                    toolUseID: nil,
                    outputFile: nil,
                    sessionID: frame.sessionID
                )
            }
            return
        }
        switch frame.subtype {
        case .taskStarted, .taskProgress, .taskUpdated, .taskNotification:
            guard let taskID = frame.rawObject.string(forKey: "task_id") else { return }
            updateTaskRecord(
                taskID: taskID,
                taskType: frame.rawObject.string(forKey: "task_type"),
                toolUseID: frame.rawObject.string(forKey: "tool_use_id"),
                outputFile: frame.rawObject.string(forKey: "output_file"),
                sessionID: frame.sessionID
            )
        default:
            break
        }
    }

    private func updateTaskRecord(
        taskID: String,
        taskType: String?,
        toolUseID: String?,
        outputFile: String?,
        sessionID: String?
    ) {
        var record = taskRecordsByID[taskID] ?? TaskRecord(
            taskType: taskType ?? "unknown",
            toolUseID: nil,
            outputFile: nil
        )
        if let taskType { record.taskType = taskType }
        if let toolUseID { record.toolUseID = toolUseID }
        if let outputFile {
            record.outputFile = outputFile
        } else if record.outputFile == nil {
            record.outputFile = derivedTaskOutputFile(
                taskID: taskID,
                sessionID: sessionID ?? currentSessionID
            )
        }
        taskRecordsByID[taskID] = record
    }

    private func derivedTaskOutputFile(taskID: String, sessionID: String?) -> String? {
        guard let directoryURL = workingDirectoryURL,
              let sessionID,
              Self.isSafePathIdentifier(taskID),
              Self.isSafePathIdentifier(sessionID) else {
            return nil
        }
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
        guard let mungedDirectory = discovery
            .mungedProjectDirectoryNames(for: directoryURL)
            .first else {
            return nil
        }
        return taskOutputRootURL
            .appendingPathComponent(mungedDirectory, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("\(taskID).output")
            .path
    }

    private nonisolated static func toolResultDetails(
        from content: Any?
    ) -> (toolUseID: String?, text: String) {
        guard let blocks = content as? [Any] else { return (nil, "") }
        var toolUseID: String?
        var textParts: [String] = []
        for case let block as [String: Any] in blocks
        where block["type"] as? String == "tool_result" {
            if toolUseID == nil { toolUseID = block["tool_use_id"] as? String }
            textParts.append(contentsOf: textPartsFromToolResultContent(block["content"]))
        }
        return (toolUseID, textParts.joined(separator: "\n"))
    }

    private nonisolated static func textPartsFromToolResultContent(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let object = block as? [String: Any],
                  object["type"] as? String == "text" else {
                return nil
            }
            return object["text"] as? String
        }
    }

    private nonisolated static func outputFilePath(from text: String) -> String? {
        let marker = "Output is being written to: "
        guard let markerRange = text.range(of: marker) else { return nil }
        let remainder = text[markerRange.upperBound...]
        guard let suffixRange = remainder.range(of: ".output") else { return nil }
        let path = String(remainder[..<suffixRange.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private nonisolated static func isSafePathIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private func consumeProtocolLine(_ line: SupermuxHarnessDecodedLine) async {
        controlRouter?.consume(line)
        consumeTaskRecordFromProtocolLine(line)
        if case .system(let frame)? = line.frame {
            consumeSystemFrame(frame)
        }
        if case .result(let frame)? = line.frame {
            // The result frame is the CLI's only reliable end-of-turn signal
            // (`session_state_changed` never arrives from the real CLI), the
            // same boundary the terminal's Stop hook fires on.
            setTurnActive(false)
            turnCompletedSink?(frame)
        }
        emitPendingUserInputStateIfChanged()
        await eventSink?(["kind": "protocol", "line": line.object.rawValue])
    }

    /// Mirrors the terminal hooks' lifecycle: UserPromptSubmit → running,
    /// Stop → idle. `send()` and status frames turn it on; the result frame
    /// and process exit turn it off.
    private func setTurnActive(_ active: Bool) {
        guard isTurnActive != active else { return }
        isTurnActive = active
        runningStateSink?(active)
    }

    private var lastEmittedPendingUserInput = false

    /// Reports whether any can_use_tool request is waiting on the user, feeding
    /// the same needs-input indicator terminal tabs show for prompts.
    private func emitPendingUserInputStateIfChanged() {
        let requests = controlRouter?.pendingPermissionRequests ?? []
        let pending = !requests.isEmpty
        guard pending != lastEmittedPendingUserInput else { return }
        lastEmittedPendingUserInput = pending
        pendingUserInputSink?(pending)
        if pending, let request = requests.first {
            permissionPromptSink?(request.displayName ?? request.toolName ?? "")
        }
    }

    /// Adopts the CLI's own topic title, matching the terminal's native tab
    /// titling. The CLI writes `ai-title` records into the session JSONL rather
    /// than emitting a stream frame, so the file is the only source; a watcher
    /// on that file makes retitles land as they are written, not at turn ends.
    /// The CLI retitles as the topic evolves, so the latest disk title wins —
    /// unless the user renamed the session, which pins the title for good.
    private func watchSessionFileForTitles() {
        guard snapshot.titleIsCustom != true,
              let directoryURL = workingDirectoryURL,
              let sessionID = snapshot.sessionId, !sessionID.isEmpty else {
            return
        }
        if sessionFileWatcher != nil, watchedSessionID == sessionID { return }
        sessionFileWatcher?.cancel()
        watchedSessionID = sessionID
        let projectsRootURL = self.projectsRootURL
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
        // The file may not exist until the CLI's first write; the watcher owns
        // the retry. Its URL is re-resolved lazily so munging stays in one place.
        let fileURL = discovery.sessionFileURL(for: directoryURL, sessionID: sessionID)
            ?? Self.expectedSessionFileURL(
                discovery: discovery,
                projectsRootURL: projectsRootURL,
                workingDirectoryURL: directoryURL,
                sessionID: sessionID
            )
        sessionFileWatcher = SupermuxHarnessSessionFileWatcher(fileURL: fileURL) { [weak self] in
            self?.refreshSessionTitleFromDisk()
        }
    }

    private nonisolated static func expectedSessionFileURL(
        discovery: SupermuxHarnessSessionDiscovery,
        projectsRootURL: URL,
        workingDirectoryURL: URL,
        sessionID: String
    ) -> URL {
        let name = discovery.mungedProjectDirectoryNames(for: workingDirectoryURL).first ?? ""
        return projectsRootURL
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(sessionID)
            .appendingPathExtension("jsonl")
    }

    private func refreshSessionTitleFromDisk() {
        guard snapshot.titleIsCustom != true,
              let directoryURL = workingDirectoryURL,
              let sessionID = snapshot.sessionId, !sessionID.isEmpty else {
            return
        }
        let projectsRootURL = self.projectsRootURL
        let fileManager = self.fileManager
        Task.detached(priority: .utility) { [weak self] in
            let discovery = SupermuxHarnessSessionDiscovery(
                projectsRootURL: projectsRootURL,
                fileManager: fileManager
            )
            guard let title = discovery.sessionTitle(for: directoryURL, sessionID: sessionID) else {
                return
            }
            await self?.applyDiscoveredTitle(title, sessionID: sessionID)
        }
    }

    private func applyDiscoveredTitle(_ title: String, sessionID: String) async {
        guard !isClosed,
              snapshot.titleIsCustom != true,
              snapshot.sessionId == sessionID,
              snapshot.title != title else {
            return
        }
        snapshot.title = title
        titleSink?(title)
        await eventSink?(["kind": "sessionTitle", "title": title])
    }

    private func consumeSystemFrame(_ frame: SupermuxHarnessSystemFrame) {
        consumeTaskRecordFromSystemFrame(frame)
        switch frame.subtype {
        case .initialize:
            if let sessionID = frame.sessionID {
                snapshot.sessionId = sessionID
                // A fresh session's id first appears here; the watcher retries
                // until the CLI's first write creates the file.
                watchSessionFileForTitles()
            }
            if let model = frame.rawObject.string(forKey: "model") {
                snapshot.model = model
                // The init frame names the model the process is ACTUALLY
                // running — including after a /model slash command, which
                // emits a fresh init frame and never passes through
                // setModel(). This is the authoritative "model in use" signal,
                // so the machine-wide last-used default tracks it.
                recordModelUse(model: model)
            }
            if let mode = frame.rawObject.string(forKey: "permissionMode") {
                snapshot.permissionMode = mode
            }
        case .status:
            switch frame.rawObject.string(forKey: "status") {
            case "requesting", "compacting":
                // Queued messages drain into new turns with no send() on this
                // side; the pre-request status frame is their start signal.
                setTurnActive(true)
            default:
                break
            }
        case .sessionStateChanged:
            if let state = frame.rawObject.string(forKey: "state") {
                setTurnActive(state != "idle")
            }
        default:
            break
        }
    }

    private func consumeLifecycleEvent(_ event: SupermuxHarnessProcessLifecycleEvent) {
        switch event {
        case .started:
            break
        case .exited(let runID, let status):
            let router = controlRouter
            controlRouter = nil
            if let router {
                Task { @MainActor in
                    await router.close(denialMessage: Self.exitedDenialMessage)
                }
            }
            setTurnActive(false)
            emitPendingUserInputStateIfChanged()
            let previousDelivery = lifecycleEventDeliveryTask
            lifecycleEventDeliveryTask = Task { @MainActor [weak self] in
                await previousDelivery?.value
                await self?.eventSink?(["kind": "runExited", "runId": runID, "status": Int(status)])
            }
        }
    }

    private nonisolated static func normalizedRewindPreview(
        _ payload: SupermuxHarnessJSONObject
    ) -> [String: Any] {
        let raw = payload.rawValue
        return [
            "canRewind": payload.bool(forKey: "canRewind") ?? false,
            "filesChanged": raw["filesChanged"] as? [String] ?? [],
            "insertions": payload.integer(forKey: "insertions") ?? 0,
            "deletions": payload.integer(forKey: "deletions") ?? 0,
        ]
    }

    private nonisolated static func rewindFailureReason(
        from payload: SupermuxHarnessJSONObject
    ) -> String {
        normalized(payload.string(forKey: "reason"))
            ?? normalized(payload.string(forKey: "error"))
            ?? rewindFilesUnavailableMessage
    }

    private nonisolated static func rewindFailureReason(from error: any Error) -> String {
        if let routerError = error as? SupermuxHarnessControlRouterError,
           case .requestFailed(_, let message) = routerError,
           let message = normalized(message) {
            return message
        }
        return rewindFilesUnavailableMessage
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func claudeVersion(
        executablePath: String,
        environment: [String: String]
    ) async -> String? {
        let runner = AgentForkCommandOutputRunner(
            executable: executablePath,
            arguments: ["--version"],
            environment: environment,
            workingDirectory: nil
        )
        let output = await withTaskCancellationHandler {
            await runner.start()
        } onCancel: {
            runner.cancel()
        }
        return normalized(output)
    }

    private nonisolated static func suggestionPaths(from payload: [String: Any]) -> [String] {
        if let paths = payload["suggestions"] as? [String] {
            return paths
        }
        if let entries = payload["suggestions"] as? [[String: Any]] {
            return entries.compactMap { $0["path"] as? String ?? $0["display"] as? String }
        }
        return []
    }

    private nonisolated static var historyRecordLimit: Int { 400 }

    private nonisolated static var rewindFilesUnavailableMessage: String {
        String(
            localized: "supermux.harness.rewind.unavailable",
            defaultValue: "This session has no file checkpoints, so only the conversation can be rewound."
        )
    }

    private nonisolated static var defaultDenialMessage: String {
        String(
            localized: "supermux.harness.permission.defaultDenyMessage",
            defaultValue: "The user denied this tool use."
        )
    }

    private nonisolated static var closedDenialMessage: String {
        String(
            localized: "supermux.harness.permission.closedDenyMessage",
            defaultValue: "The pane was closed before this request was answered."
        )
    }

    private nonisolated static var stoppedDenialMessage: String {
        String(
            localized: "supermux.harness.permission.stoppedDenyMessage",
            defaultValue: "The session was stopped before this request was answered."
        )
    }

    private nonisolated static var exitedDenialMessage: String {
        String(
            localized: "supermux.harness.permission.exitedDenyMessage",
            defaultValue: "The Claude process exited before this request was answered."
        )
    }
}
