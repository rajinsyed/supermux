import CmuxCore
import Foundation
import SupermuxKit
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct SupermuxHarnessTests {
    @Test
    func testTrustedShellURLAcceptsOnlyMatchingFileURL() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = SupermuxHarnessWebRendererCoordinator.shellURL(resourceDirectoryURL: resources)
        let equivalent = resources
            .appendingPathComponent("supermux-harness", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("supermux-harness", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        let otherBundledFile = resources
            .appendingPathComponent("supermux-harness", isDirectory: true)
            .appendingPathComponent("other.html", isDirectory: false)

        #expect(SupermuxHarnessWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        #expect(SupermuxHarnessWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        #expect(!SupermuxHarnessWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        #expect(!SupermuxHarnessWebRendererCoordinator.isTrustedShellURL(
            URL(string: "https://example.com"),
            expected: expected
        ))
        #expect(!SupermuxHarnessWebRendererCoordinator.isTrustedShellURL(nil, expected: expected))
    }

    @Test
    func testHarnessSnapshotRoundTrip() throws {
        var snapshot = SessionSupermuxHarnessPanelSnapshot()
        snapshot.workingDirectory = "/Users/example/project"
        snapshot.sessionId = "8f14e45f-ceea-467f-a7f2-000000000001"
        snapshot.model = "claude-opus-4-6"
        snapshot.permissionMode = "acceptEdits"
        snapshot.title = "Fix sidebar flicker"

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSupermuxHarnessPanelSnapshot.self, from: data)

        #expect(decoded.workingDirectory == snapshot.workingDirectory)
        #expect(decoded.sessionId == snapshot.sessionId)
        #expect(decoded.model == snapshot.model)
        #expect(decoded.permissionMode == snapshot.permissionMode)
        #expect(decoded.title == snapshot.title)
    }

    @Test
    func testHarnessSnapshotDecodesEmptyObject() throws {
        let decoded = try JSONDecoder().decode(
            SessionSupermuxHarnessPanelSnapshot.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.workingDirectory == nil)
        #expect(decoded.sessionId == nil)
        #expect(decoded.model == nil)
        #expect(decoded.permissionMode == nil)
        #expect(decoded.title == nil)
    }

    @Test
    func testPanelTypeDecodesClaudeHarnessCaseInsensitively() throws {
        let exact = try JSONDecoder().decode(PanelType.self, from: Data("\"claudeHarness\"".utf8))
        #expect(exact == .claudeHarness)
        let lowercased = try JSONDecoder().decode(PanelType.self, from: Data("\"claudeharness\"".utf8))
        #expect(lowercased == .claudeHarness)
    }

    @MainActor
    @Test
    func testRemoteHarnessDirectoryCarriesTrustProvenance() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            sshRemoteConfiguration(command: sshCommand),
            autoConnect: false
        )
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let harnessPanel = try #require(workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: nil,
            focus: true
        ))

        #expect(harnessPanel.workingDirectory == remoteDirectory)
        #expect(workspace.remoteDirectoryReportPanelIds.contains(harnessPanel.id))
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(harnessPanel.id))
        let panelSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == harnessPanel.id }
        )
        #expect(panelSnapshot.directoryIsTrustedRemoteReport == true)
        #expect(panelSnapshot.directoryRequiresRemoteTrust == true)
    }

    @MainActor
    @Test
    func testTrustRequiredHarnessRestoreDoesNotUseSavedRemoteDirectoryAsLocal() throws {
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: "/Users/alice/development",
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            sshRemoteConfiguration(command: sshCommand),
            autoConnect: false
        )
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let harnessPanel = try #require(workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: nil,
            focus: true
        ))
        workspace.disconnectRemoteConnection()
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[harnessPanel.id])
        let restoredHarness = try #require(restored.panels[restoredPanelId] as? SupermuxHarnessPanel)
        #expect(restoredHarness.workingDirectory == nil)
        #expect(restored.panelDirectories[restoredPanelId] == remoteDirectory)
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == nil)
        #expect(restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))
    }

    @Test
    func testSessionPanelSnapshotCarriesClaudeHarnessField() throws {
        var harness = SessionSupermuxHarnessPanelSnapshot()
        harness.sessionId = "abc"
        let panelSnapshot = SessionPanelSnapshot(
            id: UUID(),
            type: .claudeHarness,
            title: "Claude",
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil,
            claudeHarness: harness
        )
        let data = try JSONEncoder().encode(panelSnapshot)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        #expect(decoded.type == .claudeHarness)
        #expect(decoded.claudeHarness?.sessionId == "abc")
    }

    @MainActor
    @Test
    func testRejectedFileRestoreReturnsDegradedReplyAndRestartsConversation() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session-original"
        restored.model = "opus"
        let process = MockSupermuxHarnessProcessSession()
        process.responses["rewind_files"] = .failure("checkpoint restore failed")
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process
        )
        defer { controller.close() }

        let reply = try await controller.rewind(
            userMessageUuid: "message-current",
            restoreFiles: true,
            resumeAtUuid: "message-previous"
        )

        #expect(reply["runId"] as? String == "run-2")
        #expect(reply["filesRestored"] as? Bool == false)
        #expect(reply["reason"] as? String == "checkpoint restore failed")
        let relevant = process.operations.filter { $0.isLifecycleOperation }
        #expect(relevant == [
            .start(runID: "run-1", resumeSessionID: "session-original", resumeSessionAt: nil),
            .terminateAndWait(runID: "run-1"),
            .start(
                runID: "run-2",
                resumeSessionID: "session-original",
                resumeSessionAt: "message-previous"
            ),
        ])
    }

    @MainActor
    @Test
    func testCanRewindFalseReturnsReasonAndStillRestartsConversation() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session-original"
        let process = MockSupermuxHarnessProcessSession()
        process.responses["rewind_files"] = .success([
            "canRewind": false,
            "reason": "file checkpoints are unavailable",
        ])
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process
        )
        defer { controller.close() }

        let reply = try await controller.rewind(
            userMessageUuid: "message-current",
            restoreFiles: true,
            resumeAtUuid: "message-previous"
        )

        #expect(reply["filesRestored"] as? Bool == false)
        #expect(reply["reason"] as? String == "file checkpoints are unavailable")
        #expect(reply["runId"] as? String == "run-2")
    }

    @MainActor
    @Test
    func testConversationOnlyRewindReturnsNoRestoreReason() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session-original"
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process
        )
        defer { controller.close() }

        let reply = try await controller.rewind(
            userMessageUuid: "message-current",
            restoreFiles: false,
            resumeAtUuid: "message-previous"
        )

        #expect(reply["runId"] as? String == "run-1")
        #expect(reply["filesRestored"] as? Bool == false)
        #expect(reply["reason"] == nil)
    }

    @MainActor
    @Test
    func testNoResumeRestartRetiresRestoredSessionBeforeInitialize() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session-old"
        restored.title = "Restored title"
        let panel = SupermuxHarnessPanel(
            workspaceId: UUID(),
            workingDirectory: "/tmp",
            restoreState: restored
        )
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process
        )
        controller.restoreStateRetirementSink = { [weak panel] in
            panel?.retireRestoreState()
        }
        defer {
            controller.close()
            panel.close()
        }

        _ = try await controller.restart(
            resumeSessionId: nil,
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )

        #expect(controller.snapshot.sessionId == nil)
        #expect(panel.currentSnapshot.sessionId == nil)
    }

    @MainActor
    @Test
    func testRestartClosesRouterThenAwaitsTerminationBeforeRelaunch() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: nil,
            defaults: defaults,
            process: process
        )
        defer { controller.close() }

        _ = try await controller.start(
            resumeSessionId: nil,
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )
        try process.emitPermissionRequest(requestID: "permission-1")
        _ = try await controller.restart(
            resumeSessionId: nil,
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )

        let permissionIndex = try #require(
            process.operations.firstIndex(of: .permissionResponse(requestID: "permission-1"))
        )
        let terminationIndex = try #require(
            process.operations.firstIndex(of: .terminateAndWait(runID: "run-1"))
        )
        let relaunchIndex = try #require(
            process.operations.firstIndex {
                if case .start(let runID, _, _) = $0 { return runID == "run-2" }
                return false
            }
        )
        #expect(permissionIndex < terminationIndex)
        #expect(terminationIndex < relaunchIndex)
    }

    @MainActor
    @Test
    func testBinaryInvalidationBroadcastsToEveryLiveController() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let first = makeController(
            restoreState: nil,
            defaults: defaults,
            process: MockSupermuxHarnessProcessSession()
        )
        let second = makeController(
            restoreState: nil,
            defaults: defaults,
            process: MockSupermuxHarnessProcessSession()
        )
        defer {
            first.close()
            second.close()
        }

        #expect(await first.cliStatus()["path"] as? String == "/usr/bin/true")
        #expect(await second.cliStatus()["path"] as? String == "/usr/bin/true")
        _ = try await first.setBinaryPath("/usr/bin/false")

        #expect(await second.cliStatus()["path"] as? String == "/usr/bin/false")
    }

    @MainActor
    @Test
    func testColdControllersShareOneModelCatalogProbePerBinaryPath() async throws {
        let firstDefaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        let secondDefaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer {
            clearHarnessDefaults(firstDefaults)
            clearHarnessDefaults(secondDefaults)
        }
        var probeCount = 0
        let catalog = SupermuxHarnessInitializeCatalog(
            response: try SupermuxHarnessJSONObject(rawValue: [
                "models": [["value": "opus", "displayName": "Opus"]],
            ])
        )
        let probe: @MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog = { _ in
            probeCount += 1
            return catalog
        }
        let first = makeController(
            restoreState: nil,
            defaults: firstDefaults,
            process: MockSupermuxHarnessProcessSession(),
            modelCatalogProbe: probe
        )
        let second = makeController(
            restoreState: nil,
            defaults: secondDefaults,
            process: MockSupermuxHarnessProcessSession(),
            modelCatalogProbe: probe
        )
        defer {
            first.close()
            second.close()
        }
        let firstCatalogEvent = AsyncStream.makeStream(of: [String: Any].self)
        let secondCatalogEvent = AsyncStream.makeStream(of: [String: Any].self)
        first.eventSink = { event in
            guard event["kind"] as? String == "modelCatalog" else { return }
            firstCatalogEvent.continuation.yield(event)
            firstCatalogEvent.continuation.finish()
        }
        second.eventSink = { event in
            guard event["kind"] as? String == "modelCatalog" else { return }
            secondCatalogEvent.continuation.yield(event)
            secondCatalogEvent.continuation.finish()
        }

        _ = await first.contextBootstrap()
        _ = await second.contextBootstrap()
        let firstEvent = await firstCatalogEvent.stream.first(where: { _ in true })
        let secondEvent = await secondCatalogEvent.stream.first(where: { _ in true })

        #expect(firstEvent?["models"] != nil)
        #expect(secondEvent?["models"] != nil)
        #expect(probeCount == 1)
    }

    @Test
    func testBinaryOverrideRejectsRelativeExecutablePath() throws {
        let defaults = try makeHarnessDefaults(executablePath: nil)
        defer { clearHarnessDefaults(defaults) }
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let parentCount = max(0, currentDirectory.pathComponents.count - 1)
        let relativeExecutable = String(repeating: "../", count: parentCount) + "usr/bin/true"
        #expect(
            URL(fileURLWithPath: relativeExecutable).standardizedFileURL.path == "/usr/bin/true"
        )
        let setting = SupermuxHarnessBinarySetting(defaults: defaults, fileManager: .default)

        do {
            _ = try setting.setPath(relativeExecutable)
            Issue.record("Expected a relative executable path to be rejected")
        } catch let error as SupermuxHarnessBridgeError {
            #expect(error.code == "invalidBinaryPath")
        }
    }

    @MainActor
    private func makeController(
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        defaults: UserDefaults,
        process: MockSupermuxHarnessProcessSession,
        modelCatalogProbe: (@MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog)? = nil
    ) -> SupermuxHarnessSessionController {
        SupermuxHarnessSessionController(
            workingDirectory: "/tmp",
            restoreState: restoreState,
            defaults: defaults,
            modelCatalogProbe: modelCatalogProbe,
            processSessionFactory: { protocolLineSink, stderrSink, lifecycleSink in
                process.configure(
                    protocolLineSink: protocolLineSink,
                    stderrSink: stderrSink,
                    lifecycleSink: lifecycleSink
                )
                return process
            }
        )
    }

    private func makeHarnessDefaults(executablePath: String?) throws -> UserDefaults {
        let suiteName = "SupermuxHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(suiteName, forKey: MockSupermuxHarnessProcessSession.defaultsSuiteMarkerKey)
        if let executablePath {
            defaults.set(executablePath, forKey: SupermuxHarnessBinarySetting.defaultsKey)
        }
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: MockSupermuxHarnessProcessSession.defaultsSuiteMarkerKey)
    }

    private func clearHarnessDefaults(_ defaults: UserDefaults) {
        guard let suiteName = defaultsSuiteName(defaults) else { return }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func sshRemoteConfiguration(command: String) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "seepine@192.168.5.20",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-harness-\(UUID().uuidString).sock",
            terminalStartupCommand: command
        )
    }
}

