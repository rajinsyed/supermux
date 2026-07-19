import Foundation
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
/// (agent key + that key's own lifecycle matching the icon shape, no URL) and
/// preserve everything else: agent error rows, status/lifecycle mismatches
/// (some hook paths publish only the status row, e.g. codex transcript
/// questions/failures), rows for agents with no tracked lifecycle, rows with
/// click-through URLs, and user-defined `set_status` rows. Matching is per
/// agent key — one agent's lifecycle must never drop another agent's row.
@Suite struct SupermuxSidebarAgentStatusRowsTests {
    private func entry(
        key: String, value: String, icon: String?, url: URL? = nil
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: icon, url: url)
    }

    private func keys(
        _ entries: [SidebarStatusEntry],
        activityByAgentKey: [String: SupermuxWorkspaceActivity]
    ) -> [String] {
        SupermuxSidebarAgentStatusRows
            .droppingAgentStatusRows(from: entries, duplicatedBy: activityByAgentKey)
            .map(\.key)
    }

    @Test func dropsRunningRowWhileItsAgentIsWorking() {
        let entries = [entry(key: "claude_code", value: "Running", icon: "bolt.fill")]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .working]).isEmpty)
    }

    @Test func dropsIdleRowWhileItsAgentIsReady() {
        let entries = [entry(key: "claude_code", value: "Idle", icon: "pause.circle.fill")]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .ready]).isEmpty)
    }

    @Test func dropsNeedsInputRowWhileItsAgentNeedsInput() {
        let entries = [entry(key: "codex", value: "Codex needs input", icon: "bell.fill")]
        #expect(keys(entries, activityByAgentKey: ["codex": .needsInput]).isEmpty)
    }

    @Test func keepsErrorRowEvenWhileItsAgentIsWorking() {
        // Codex transcript failures publish only this status row — no
        // lifecycle update — so it must never be filtered.
        let entries = [
            entry(key: "codex", value: "Codex network error", icon: "exclamationmark.triangle.fill")
        ]
        #expect(keys(entries, activityByAgentKey: ["codex": .working]) == ["codex"])
    }

    @Test func keepsMismatchedNeedsInputRowWhileItsAgentLifecycleSaysWorking() {
        // Codex transcript questions publish only the bell status; if codex's
        // lifecycle still says working, the row is the sole needs-input signal.
        let entries = [entry(key: "codex", value: "Codex needs input", icon: "bell.fill")]
        #expect(keys(entries, activityByAgentKey: ["codex": .working]) == ["codex"])
    }

    @Test func keepsBellRowWhenOnlyAnotherAgentNeedsInput() {
        // Cross-agent regression: claude_code's needsInput lifecycle must not
        // drop codex's bell row when codex has no lifecycle entry of its own
        // (codex transcript questions publish only the status row).
        let entries = [entry(key: "codex", value: "Codex needs input", icon: "bell.fill")]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .needsInput]) == ["codex"])
    }

    @Test func dropsEachRowAgainstItsOwnAgentActivity() {
        // Multi-agent workspace: every row that duplicates its own agent's
        // lifecycle is dropped, regardless of what the aggregate would say.
        let entries = [
            entry(key: "claude_code", value: "Running", icon: "bolt.fill"),
            entry(key: "codex", value: "Codex needs input", icon: "bell.fill"),
        ]
        let activityByAgentKey: [String: SupermuxWorkspaceActivity] = [
            "claude_code": .working,
            "codex": .needsInput,
        ]
        #expect(keys(entries, activityByAgentKey: activityByAgentKey).isEmpty)
    }

    @Test func keepsAgentRowWhileNoLifecycleIsTracked() {
        let entries = [entry(key: "claude_code", value: "Running", icon: "bolt.fill")]
        #expect(keys(entries, activityByAgentKey: [:]) == ["claude_code"])
    }

    @Test func keepsUserDefinedStatusRows() {
        let entries = [
            entry(key: "deploy", value: "Running", icon: "bolt.fill"),
            entry(key: "claude_code", value: "Running", icon: "bolt.fill"),
        ]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .working]) == ["deploy"])
    }

    @Test func keepsAgentRowWithoutIcon() {
        let entries = [entry(key: "claude_code", value: "Running", icon: nil)]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .working]) == ["claude_code"])
    }

    @Test func keepsAgentRowWithURL() {
        // A row carrying a click-through link is never a mere duplicate of the
        // indicator — dropping it would silently discard the link.
        let entries = [
            entry(
                key: "claude_code",
                value: "Compiling — 3m left",
                icon: "bolt.fill",
                url: URL(string: "https://ci.example.com/build/42")
            )
        ]
        #expect(keys(entries, activityByAgentKey: ["claude_code": .working]) == ["claude_code"])
    }
}

/// Coverage for `SupermuxWorkspaceActivityResolver`'s pure resolution cores:
/// reserved manual workspace-loading keys (`manual`/`manual:<id>`, written by
/// `cmux workspace loading` to drive cmux's gray sidebar spinner) must never
/// register as agent activity, and per-key resolution must group across panels.
@Suite @MainActor struct SupermuxWorkspaceActivityResolverKeyTests {
    @Test func ignoresManualLoaderKeys() {
        let states: [UUID: [String: AgentHibernationLifecycleState]] = [
            UUID(): ["manual": .running],
            UUID(): ["manual:loader-1": .running],
        ]
        #expect(SupermuxWorkspaceActivityResolver.activity(fromStatesByPanelId: states) == .idle)
        #expect(SupermuxWorkspaceActivityResolver.activityByAgentKey(fromStatesByPanelId: states).isEmpty)
    }

    @Test func resolvesAgentKeysAlongsideManualKeys() {
        let states: [UUID: [String: AgentHibernationLifecycleState]] = [
            UUID(): ["manual": .running, "claude_code": .idle],
            UUID(): ["codex": .running],
        ]
        #expect(SupermuxWorkspaceActivityResolver.activity(fromStatesByPanelId: states) == .working)
        let byKey = SupermuxWorkspaceActivityResolver.activityByAgentKey(fromStatesByPanelId: states)
        #expect(byKey == ["claude_code": .ready, "codex": .working])
    }

    @Test func perKeyResolutionAggregatesAcrossPanels() {
        let states: [UUID: [String: AgentHibernationLifecycleState]] = [
            UUID(): ["claude_code": .idle],
            UUID(): ["claude_code": .needsInput],
        ]
        let byKey = SupermuxWorkspaceActivityResolver.activityByAgentKey(fromStatesByPanelId: states)
        #expect(byKey == ["claude_code": .needsInput])
    }
}
