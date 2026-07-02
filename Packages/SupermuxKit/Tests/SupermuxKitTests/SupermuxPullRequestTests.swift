import CmuxGit
import Foundation
import Testing
@testable import SupermuxKit

/// Tests the pull-request badge value, the `CmuxGit` bridging, the probe's
/// no-network short circuits (default branches / empty input), and the worktree
/// model's pure merge/prune logic.
struct SupermuxPullRequestTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    private func pullRequest(_ number: Int, _ status: SupermuxPullRequest.Status) -> SupermuxPullRequest {
        SupermuxPullRequest(number: number, status: status, url: url("https://github.com/o/r/pull/\(number)"))
    }

    // MARK: Status raw-value contract

    @Test func statusRawValuesBridgeWithCmux() {
        // The badge bridges both cmux's `SidebarPullRequestStatus` and CmuxGit's
        // `PullRequestStatus` via `rawValue`; these strings are that contract.
        #expect(SupermuxPullRequest.Status.open.rawValue == "open")
        #expect(SupermuxPullRequest.Status.merged.rawValue == "merged")
        #expect(SupermuxPullRequest.Status.closed.rawValue == "closed")
        #expect(SupermuxPullRequest.Status(rawValue: "open") == .open)
        #expect(SupermuxPullRequest.Status(rawValue: "merged") == .merged)
        #expect(SupermuxPullRequest.Status(rawValue: "closed") == .closed)
        #expect(SupermuxPullRequest.Status(rawValue: "draft") == nil)
    }

    // MARK: CmuxGit bridging

    @Test func bridgesResolvedItem() {
        let item = WorkspacePullRequestResolvedItem(
            number: 1234,
            urlString: "https://github.com/o/r/pull/1234",
            statusRawValue: "merged",
            branch: "feature"
        )
        let pr = SupermuxPullRequest(resolvedItem: item)
        #expect(pr?.number == 1234)
        #expect(pr?.status == .merged)
        #expect(pr?.url == url("https://github.com/o/r/pull/1234"))
        #expect(pr?.isStale == false)
    }

    @Test func bridgingRejectsBadInput() {
        // Unrecognized status → nil rather than a fabricated badge.
        #expect(SupermuxPullRequest(resolvedItem: WorkspacePullRequestResolvedItem(
            number: 1, urlString: "https://github.com/o/r/pull/1", statusRawValue: "queued", branch: "b"
        )) == nil)
        // Unparseable URL → nil.
        #expect(SupermuxPullRequest(resolvedItem: WorkspacePullRequestResolvedItem(
            number: 1, urlString: "", statusRawValue: "open", branch: "b"
        )) == nil)
    }

    // MARK: Probe short circuits (no network)

    @Test func probeSkipsDefaultBranchesWithoutNetwork() async {
        let probe = SupermuxPullRequestProbe()
        let targets = [
            SupermuxPullRequestTarget(path: "/repo/main", branch: "main"),
            SupermuxPullRequestTarget(path: "/repo/master", branch: "master"),
        ]
        let outcome = await probe.resolve(targets: targets, cache: [:], allowCache: false)
        #expect(outcome.resolutions.count == 2)
        for resolution in outcome.resolutions {
            guard case .absent = resolution.resolution else {
                Issue.record("default branch should resolve absent without a lookup")
                return
            }
        }
        #expect(outcome.updatedCache.isEmpty)
    }

    @Test func probeReturnsEmptyForNoTargets() async {
        let probe = SupermuxPullRequestProbe()
        let outcome = await probe.resolve(targets: [], cache: [:], allowCache: true)
        #expect(outcome.resolutions.isEmpty)
        #expect(outcome.updatedCache.isEmpty)
    }

    // MARK: Model merge / prune logic

    @Test func applyingSetsResolvedAndClearsAbsent() {
        let existing = ["/a": pullRequest(1, .open)]
        let resolutions: [SupermuxPullRequestProbe.PathResolution] = [
            .init(path: "/a", resolution: .absent),
            .init(path: "/b", resolution: .pullRequest(pullRequest(2, .merged))),
        ]
        let updated = SupermuxWorktreePullRequestModel.applying(
            resolutions, to: existing, trackedPaths: ["/a", "/b"]
        ).badges
        #expect(updated["/a"] == nil)          // absent cleared it
        #expect(updated["/b"]?.number == 2)    // resolved added it
    }

    @Test func applyingKeepsExistingOnTransientFailure() {
        let existing = ["/a": pullRequest(9, .open)]
        let updated = SupermuxWorktreePullRequestModel.applying(
            [.init(path: "/a", resolution: .keepExisting)],
            to: existing,
            trackedPaths: ["/a"]
        ).badges
        #expect(updated["/a"]?.number == 9)    // transient failure preserves the badge
    }

    @Test func applyingPrunesUntrackedPaths() {
        // A worktree that's been deleted (or opened as a workspace) drops out of
        // the tracked set and its badge is pruned even without a resolution.
        let existing = [
            "/keep": pullRequest(1, .open),
            "/gone": pullRequest(2, .closed),
        ]
        let updated = SupermuxWorktreePullRequestModel.applying(
            [], to: existing, trackedPaths: ["/keep"]
        ).badges
        #expect(updated["/keep"]?.number == 1)
        #expect(updated["/gone"] == nil)
    }

    // MARK: Stale escalation on repeated transient failures

    @Test func consecutiveTransientFailuresMarkBadgeStale() {
        var badges = ["/a": pullRequest(9, .open)]
        var counts: [String: Int] = [:]
        let keep: [SupermuxPullRequestProbe.PathResolution] = [
            .init(path: "/a", resolution: .keepExisting)
        ]
        for pass in 1...SupermuxWorktreePullRequestModel.staleFailureThreshold {
            let applied = SupermuxWorktreePullRequestModel.applying(
                keep, to: badges, trackedPaths: ["/a"], failureCounts: counts
            )
            badges = applied.badges
            counts = applied.failureCounts
            let expectStale = pass >= SupermuxWorktreePullRequestModel.staleFailureThreshold
            #expect(badges["/a"]?.isStale == expectStale, "pass \(pass)")
            #expect(badges["/a"]?.number == 9)
        }
    }

    @Test func successfulResolutionResetsFailureCount() {
        let badges = ["/a": pullRequest(9, .open)]
        let almostStale = ["/a": SupermuxWorktreePullRequestModel.staleFailureThreshold - 1]
        // A success resets the count (and refreshes the badge un-stale)...
        let recovered = SupermuxWorktreePullRequestModel.applying(
            [.init(path: "/a", resolution: .pullRequest(pullRequest(9, .open)))],
            to: badges, trackedPaths: ["/a"], failureCounts: almostStale
        )
        #expect(recovered.failureCounts["/a"] == nil)
        #expect(recovered.badges["/a"]?.isStale == false)
        // ...so the next transient failure starts counting from one again.
        let afterFailure = SupermuxWorktreePullRequestModel.applying(
            [.init(path: "/a", resolution: .keepExisting)],
            to: recovered.badges, trackedPaths: ["/a"], failureCounts: recovered.failureCounts
        )
        #expect(afterFailure.badges["/a"]?.isStale == false)
        #expect(afterFailure.failureCounts["/a"] == 1)
    }

    @Test func failureCountsPruneWithUntrackedPaths() {
        let applied = SupermuxWorktreePullRequestModel.applying(
            [], to: [:], trackedPaths: ["/keep"], failureCounts: ["/keep": 1, "/gone": 2]
        )
        #expect(applied.failureCounts == ["/keep": 1])
    }
}