@MainActor
private final class MockSupermuxHarnessProcessSession: SupermuxHarnessProcessSessionProtocol {
    nonisolated static let defaultsSuiteMarkerKey = "SupermuxHarnessTests.defaultsSuiteName"

    enum Response {
        case success([String: Any])
        case failure(String)
    }

    enum Operation: Equatable {
        case start(runID: String, resumeSessionID: String?, resumeSessionAt: String?)
        case control(subtype: String)
        case permissionResponse(requestID: String)
        case terminate(runID: String)
        case terminateAndWait(runID: String)
        case close(runID: String?)

        var isLifecycleOperation: Bool {
            switch self {
            case .start, .terminateAndWait:
                true
            default:
                false
            }
        }
    }

    private(set) var isRunning = false
    private(set) var activeRunID: String?
    var responses: [String: Response] = [:]
    private(set) var operations: [Operation] = []

    private var protocolLineSink: SupermuxHarnessProtocolLineSink?
    private var stderrSink: SupermuxHarnessStderrSink?
    private var lifecycleSink: SupermuxHarnessLifecycleSink?
    private let decoder = SupermuxHarnessProtocolDecoder()
    private var nextRunNumber = 1

    func configure(
        protocolLineSink: @escaping SupermuxHarnessProtocolLineSink,
        stderrSink: @escaping SupermuxHarnessStderrSink,
        lifecycleSink: @escaping SupermuxHarnessLifecycleSink
    ) {
        self.protocolLineSink = protocolLineSink
        self.stderrSink = stderrSink
        self.lifecycleSink = lifecycleSink
    }

