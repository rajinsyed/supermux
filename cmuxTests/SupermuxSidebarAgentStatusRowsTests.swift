import Testing
// `SidebarStatusEntry` is public in CmuxSidebar; import it explicitly (like
// SupermuxSidebarBranchTests) so this compiles in the plain-`cmux` unit config.
import CmuxSidebar
import SupermuxKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the flat-row agent-status dedup filter
/// (`SupermuxSidebarAgentStatusRows.droppingAgentStatusRows(from:duplicatedBy:)`).
///
/// The filter must drop only rows the activity indicator actually duplicates
/// (agent key + matching icon shape) and preserve everything else: agent error
/// rows, status/lifecycle mismatches (some hook paths publish only the status
/// row, e.g. codex transcript questions/failures), rows while no indicator is
/// visible, and user-defined `set_status` rows.
@Suite struct SupermuxSidebarAgentStatusRowsTests {
    private func entry(key: String, value: String, icon: String?) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: icon)
    }

    private func keys(
        _ entries: [SidebarStatusEntry],
        activity: SupermuxWorkspaceActivity
    ) -> [String] {
        SupermuxSidebarAgentStatusRows
            .droppingAgentStatusRows(from: entries, duplicatedBy: activity)
            .map(\.key)
    }

    @Test func dropsRunningRowWhileIndicatorShowsWorking() {
        let entries = [entry(key: "claude_code", value: "Running", icon: "bolt.fill")]
        #expect(keys(entries, activity: .working).isEmpty)
    }

    @Test func dropsIdleRowWhileIndicatorShowsReady() {
        let entries = [entry(key: "claude_code", value: "Idle", icon: "pause.circle.fill")]
        #expect(keys(entries, activity: .ready).isEmpty)
    }

    @Test func dropsNeedsInputRowWhileIndicatorShowsNeedsInput() {
        let entries = [entry(key: "codex", value: "Codex needs input", icon: "bell.fill")]
        #expect(keys(entries, activity: .needsInput).isEmpty)
    }

    @Test func keepsErrorRowEvenWhileIndicatorShowsWorking() {
        // Codex transcript failures publish only this status row — no
        // lifecycle update — so it must never be filtered.
        let entries = [
            entry(key: "codex", value: "Codex network error", icon: "exclamationmark.triangle.fill")
        ]
        #expect(keys(entries, activity: .working) == ["codex"])
    }

    @Test func keepsMismatchedNeedsInputRowWhileIndicatorShowsWorking() {
        // Codex transcript questions publish only the bell status; if the
        // lifecycle still says working, the row is the sole needs-input signal.
        let entries = [entry(key: "codex", value: "Codex needs input", icon: "bell.fill")]
        #expect(keys(entries, activity: .working) == ["codex"])
    }

    @Test func keepsAgentRowWhileNoIndicatorIsVisible() {
        let entries = [entry(key: "claude_code", value: "Running", icon: "bolt.fill")]
        #expect(keys(entries, activity: .idle) == ["claude_code"])
    }

    @Test func keepsUserDefinedStatusRows() {
        let entries = [
            entry(key: "deploy", value: "Running", icon: "bolt.fill"),
            entry(key: "claude_code", value: "Running", icon: "bolt.fill"),
        ]
        #expect(keys(entries, activity: .working) == ["deploy"])
    }

    @Test func keepsAgentRowWithoutIcon() {
        let entries = [entry(key: "claude_code", value: "Running", icon: nil)]
        #expect(keys(entries, activity: .working) == ["claude_code"])
    }
}
