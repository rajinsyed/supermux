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
}