    func start(plan: SupermuxHarnessLaunchPlan) throws -> SupermuxHarnessStartedProcess {
        guard !isRunning else { throw SupermuxHarnessProcessError.alreadyRunning }
        let runID = "run-\(nextRunNumber)"
        nextRunNumber += 1
        isRunning = true
        activeRunID = runID
        operations.append(.start(
            runID: runID,
            resumeSessionID: plan.arguments.value(after: "--resume"),
            resumeSessionAt: plan.arguments.first {
                $0.hasPrefix("--resume-session-at=")
            }?.replacingOccurrences(of: "--resume-session-at=", with: "")
        ))
        lifecycleSink?(.started(runID: runID, processID: Int32(nextRunNumber)))
        return SupermuxHarnessStartedProcess(runID: runID, processID: Int32(nextRunNumber))
    }

    func send(_ frame: SupermuxHarnessEncodedFrame) async throws {
        try await handle(frame, expectedRunID: nil)
    }

    func send(_ frame: SupermuxHarnessEncodedFrame, forRunID runID: String) async throws {
        try await handle(frame, expectedRunID: runID)
    }

    func terminate() throws {
        guard let runID = activeRunID else { throw SupermuxHarnessProcessError.notRunning }
        operations.append(.terminate(runID: runID))
        finish(runID: runID)
    }

