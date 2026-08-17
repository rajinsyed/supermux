import CmuxCore
import Foundation
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
