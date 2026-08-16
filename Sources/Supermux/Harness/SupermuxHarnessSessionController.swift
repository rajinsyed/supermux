import Foundation
import SupermuxKit

/// Drives one SupermuxKit Claude harness process for a panel: launch, protocol
/// forwarding, control routing, permission fail-safety, and persisted state.
@MainActor
final class SupermuxHarnessSessionController {
    var eventSink: (([String: Any]) -> Void)?
    var runningStateSink: ((Bool) -> Void)?
    var titleSink: ((String?) -> Void)?

    private(set) var workingDirectory: String?
    private(set) var snapshot = SessionSupermuxHarnessPanelSnapshot()
    var composerDraft: String?

    private var processSession: SupermuxHarnessProcessSession!
    private var controlRouter: SupermuxHarnessControlRouter?
    private let encoder = SupermuxHarnessProtocolEncoder()
    private var isClosed = false
    private var isStartPending = false
    private var cachedCLIStatus: [String: Any]?

    init(workingDirectory: String?, restoreState: SessionSupermuxHarnessPanelSnapshot?) {
        self.workingDirectory = workingDirectory ?? restoreState?.workingDirectory
        if var restored = restoreState {
            restored.workingDirectory = self.workingDirectory
            snapshot = restored
        } else {
            snapshot.workingDirectory = self.workingDirectory
        }
        processSession = SupermuxHarnessProcessSession(
            protocolLineSink: { [weak self] line in
                self?.consumeProtocolLine(line)
            },
            stderrSink: { [weak self] text in
                self?.eventSink?(["kind": "stderr", "text": text])
            },
            lifecycleSink: { [weak self] event in
                self?.consumeLifecycleEvent(event)
            }
        )
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
        let configuredExecutablePaths = AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        let status: [String: Any] = await Task.detached(priority: .userInitiated) {
            let resolver = AgentExecutableResolver(configuredExecutablePaths: configuredExecutablePaths)
            do {
                let plan = try resolver.resolve(.claude)
                return ["available": true, "path": plan.executableURL.path]
            } catch let error as AgentExecutableResolverError {
                return ["available": false, "error": error.message]
            } catch {
                return ["available": false, "error": error.localizedDescription]
            }
        }.value
        cachedCLIStatus = status
        return status
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
        guard let directoryPath = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directoryPath.isEmpty else {
            throw SupermuxHarnessBridgeError.workingDirectoryUnavailable
        }
        isStartPending = true
        defer { isStartPending = false }

        let configuredExecutablePaths = AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        let resolvedPlan = try await Task.detached(priority: .userInitiated) {
            let resolver = AgentExecutableResolver(configuredExecutablePaths: configuredExecutablePaths)
            return try resolver.resolve(.claude)
        }.value
        guard !isClosed, !processSession.isRunning else {
            throw SupermuxHarnessBridgeError.sessionAlreadyRunning
        }

        var options = SupermuxHarnessLaunchOptions()
        options.model = model
        options.permissionMode = permissionMode.flatMap(SupermuxHarnessPermissionMode.init(rawValue:))
        options.resumeSessionID = resumeSessionId
        options.forkSession = forkSession
        options.effort = effort
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: resolvedPlan.executableURL,
            workingDirectoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            environment: resolvedPlan.environment,
            options: options
        )

        let router = SupermuxHarnessControlRouter(sender: { [weak self] frame in
            guard let self else { throw SupermuxHarnessProcessError.notRunning }
            try await self.processSession.send(frame)
        })
        controlRouter = router

        let started: SupermuxHarnessStartedProcess
        do {
            started = try processSession.start(plan: plan)
        } catch {
            controlRouter = nil
            throw SupermuxHarnessBridgeError.startFailed(error.localizedDescription)
        }

