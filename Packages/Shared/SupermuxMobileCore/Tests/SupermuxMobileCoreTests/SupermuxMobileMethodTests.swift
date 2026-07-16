import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxMobileMethodTests {
    /// The exact wire strings from architecture §2, in declaration order.
    private static let expectedRawValues: [String] = [
        // Projects
        "mobile.supermux.projects.list",
        "mobile.supermux.project.create",
        "mobile.supermux.project.update",
        "mobile.supermux.project.delete",
        "mobile.supermux.project.open",
        "mobile.supermux.project.icon",
        "mobile.supermux.projects.set_section_collapsed",
        // Worktrees
        "mobile.supermux.worktrees.list",
        "mobile.supermux.worktree.suggest_branch",
        "mobile.supermux.worktree.create",
        "mobile.supermux.worktree.open",
        "mobile.supermux.worktree.remove",
        // Changes
        "mobile.supermux.changes.watch",
        "mobile.supermux.changes.status",
        "mobile.supermux.changes.diff",
        "mobile.supermux.changes.stage",
        "mobile.supermux.changes.unstage",
        "mobile.supermux.changes.discard",
        "mobile.supermux.changes.commit",
        "mobile.supermux.changes.generate_commit_message",
        "mobile.supermux.changes.push",
        "mobile.supermux.changes.pull",
        "mobile.supermux.changes.stash",
        "mobile.supermux.changes.stash_pop",
        "mobile.supermux.changes.history",
        // Run
        "mobile.supermux.run.state",
        "mobile.supermux.run.start",
        "mobile.supermux.run.stop",
        // Presets / actions
        "mobile.supermux.preset.create",
        "mobile.supermux.preset.update",
        "mobile.supermux.preset.delete",
        "mobile.supermux.preset.launch",
        "mobile.supermux.action.run",
        // Files
        "mobile.supermux.files.list",
        "mobile.supermux.files.create",
        "mobile.supermux.files.rename",
        "mobile.supermux.files.duplicate",
        "mobile.supermux.files.trash",
    ]

    @Test func allExposesEveryMethodExactlyOnce() {
        #expect(SupermuxMobileMethod.all.map(\.rawValue) == Self.expectedRawValues)
        #expect(SupermuxMobileMethod.all.count == 38)
        #expect(Set(SupermuxMobileMethod.all).count == SupermuxMobileMethod.all.count)
    }

    @Test func allMatchesCaseIterable() {
        #expect(SupermuxMobileMethod.all == SupermuxMobileMethod.allCases)
    }

    @Test func everyMethodCarriesTheNamespacePrefix() {
        #expect(SupermuxMobileMethod.namespacePrefix == "mobile.supermux.")
        for method in SupermuxMobileMethod.all {
            #expect(method.rawValue.hasPrefix(SupermuxMobileMethod.namespacePrefix))
        }
    }

    @Test func methodsRoundTripThroughRawValue() {
        for method in SupermuxMobileMethod.all {
            #expect(SupermuxMobileMethod(rawValue: method.rawValue) == method)
        }
        #expect(SupermuxMobileMethod(rawValue: "mobile.supermux.not.a.method") == nil)
    }
}
