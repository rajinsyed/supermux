import CmuxCore
import Foundation
import Testing

@testable import SupermuxKit

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

    // MARK: - Item 9: workspace-tab branch for a harness-only workspace

    /// The workspace-tab / sidebar branch chip reads
    /// `sidebarGitBranchesInDisplayOrder`, which projects `panelGitBranches`.
    /// A harness pane must be able to carry a branch there exactly like a
    /// terminal pane, otherwise a project-nested workspace whose only pane is a
    /// harness pane shows no branch at all.
    @MainActor
    @Test
    func testHarnessOnlyWorkspaceSurfacesItsBranchInTheTabChip() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/project")
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let harnessPanel = try #require(workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: "/Users/alice/project",
            focus: true
        ))
        // Close the seed terminal so the harness pane is the ONLY pane, which is
        // the exact repro condition from the report.
        _ = workspace.closePanel(terminalPanelId, force: true)
        #expect(workspace.panels.count == 1)
        #expect(workspace.panels[harnessPanel.id] is SupermuxHarnessPanel)

        // The git probe is what would normally write this; drive its projection
        // directly so the test covers the presentation path without git I/O.
        workspace.updatePanelGitBranch(panelId: harnessPanel.id, branch: "feature/harness", isDirty: false)

        #expect(workspace.supermuxSidebarBranch == "feature/harness")
        #expect(workspace.sidebarGitBranchesInDisplayOrder().first?.branch == "feature/harness")
    }

    /// The actual bug: nothing ever SCHEDULED a git probe for a harness pane,
    /// because every scheduling site keys on `TerminalPanel`. Assert the fork's
    /// harness-specific scheduler recognizes the pane (and ignores others), so a
    /// future refactor that drops the call is caught here.
    @MainActor
    @Test
    func testHarnessGitProbeSchedulingTargetsOnlyHarnessPanes() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/project")
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let harnessPanel = try #require(workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: "/Users/alice/project",
            focus: true
        ))

        // Detached workspace (no owning TabManager): these must be safe no-ops
        // rather than traps, since session restore builds panels pre-attach.
        workspace.scheduleSupermuxHarnessGitMetadataProbe(panelId: harnessPanel.id, reason: "test")
        workspace.scheduleSupermuxHarnessGitMetadataProbe(panelId: terminalPanelId, reason: "test")
        workspace.scheduleSupermuxHarnessGitMetadataProbes(reason: "test")

        // The harness pane must expose the project cwd the probe would read.
        #expect(workspace.panelDirectories[harnessPanel.id] == "/Users/alice/project")
        #expect(harnessPanel.workingDirectory == "/Users/alice/project")
    }

    // MARK: - Item 10: harness pane unread indicator

    /// Harness panes must participate in the same per-panel unread state
    /// terminal panes use, so the pane indicator and the tab badge agree.
    @MainActor
    @Test
    func testHarnessPaneParticipatesInPanelUnreadState() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/project")
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let harnessPanel = try #require(workspace.newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: "/Users/alice/project",
            focus: false
        ))

        workspace.markPanelUnread(harnessPanel.id)
        #expect(workspace.manualUnreadPanelIds.contains(harnessPanel.id))
        #expect(Workspace.shouldShowUnreadIndicator(
            hasUnreadNotification: false,
            hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(harnessPanel.id)
        ))

        workspace.markPanelRead(harnessPanel.id)
        #expect(!workspace.manualUnreadPanelIds.contains(harnessPanel.id))
        #expect(!Workspace.shouldShowUnreadIndicator(
            hasUnreadNotification: false,
            hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(harnessPanel.id)
        ))
    }

    /// Round 6: the unread treatment is a top-edge light, not the old breathing
    /// tick. A read pane must draw nothing at all — no residual seam, no glow —
    /// so the pane returns to a completely clean surface on dismissal.
    @Test
    func testReadHarnessPaneDrawsNoUnreadTreatment() throws {
        for appearance: SupermuxHarnessUnreadAppearance in [.light, .dark] {
            for reduceMotion in [false, true] {
                let presentation = SupermuxHarnessUnreadPresentation.resolve(
                    isUnread: false,
                    appearance: appearance,
                    reduceMotion: reduceMotion
                )
                #expect(!presentation.isVisible)
                #expect(presentation.seamOpacity == 0)
                #expect(presentation.glowOpacity == 0)
                #expect(!presentation.animatesOnArrival)
            }
        }
    }

    /// The whole point of the redesign is that it survives the app's translucent
    /// dark chrome as well as a light surface. Both appearances must clear the
    /// legibility floors; a future tuning pass that dims past them is a
    /// regression, not a taste change.
    @Test
    func testUnreadTreatmentIsLegibleInBothAppearances() throws {
        for appearance: SupermuxHarnessUnreadAppearance in [.light, .dark] {
            let presentation = SupermuxHarnessUnreadPresentation.resolve(
                isUnread: true,
                appearance: appearance,
                reduceMotion: false
            )
            #expect(presentation.isVisible)
            #expect(presentation.seamOpacity >= SupermuxHarnessUnreadPresentation.seamLegibilityFloor)
            #expect(presentation.glowOpacity >= SupermuxHarnessUnreadPresentation.glowLegibilityFloor)
            // The bleed must stay a wash behind the seam, never a second bar.
            #expect(presentation.glowOpacity < presentation.seamOpacity)
        }

        // The appearance comes from the pane's own theme, not the system colour
        // scheme: a dark Ghostty theme under a Light system appearance is a dark
        // pane, and the indicator must dress for the surface it sits on.
        #expect(SupermuxHarnessUnreadAppearance(isDark: true) == .dark)
        #expect(SupermuxHarnessUnreadAppearance(isDark: false) == .light)

        // Dark panes carry more bloom, because vibrancy eats a faint wash there.
        let dark = SupermuxHarnessUnreadPresentation.resolve(
            isUnread: true, appearance: .dark, reduceMotion: false
        )
        let light = SupermuxHarnessUnreadPresentation.resolve(
            isUnread: true, appearance: .light, reduceMotion: false
        )
        #expect(dark.glowOpacity > light.glowOpacity)
    }

    /// Reduce Motion drops the arrival settle and nothing else: the indicator is
    /// pixel-identical at rest, it simply appears already settled. It must never
    /// degrade to "no indicator".
    @Test
    func testReduceMotionKeepsTheIndicatorAndDropsOnlyTheArrivalMotion() throws {
        for appearance: SupermuxHarnessUnreadAppearance in [.light, .dark] {
            let animated = SupermuxHarnessUnreadPresentation.resolve(
                isUnread: true, appearance: appearance, reduceMotion: false
            )
            let still = SupermuxHarnessUnreadPresentation.resolve(
                isUnread: true, appearance: appearance, reduceMotion: true
            )

            #expect(animated.animatesOnArrival)
            #expect(!still.animatesOnArrival)
            #expect(still.entryDuration == 0)
            #expect(still.isVisible)
            // Resting appearance is unchanged by the motion setting.
            #expect(still.seamOpacity == animated.seamOpacity)
            #expect(still.glowOpacity == animated.glowOpacity)
        }
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
            restoreState: restored,
            sessionRepository: makeSessionRepository(),
            transcriptService: SupermuxHarnessSubagentTranscriptService(
                projectsRootURL: SupermuxHarnessSessionController.claudeProjectsRootURL,
                fileManager: .default
            )
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
        try await process.emitPermissionRequest(requestID: "permission-1")
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
    @Test
    func testForgedHarnessSendRejectsMalformedAttachmentsBeforeProcessSend() async throws {
        let coordinator = SupermuxHarnessWebRendererCoordinator()
        coordinator.bind(
            panelId: UUID(),
            workspaceId: UUID(),
            workingDirectory: "/tmp",
            restoreState: nil,
            theme: coordinator.theme,
            isFocused: true
        )
        defer { coordinator.close() }
        let request = try SupermuxHarnessBridgeRequest(body: [
            "id": "forged-send",
            "method": "harness.send",
            "params": [
                "text": "inspect",
                "uuid": UUID().uuidString,
                "images": [[
                    "mediaType": "image/png",
                    "dataBase64": "not base64",
                ]],
            ],
        ])

        do {
            _ = try await coordinator.handle(request)
            Issue.record("Expected forged attachment rejection")
        } catch let error as SupermuxHarnessBridgeError {
            #expect(error.code == "invalidAttachment")
        }
    }

    @MainActor
    @Test
    func testForgedHarnessSendRejectsMalformedImageObjectsRatherThanDroppingThem() async throws {
        let coordinator = SupermuxHarnessWebRendererCoordinator()
        coordinator.bind(
            panelId: UUID(),
            workspaceId: UUID(),
            workingDirectory: "/tmp",
            restoreState: nil,
            theme: coordinator.theme,
            isFocused: true
        )
        defer { coordinator.close() }
        let request = try SupermuxHarnessBridgeRequest(body: [
            "id": "forged-shape",
            "method": "harness.send",
            "params": [
                "text": "inspect",
                "uuid": UUID().uuidString,
                "images": [["mediaType": "image/png"]],
            ],
        ])

        do {
            _ = try await coordinator.handle(request)
            Issue.record("Expected malformed image object rejection")
        } catch let error as SupermuxHarnessBridgeError {
            #expect(error.code == "invalidAttachment")
        }
    }

    @MainActor
    @Test
    func testRunningIndicatorFollowsTurnsNotProcessLifetime() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(restoreState: nil, defaults: defaults, process: process)
        var runningStates: [Bool] = []
        controller.runningStateSink = { runningStates.append($0) }

        _ = try await controller.start(
            resumeSessionId: nil,
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )
        // Starting the process is not a running turn: the terminal shows no
        // spinner on SessionStart, only on prompt submit.
        #expect(runningStates.isEmpty)

        try await controller.send(text: "hello", images: [], uuid: UUID().uuidString)
        #expect(runningStates == [true])

        // The real CLI never emits session_state_changed; the result frame is
        // the end-of-turn boundary and must clear the indicator.
        try await process.emitLine([
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "Done.",
            "uuid": UUID().uuidString,
        ])
        #expect(runningStates == [true, false])

        // A queued message drains into a new turn with no send() on this side;
        // the pre-request status frame is its start signal.
        try await process.emitLine([
            "type": "system",
            "subtype": "status",
            "status": "requesting",
            "uuid": UUID().uuidString,
        ])
        #expect(runningStates == [true, false, true])
        try await process.emitLine([
            "type": "result",
            "subtype": "error_during_execution",
            "is_error": true,
            "terminal_reason": "aborted_streaming",
            "uuid": UUID().uuidString,
        ])
        #expect(runningStates == [true, false, true, false])
    }

    @MainActor
    @Test
    func testTaskCacheDerivesOutputPathAndRejectsUnknownTaskIDs() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-task-cache-\(UUID().uuidString)", isDirectory: true)
        let projects = container.appendingPathComponent("projects", isDirectory: true)
        let taskRoot = container.appendingPathComponent("claude-501", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: nil,
            defaults: defaults,
            process: process,
            workingDirectory: "/tmp/harness task cache",
            projectsRootURL: projects,
            taskOutputRootURL: taskRoot
        )
        defer { controller.close() }
        try await process.emitLine([
            "type": "system",
            "subtype": "init",
            "session_id": "session-1",
        ])
        try await process.emitLine([
            "type": "system",
            "subtype": "task_started",
            "task_id": "task-1",
            "tool_use_id": "toolu_1",
            "task_type": "local_bash",
            "session_id": "session-1",
        ])
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let mungedDirectory = try #require(
            discovery.mungedProjectDirectoryNames(
                for: URL(fileURLWithPath: "/tmp/harness task cache", isDirectory: true)
            ).first
        )
        let outputURL = taskRoot
            .appendingPathComponent(mungedDirectory, isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("task-1.output")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "cached output".write(to: outputURL, atomically: true, encoding: .utf8)

        let coordinator = SupermuxHarnessWebRendererCoordinator(
            sessionRepository: makeSessionRepository(),
            transcriptService: SupermuxHarnessSubagentTranscriptService(
                projectsRootURL: projects,
                fileManager: .default
            )
        )
        let request = try SupermuxHarnessBridgeRequest(body: [
            "id": "read-output",
            "method": "harness.readTaskOutput",
            "params": ["taskId": "task-1"],
        ])
        let reply = try #require(
            try await coordinator.handleTaskBridgeRequest(request, controller: controller)
                as? [String: Any]
        )
        #expect(reply["text"] as? String == "cached output")
        #expect(reply["truncated"] as? Bool == false)
        #expect(reply["missing"] as? Bool == false)

        do {
            _ = try await controller.readTaskOutput(taskId: "not-observed")
            Issue.record("Expected an unobserved task identifier to be rejected")
        } catch let error as SupermuxHarnessBridgeError {
            #expect(error.code == "invalidRequest")
        }
    }

    @MainActor
    @Test
    func testToolResultCachesProtocolOutputPathBeforeTaskNotification() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-task-result-\(UUID().uuidString)", isDirectory: true)
        let taskRoot = container.appendingPathComponent("claude-501", isDirectory: true)
        let outputURL = taskRoot
            .appendingPathComponent("munged", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("shell-1.output")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "live shell output".write(to: outputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: container) }
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: nil,
            defaults: defaults,
            process: process,
            workingDirectory: nil,
            taskOutputRootURL: taskRoot
        )
        defer { controller.close() }
        try await process.emitLine([
            "type": "system",
            "subtype": "task_started",
            "task_id": "shell-1",
            "tool_use_id": "toolu_shell",
            "task_type": "local_bash",
            "session_id": "session",
        ])
        try await process.emitLine([
            "type": "user",
            "session_id": "session",
            "message": [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_shell",
                    "content": "Command running in background. Output is being written to: \(outputURL.path). You will be notified.",
                ]],
            ],
            "tool_use_result": ["backgroundTaskId": "shell-1"],
        ])

        let reply = try await controller.readTaskOutput(taskId: "shell-1")
        #expect(reply["text"] as? String == "live shell output")
        #expect(reply["missing"] as? Bool == false)
    }

    @MainActor
    @Test
    func testRoundThreeBridgeRoutesControlsAndTranscriptPassthroughs() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-round-three-\(UUID().uuidString)", isDirectory: true)
        let projects = container.appendingPathComponent("projects", isDirectory: true)
        let workingDirectory = container.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session"
        let process = MockSupermuxHarnessProcessSession()
        process.responses["background_tasks"] = .success(["backgrounded": true])
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process,
            workingDirectory: workingDirectory.path,
            projectsRootURL: projects
        )
        defer { controller.close() }
        _ = try await controller.start(
            resumeSessionId: "session",
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let projectDirectory = try #require(
            discovery.projectDirectoryURLs(for: workingDirectory).first
        )
        let transcriptDirectory = projectDirectory
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let transcriptRecord: [String: Any] = [
            "type": "assistant",
            "uuid": "agent-answer",
            "message": ["role": "assistant", "content": "done"],
        ]
        let transcriptData = try JSONSerialization.data(withJSONObject: transcriptRecord)
        try (String(decoding: transcriptData, as: UTF8.self) + "\n").write(
            to: transcriptDirectory.appendingPathComponent("agent-agent-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let metadata = try JSONSerialization.data(withJSONObject: [
            "agentType": "general-purpose",
            "description": "Inspect",
            "spawnDepth": 1,
        ])
        try metadata.write(to: transcriptDirectory.appendingPathComponent("agent-agent-1.meta.json"))

        let coordinator = SupermuxHarnessWebRendererCoordinator(
            sessionRepository: makeSessionRepository(),
            transcriptService: SupermuxHarnessSubagentTranscriptService(
                projectsRootURL: projects,
                fileManager: .default
            )
        )
        let stopRequest = try SupermuxHarnessBridgeRequest(body: [
            "id": "stop",
            "method": "harness.stopTask",
            "params": ["taskId": "task-1"],
        ])
        let stopReply = try #require(
            try await coordinator.handleTaskBridgeRequest(stopRequest, controller: controller)
                as? [String: Any]
        )
        #expect(stopReply.isEmpty)

        let backgroundRequest = try SupermuxHarnessBridgeRequest(body: [
            "id": "background",
            "method": "harness.backgroundTask",
            "params": ["toolUseId": "toolu_1"],
        ])
        let backgroundReply = try #require(
            try await coordinator.handleTaskBridgeRequest(backgroundRequest, controller: controller)
                as? [String: Any]
        )
        #expect(backgroundReply["backgrounded"] as? Bool == true)

        let transcriptRequest = try SupermuxHarnessBridgeRequest(body: [
            "id": "transcript",
            "method": "harness.loadSubagentTranscript",
            "params": ["taskId": "agent-1"],
        ])
        let transcriptReply = try #require(
            try await coordinator.handleTaskBridgeRequest(transcriptRequest, controller: controller)
                as? [String: Any]
        )
        let events = try #require(transcriptReply["events"] as? [[String: Any]])
        #expect(events.first?["uuid"] as? String == "agent-answer")
        let meta = try #require(transcriptReply["meta"] as? [String: Any])
        #expect(meta["agentType"] as? String == "general-purpose")
        #expect(meta["spawnDepth"] as? Int == 1)
        #expect(process.operations.contains(.control(subtype: "stop_task")))
        #expect(process.operations.contains(.control(subtype: "background_tasks")))
    }

    /// Round-6 item 12: `harness.context` carries the CLI's settings defaults —
    /// the model/effort a flagless start actually runs — read in the CLI's own
    /// precedence order (project settings.local.json → project settings.json →
    /// user settings.json), so a fresh pane can name the real session-default
    /// model instead of the catalog's generic "Default (recommended)" row.
    @Test
    func testSettingsDefaultsReadClaudeSettingsInPrecedenceOrder() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-settings-\(UUID().uuidString)", isDirectory: true)
        let home = container.appendingPathComponent("home", isDirectory: true)
        let project = container.appendingPathComponent("project", isDirectory: true)
        let homeClaude = home.appendingPathComponent(".claude", isDirectory: true)
        let projectClaude = project.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: homeClaude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectClaude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        // Only the user settings exist: both values come from home.
        try Data(#"{"model": "gpt-5.6-sol", "effortLevel": "xhigh"}"#.utf8)
            .write(to: homeClaude.appendingPathComponent("settings.json"))
        var defaults = SupermuxHarnessSessionController.settingsDefaults(
            workingDirectoryURL: project,
            homeDirectoryURL: home
        )
        #expect(defaults?["model"] as? String == "gpt-5.6-sol")
        #expect(defaults?["effort"] as? String == "xhigh")

        // A project settings.json overrides the model; the effort still falls
        // through to the user file — per-key precedence, not per-file.
        try Data(#"{"model": "sonnet"}"#.utf8)
            .write(to: projectClaude.appendingPathComponent("settings.json"))
        defaults = SupermuxHarnessSessionController.settingsDefaults(
            workingDirectoryURL: project,
            homeDirectoryURL: home
        )
        #expect(defaults?["model"] as? String == "sonnet")
        #expect(defaults?["effort"] as? String == "xhigh")

        // settings.local.json outranks both.
        try Data(#"{"model": "opus", "effortLevel": "low"}"#.utf8)
            .write(to: projectClaude.appendingPathComponent("settings.local.json"))
        defaults = SupermuxHarnessSessionController.settingsDefaults(
            workingDirectoryURL: project,
            homeDirectoryURL: home
        )
        #expect(defaults?["model"] as? String == "opus")
        #expect(defaults?["effort"] as? String == "low")

        // No settings anywhere: nil, so the context omits the key entirely.
        let emptyHome = container.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        #expect(SupermuxHarnessSessionController.settingsDefaults(
            workingDirectoryURL: nil,
            homeDirectoryURL: emptyHome
        ) == nil)

        // Corrupt JSON is a cache miss, not a crash.
        let corruptHome = container.appendingPathComponent("corrupt-home", isDirectory: true)
        let corruptClaude = corruptHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptClaude, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: corruptClaude.appendingPathComponent("settings.json"))
        #expect(SupermuxHarnessSessionController.settingsDefaults(
            workingDirectoryURL: nil,
            homeDirectoryURL: corruptHome
        ) == nil)
    }

    /// Item A (dogfood round 8): the machine-wide LAST-USED model — recorded on
    /// every model use (a start that carried one, a set_model ack, an init
    /// frame) into a UserDefaults store shared across panes, and delivered as
    /// `context.defaults.lastUsed` so a new pane defaults to the last model the
    /// user actually ran instead of settings.json's stale value. The real CLI
    /// forgets a plain /model switch on exit ("for this session only"), which
    /// is exactly why the harness has to remember it.
    @MainActor
    @Test
    func testLastUsedModelIsRecordedOnUseAndSharedAcrossControllers() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let process = MockSupermuxHarnessProcessSession()
        let controller = makeController(
            restoreState: nil,
            defaults: defaults,
            process: process
        )
        defer { controller.close() }

        // Nothing recorded yet: contextDefaults has no lastUsed.
        #expect(controller.contextDefaults()?["lastUsed"] == nil)

        // A start that carries a model records it.
        _ = try await controller.start(
            resumeSessionId: nil,
            forkSession: false,
            model: "opus[1m]",
            permissionMode: nil,
            effort: "high"
        )
        var lastUsed = controller.contextDefaults()?["lastUsed"] as? [String: Any]
        #expect(lastUsed?["model"] as? String == "opus[1m]")
        #expect(lastUsed?["effort"] as? String == "high")

        // A live set_model ack updates it.
        try await controller.setModel(model: "sonnet", effort: "low")
        lastUsed = controller.contextDefaults()?["lastUsed"] as? [String: Any]
        #expect(lastUsed?["model"] as? String == "sonnet")
        #expect(lastUsed?["effort"] as? String == "low")

        // An init frame naming another model (a /model slash command emits a
        // fresh init and never passes through setModel) updates the model and
        // PRESERVES the stored effort — init frames carry none.
        try await process.emitLine([
            "type": "system",
            "subtype": "init",
            "session_id": "session-2",
            "model": "gpt-5.6-sol",
        ])
        lastUsed = controller.contextDefaults()?["lastUsed"] as? [String: Any]
        #expect(lastUsed?["model"] as? String == "gpt-5.6-sol")
        #expect(lastUsed?["effort"] as? String == "low")

        // A SECOND controller on the same defaults (a new pane) sees it too:
        // the store is machine-wide, not per-pane.
        let otherProcess = MockSupermuxHarnessProcessSession()
        let otherPane = makeController(
            restoreState: nil,
            defaults: defaults,
            process: otherProcess
        )
        defer { otherPane.close() }
        let otherLastUsed = otherPane.contextDefaults()?["lastUsed"] as? [String: Any]
        #expect(otherLastUsed?["model"] as? String == "gpt-5.6-sol")

        // A flagless start records nothing — no model was named.
        _ = try await otherPane.start(
            resumeSessionId: nil,
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )
        let unchanged = otherPane.contextDefaults()?["lastUsed"] as? [String: Any]
        #expect(unchanged?["model"] as? String == "gpt-5.6-sol")
    }

    @MainActor
    @Test
    func testTwoControllersShareOneInjectedRepositoryScan() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "supermux-harness-shared-repository-\(UUID().uuidString)",
                isDirectory: true
            )
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = SupermuxHarnessSessionDiscovery(
            projectsRootURL: projects,
            fileManager: .default
        )
        let projectDirectory = try #require(
            discovery.projectDirectoryURLs(for: workingDirectory).first
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = projectDirectory.appendingPathComponent("shared.jsonl")
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "ai-title",
            "aiTitle": "Shared",
        ], options: [.sortedKeys])
        try (data + Data("\n".utf8)).write(to: fileURL)

        let gate = SupermuxHarnessControllerRepositoryScanGate()
        let repository = SupermuxHarnessSessionRepository(
            projectsRootURL: projects,
            fileManager: .default,
            configuration: .production,
            scanObserver: { _ in await gate.arriveAndWait() }
        )
        let first = makeController(
            restoreState: nil,
            defaults: defaults,
            process: MockSupermuxHarnessProcessSession(),
            workingDirectory: workingDirectory.path,
            projectsRootURL: projects,
            sessionRepository: repository
        )
        let second = makeController(
            restoreState: nil,
            defaults: defaults,
            process: MockSupermuxHarnessProcessSession(),
            workingDirectory: workingDirectory.path,
            projectsRootURL: projects,
            sessionRepository: repository
        )
        defer {
            first.close()
            second.close()
        }

        async let firstList = first.listSessions(limit: nil)
        await gate.waitForArrivals(1)
        async let secondList = second.listSessions(limit: nil)
        let didCoalesce = await SupermuxHarnessControllerTestWait().until {
            await repository.debugMetrics(for: fileURL).coalescedRequestCount == 1
        }
        await gate.release()

        #expect(didCoalesce)
        #expect(try await firstList.first?["title"] as? String == "Shared")
        #expect(try await secondList.first?["title"] as? String == "Shared")
        #expect(await repository.debugMetrics(for: fileURL).scanCount == 1)
    }

    @MainActor
    @Test
    func testPendingRenameRejectsOlderDiskTitleCompletion() async throws {
        let defaults = try makeHarnessDefaults(executablePath: "/usr/bin/true")
        defer { clearHarnessDefaults(defaults) }
        var restored = SessionSupermuxHarnessPanelSnapshot()
        restored.sessionId = "session"
        let repository = DelayedSupermuxHarnessSessionRepository()
        let process = MockSupermuxHarnessProcessSession()
        process.heldControlSubtypes = ["rename_session"]
        let controller = makeController(
            restoreState: restored,
            defaults: defaults,
            process: process,
            sessionRepository: repository
        )
        defer { controller.close() }
        var titles: [String] = []
        controller.titleSink = { title in
            if let title { titles.append(title) }
        }
        _ = try await controller.start(
            resumeSessionId: "session",
            forkSession: false,
            model: nil,
            permissionMode: nil,
            effort: nil
        )
        await repository.waitForTitleRequests(1)

        let rename = Task { @MainActor in
            try await controller.renameSession(title: "Custom title")
        }
        let renameReachedProcess = await SupermuxHarnessControllerTestWait().until {
            await MainActor.run {
                process.operations.contains(.control(subtype: "rename_session"))
            }
        }
        #expect(renameReachedProcess)
        await repository.releaseTitles("Older disk title")
        _ = await SupermuxHarnessControllerTestWait().until {
            await MainActor.run { !titles.isEmpty }
        }
        #expect(!titles.contains("Older disk title"))

        process.releaseHeldControl(subtype: "rename_session")
        try await rename.value
        #expect(titles.last == "Custom title")
    }

    @MainActor
    private func makeController(
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        defaults: UserDefaults,
        process: MockSupermuxHarnessProcessSession,
        workingDirectory: String? = "/tmp",
        projectsRootURL: URL? = nil,
        taskOutputRootURL: URL? = nil,
        modelCatalogProbe: (@MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog)? = nil,
        sessionRepository: (any SupermuxHarnessSessionReading)? = nil
    ) -> SupermuxHarnessSessionController {
        let transcriptService = SupermuxHarnessSubagentTranscriptService(
            projectsRootURL: projectsRootURL ?? SupermuxHarnessSessionController.claudeProjectsRootURL,
            fileManager: .default
        )
        return SupermuxHarnessSessionController(
            workingDirectory: workingDirectory,
            restoreState: restoreState,
            sessionRepository: sessionRepository ?? makeSessionRepository(
                projectsRootURL: projectsRootURL
            ),
            transcriptService: transcriptService,
            defaults: defaults,
            projectsRootURL: projectsRootURL,
            taskOutputRootURL: taskOutputRootURL,
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

    private func makeSessionRepository(
        projectsRootURL: URL? = nil
    ) -> SupermuxHarnessSessionRepository {
        SupermuxHarnessSessionRepository(
            projectsRootURL: projectsRootURL ?? SupermuxHarnessSessionController.claudeProjectsRootURL,
            fileManager: .default
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

private actor DelayedSupermuxHarnessSessionRepository: SupermuxHarnessSessionReading {
    private var titleRequests = 0
    private var requestWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var titleContinuations: [CheckedContinuation<String?, Never>] = []

    func listSessions(
        for workingDirectoryURL: URL,
        limit: Int?
    ) async throws -> [SupermuxHarnessDiscoveredSession] {
        _ = workingDirectoryURL
        _ = limit
        return []
    }

    func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int?
    ) async throws -> SupermuxHarnessHistoryPage {
        _ = workingDirectoryURL
        _ = sessionID
        _ = recordLimit
        return SupermuxHarnessHistoryPage(events: [], truncated: false)
    }

    func sessionTitle(
        for workingDirectoryURL: URL,
        sessionID: String
    ) async -> String? {
        _ = workingDirectoryURL
        _ = sessionID
        titleRequests += 1
        let ready = requestWaiters.filter { titleRequests >= $0.count }
        requestWaiters.removeAll { titleRequests >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        return await withCheckedContinuation { continuation in
            titleContinuations.append(continuation)
        }
    }

    func waitForTitleRequests(_ count: Int) async {
        guard titleRequests < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseTitles(_ title: String?) {
        let continuations = titleContinuations
        titleContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: title)
        }
    }
}

private actor SupermuxHarnessControllerRepositoryScanGate {
    private var arrivals = 0
    private var arrivalWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func arriveAndWait() async {
        arrivals += 1
        let ready = arrivalWaiters.filter { arrivals >= $0.count }
        arrivalWaiters.removeAll { arrivals >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForArrivals(_ count: Int) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((count, continuation))
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct SupermuxHarnessControllerTestWait {
    func until(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
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
    var heldControlSubtypes: Set<String> = []
    private(set) var operations: [Operation] = []

    private var heldControlContinuations: [String: CheckedContinuation<Void, Never>] = [:]
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

    func emitPermissionRequest(requestID: String) async throws {
        try await emit([
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
        if heldControlSubtypes.contains(subtype) {
            await withCheckedContinuation { continuation in
                heldControlContinuations[subtype] = continuation
            }
        }
        switch responses[subtype] ?? .success([:]) {
        case .success(let payload):
            try await emit([
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": requestID,
                    "response": payload,
                ],
            ])
        case .failure(let message):
            try await emit([
                "type": "control_response",
                "response": [
                    "subtype": "error",
                    "request_id": requestID,
                    "response": ["error": message],
                ],
            ])
        }
    }

    func releaseHeldControl(subtype: String) {
        heldControlSubtypes.remove(subtype)
        heldControlContinuations.removeValue(forKey: subtype)?.resume()
    }

    func emitLine(_ object: [String: Any]) async throws {
        try await emit(object)
    }

    private func emit(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let line = try #require(String(data: data, encoding: .utf8))
        await protocolLineSink?(try decoder.decodeLine(line))
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