    func terminateAndWait(timeout: TimeInterval) async throws -> Int32 {
        _ = timeout
        guard let runID = activeRunID else { throw SupermuxHarnessProcessError.notRunning }
        operations.append(.terminateAndWait(runID: runID))
        finish(runID: runID)
        return 0
    }

    func close() {
        operations.append(.close(runID: activeRunID))
        guard let runID = activeRunID else { return }
        finish(runID: runID)
    }

    func emitPermissionRequest(requestID: String) throws {
        try emit([
            "type": "control_request",
            "request_id": requestID,
            "request": [
                "subtype": "can_use_tool",
                "tool_name": "Edit",
                "input": ["file_path": "/tmp/example"],
            ],
        ])
    }

    private func handle(
        _ frame: SupermuxHarnessEncodedFrame,
        expectedRunID: String?
    ) async throws {
        guard isRunning,
              expectedRunID == nil || activeRunID == expectedRunID else {
            throw SupermuxHarnessProcessError.notRunning
        }
        let object = try frame.jsonObject()
        if object.string(forKey: "type") == "control_response" {
            let requestID = object.object(forKey: "response")?.string(forKey: "request_id") ?? ""
            operations.append(.permissionResponse(requestID: requestID))
            return
        }
        guard object.string(forKey: "type") == "control_request",
              let requestID = object.string(forKey: "request_id"),
              let subtype = object.object(forKey: "request")?.string(forKey: "subtype") else {
            return
        }
        operations.append(.control(subtype: subtype))
        switch responses[subtype] ?? .success([:]) {
        case .success(let payload):
            try emit([
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": requestID,
                    "response": payload,
                ],
            ])
        case .failure(let message):
            try emit([
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestID,
                    "response": ["error": message],
                ],
            ])
        }
    }

    private func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let line = try #require(String(data: data, encoding: .utf8))
        protocolLineSink?(try decoder.decodeLine(line))
    }

    private func finish(runID: String) {
        guard activeRunID == runID else { return }
        isRunning = false
        activeRunID = nil
        lifecycleSink?(.exited(runID: runID, status: 0))
    }
}

private extension Array where Element == String {
    func value(after argument: String) -> String? {
        guard let index = firstIndex(of: argument) else { return nil }
        let valueIndex = index + 1
        guard indices.contains(valueIndex) else { return nil }
        return self[valueIndex]
    }
}