        if let model { snapshot.model = model }
        if let permissionMode { snapshot.permissionMode = permissionMode }
        if let resumeSessionId, !forkSession { snapshot.sessionId = resumeSessionId }
        runningStateSink?(true)
        var event: [String: Any] = ["kind": "runStarted", "runId": started.runID]
        if let resumeSessionId { event["resumedSessionId"] = resumeSessionId }
        eventSink?(event)
        Task { @MainActor [weak router] in
            _ = try? await router?.issue(.initialize)
        }
        return started.runID
    }

    func send(text: String, images: [SupermuxHarnessImage], uuid: String) async throws {
        guard processSession.isRunning else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        let frame = try encoder.userMessage(text: text, images: images, uuid: uuid)
        try await processSession.send(frame)
    }

    func interrupt(cancelQueued: Bool) async throws {
        guard let controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await controlRouter.issue(.interrupt(cancelQueued: cancelQueued))
    }

    func cancelQueued(messageUuid: String) async throws {
        guard let controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await controlRouter.issue(.cancelAsyncMessage(messageUUID: messageUuid))
    }

    func stop() async {
        if let controlRouter {
            await controlRouter.close(denialMessage: Self.stoppedDenialMessage)
            self.controlRouter = nil
        }
        try? processSession.terminate()
    }

    func setModel(model: String, effort: String?) async throws {
        guard let controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        _ = try await controlRouter.issue(.setModel(model: model, effort: effort))
        snapshot.model = model
    }

    func setPermissionMode(_ mode: String) async throws {
        guard let permissionMode = SupermuxHarnessPermissionMode(rawValue: mode) else {
            throw SupermuxHarnessBridgeError.missingParameter("mode")
        }
        guard let controlRouter else {
            snapshot.permissionMode = mode
            return
        }
        _ = try await controlRouter.issue(.setPermissionMode(permissionMode))
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
        do {
            try await controlRouter.respondToPermission(requestID: requestId, decision: decision)
        } catch SupermuxHarnessControlRouterError.permissionRequestNotFound {
            throw SupermuxHarnessBridgeError.permissionRequestNotFound
        }
    }

    func renameSession(title: String) async throws {
        guard let controlRouter else {
            snapshot.title = title
            titleSink?(title)
            return
        }
        _ = try await controlRouter.issue(.renameSession(title: title))
        snapshot.title = title
        titleSink?(title)
    }

    func getContextUsage() async throws -> [String: Any] {
        guard let controlRouter else { throw SupermuxHarnessBridgeError.sessionNotRunning }
        return try await controlRouter.issue(.getContextUsage).rawValue
    }

    func fileSuggestions(query: String) async -> [String: Any] {
        guard let controlRouter, processSession.isRunning else { return ["paths": []] }
        guard let payload = try? await controlRouter.issue(.fileSuggestions(query: query)) else {
            return ["paths": []]
        }
        var result = payload.rawValue
        if result["paths"] == nil {
            result["paths"] = Self.suggestionPaths(from: result)
        }
        return result
    }

    func listSessions(limit: Int?) throws -> [[String: Any]] {
        guard let directoryURL = workingDirectoryURL else { return [] }
        let discovery = makeDiscovery()
        let sessions = try discovery.listSessions(for: directoryURL, limit: limit)
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

    func loadSessionHistory(sessionId: String) throws -> [String: Any] {
        guard let directoryURL = workingDirectoryURL else {
            throw SupermuxHarnessBridgeError.workingDirectoryUnavailable
        }
        let discovery = makeDiscovery()
        let page = try discovery.loadHistory(
            for: directoryURL,
            sessionID: sessionId,
            recordLimit: Self.historyRecordLimit
        )
        return [
            "events": page.events.map(\.rawValue),
            "truncated": page.truncated,
        ]
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let router = controlRouter
        controlRouter = nil
        if let router {
            Task { @MainActor in
                await router.close(denialMessage: Self.closedDenialMessage)
            }
        }
        processSession.close()
    }

    private var workingDirectoryURL: URL? {
        guard let path = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeDiscovery() -> SupermuxHarnessSessionDiscovery {
        SupermuxHarnessSessionDiscovery(
            projectsRootURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true),
            fileManager: .default
        )
    }

    private func consumeProtocolLine(_ line: SupermuxHarnessDecodedLine) {
        controlRouter?.consume(line)
        if case .system(let frame)? = line.frame {
            consumeSystemFrame(frame)
        }
        eventSink?(["kind": "protocol", "line": line.object.rawValue])
    }

    private func consumeSystemFrame(_ frame: SupermuxHarnessSystemFrame) {
        switch frame.subtype {
        case .initialize:
            if let sessionID = frame.sessionID {
                snapshot.sessionId = sessionID
            }
            if let model = frame.rawObject.string(forKey: "model") {
                snapshot.model = model
            }
            if let mode = frame.rawObject.string(forKey: "permissionMode") {
                snapshot.permissionMode = mode
            }
        case .sessionStateChanged:
            if let state = frame.rawObject.string(forKey: "state") {
                runningStateSink?(state != "idle")
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
            runningStateSink?(false)
            eventSink?(["kind": "runExited", "runId": runID, "status": Int(status)])
        }
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
