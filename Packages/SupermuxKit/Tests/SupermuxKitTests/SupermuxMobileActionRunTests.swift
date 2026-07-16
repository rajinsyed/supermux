import Foundation
import Testing
@testable import SupermuxKit

/// Classification tests for `mobile.supermux.action.run` (validation contract
/// RPC-ACT-01): an action whose command is a single absolute http(s) URL is
/// an `open_url` action — the Mac returns `{kind: "open_url", url}` and
/// executes nothing — while every other launchable action (editor commands
/// like `cursor .` included) is a `command` action the Mac executes through
/// the desktop launch path.
struct SupermuxMobileActionRunTests {
    // MARK: - RPC-ACT-01: open_url actions return the URL, unexecuted

    @Test func urlCommandClassifiesAsOpenURL() throws {
        let action = SupermuxProjectAction(name: "Dashboard", command: "https://example.com/dashboard?tab=1")
        let outcome = try #require(SupermuxMobileActionRun.outcome(for: action))
        #expect(outcome == .openURL(try #require(URL(string: "https://example.com/dashboard?tab=1"))))
    }

    @Test func urlCommandToleratesSurroundingWhitespaceAndPlainHTTP() throws {
        let action = SupermuxProjectAction(name: "Staging", command: "  http://localhost:3000/status \n")
        let outcome = try #require(SupermuxMobileActionRun.outcome(for: action))
        #expect(outcome == .openURL(try #require(URL(string: "http://localhost:3000/status"))))
    }

    @Test func openURLWireResultCarriesKindAndURLOnly() throws {
        let url = try #require(URL(string: "https://example.com/dashboard"))
        let payload = SupermuxMobileActionRun.openURLResult(url: url)
        #expect(payload.count == 2)
        #expect(payload["kind"] as? String == "open_url")
        #expect(payload["url"] as? String == "https://example.com/dashboard")
    }

    // MARK: - RPC-ACT-01: command (and editor) actions execute mac-side

    @Test func editorCommandClassifiesAsCommand() throws {
        let action = SupermuxProjectAction(name: "Open in Cursor", command: "cursor .")
        #expect(SupermuxMobileActionRun.outcome(for: action) == .command("cursor ."))
    }

    @Test func commandMentioningAURLIsStillACommand() throws {
        let action = SupermuxProjectAction(name: "Open docs", command: "open https://example.com")
        #expect(SupermuxMobileActionRun.outcome(for: action) == .command("open https://example.com"))
    }

    @Test func nonHTTPSchemesAndHostlessURLsAreCommands() throws {
        // Only absolute http(s) URLs are safe to hand to the phone; anything
        // else keeps desktop behavior (run through the interactive shell).
        #expect(SupermuxMobileActionRun.outcome(
            for: SupermuxProjectAction(name: "Editor", command: "vscode://file/tmp")
        ) == .command("vscode://file/tmp"))
        #expect(SupermuxMobileActionRun.outcome(
            for: SupermuxProjectAction(name: "Broken", command: "https://")
        ) == .command("https://"))
    }

    @Test func commandWireResultReportsOK() {
        let payload = SupermuxMobileActionRun.commandResult()
        #expect(payload["ok"] as? Bool == true)
        #expect(payload["kind"] as? String == "command")
    }

    // MARK: - Unlaunchable actions

    @Test func blankActionsHaveNoOutcome() {
        #expect(SupermuxMobileActionRun.outcome(
            for: SupermuxProjectAction(name: "Blank", command: "   ")
        ) == nil)
        #expect(SupermuxMobileActionRun.outcome(
            for: SupermuxProjectAction(name: " ", command: "echo hi")
        ) == nil)
    }
}
