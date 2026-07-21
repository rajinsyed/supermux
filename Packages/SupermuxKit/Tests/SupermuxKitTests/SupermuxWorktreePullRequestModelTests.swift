import CmuxGit
import Foundation
import Testing
@testable import SupermuxKit

/// A resolver that maps each target's path to a scripted resolution, echoing
/// the cache back unchanged.
private struct StubResolver: SupermuxPullRequestResolving {
    let resolutionsByPath: [String: SupermuxPullRequestProbe.Resolution]

    func resolve(
        targets: [SupermuxPullRequestTarget],
        cache: [String: WorkspacePullRequestRepoCacheEntry],
        allowCache: Bool,
        now: Date
    ) async -> SupermuxPullRequestProbe.Outcome {
        SupermuxPullRequestProbe.Outcome(
            resolutions: targets.map {
                .init(path: $0.path, resolution: resolutionsByPath[$0.path] ?? .absent)
            },
            updatedCache: cache
        )
    }
}

/// A resolver that serves scripted outcomes per call index and counts calls,
/// so tests can assert a refresh was (or wasn't) allowed to probe.
private actor CountingResolver: SupermuxPullRequestResolving {
    private let outcomes: [SupermuxPullRequestProbe.Outcome]
    private(set) var callCount = 0

    init(outcomes: [SupermuxPullRequestProbe.Outcome]) {
        self.outcomes = outcomes
    }

    func resolve(
        targets: [SupermuxPullRequestTarget],
        cache: [String: WorkspacePullRequestRepoCacheEntry],
        allowCache: Bool,
        now: Date
    ) async -> SupermuxPullRequestProbe.Outcome {
        callCount += 1
        return outcomes[min(callCount - 1, outcomes.count - 1)]
    }
}

/// A resolver whose first call suspends until the test opens a gate (holding a
/// probe pass in flight while a second pass runs), then serves scripted
/// outcomes per call index.
private actor GatedResolver: SupermuxPullRequestResolving {
    private let outcomes: [SupermuxPullRequestProbe.Outcome]
    private var calls = 0
    private var gateOpen = false
    private var gateWaiter: CheckedContinuation<Void, Never>?
    private var firstCallStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    init(outcomes: [SupermuxPullRequestProbe.Outcome]) {
        self.outcomes = outcomes
    }

    func resolve(
        targets: [SupermuxPullRequestTarget],
        cache: [String: WorkspacePullRequestRepoCacheEntry],
        allowCache: Bool,
        now: Date
    ) async -> SupermuxPullRequestProbe.Outcome {
        calls += 1
        let index = min(calls - 1, outcomes.count - 1)
        if calls == 1 {
            firstCallStarted = true
            startWaiter?.resume()
            startWaiter = nil
            if !gateOpen {
                await withCheckedContinuation { gateWaiter = $0 }
            }
        }
        return outcomes[index]
    }

    /// Suspends until the first `resolve` call has begun (and is gated).
    func waitForFirstCall() async {
        if firstCallStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    /// Lets the gated first call return.
    func openGate() {
        gateOpen = true
        gateWaiter?.resume()
        gateWaiter = nil
    }
}

/// Behavior tests for ``SupermuxWorktreePullRequestModel``: stale-pass writes
/// are dropped, and multi-client (shared, multi-window) tracking prunes badges
/// to the union of every client's targets.
@MainActor
struct SupermuxWorktreePullRequestModelTests {
    private func pullRequest(_ number: Int) -> SupermuxPullRequest {
        SupermuxPullRequest(
            number: number,
            status: .open,
            url: URL(string: "https://github.com/o/r/pull/\(number)")!
        )
    }

    private func outcome(path: String, number: Int) -> SupermuxPullRequestProbe.Outcome {
        SupermuxPullRequestProbe.Outcome(
            resolutions: [.init(path: path, resolution: .pullRequest(pullRequest(number)))],
            updatedCache: [:]
        )
    }

    private func target(_ path: String) -> SupermuxPullRequestTarget {
        SupermuxPullRequestTarget(path: path, branch: "feature")
    }

    // MARK: Stale-write race

    @Test func stalePassCannotClobberNewerPass() async {
        let resolver = GatedResolver(outcomes: [
            outcome(path: "/a", number: 1),   // call 1: held in flight, old data
            outcome(path: "/a", number: 2),   // call 2: the replacement pass
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let targets = [target("/a")]

        let stalePass = Task { await model.refresh(targets: targets, allowCache: true) }
        await resolver.waitForFirstCall()
        // A newer pass (e.g. the view's .task(id:) restarted) completes first.
        await model.refresh(targets: targets, allowCache: true)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 2)

        // The stale pass then returns; its write must be dropped.
        await resolver.openGate()
        await stalePass.value
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 2)
    }

    @Test func clearingPassInvalidatesInFlightPass() async {
        let resolver = GatedResolver(outcomes: [outcome(path: "/a", number: 1)])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)

        let stalePass = Task { await model.refresh(targets: [target("/a")], allowCache: true) }
        await resolver.waitForFirstCall()
        // The section collapsed / worktree list emptied: a clearing refresh runs.
        await model.refresh(targets: [], allowCache: true)
        await resolver.openGate()
        await stalePass.value
        // The stale pass must not resurrect the badge the clearing pass removed.
        #expect(model.pullRequestsByWorktreePath.isEmpty)
    }

    /// Two windows' poll passes routinely overlap (both sections poll on the
    /// same cadence) and carry disjoint target sets. The stale-pass guard is
    /// per-client, so one window's pass completing must never invalidate the
    /// other's in-flight pass — a global token would starve the losing
    /// window's badges every poll round.
    @Test func concurrentPassesFromDifferentClientsBothApply() async {
        let resolver = GatedResolver(outcomes: [
            outcome(path: "/a", number: 1),   // call 1: window A, held in flight
            outcome(path: "/b", number: 2),   // call 2: window B, completes first
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let windowA = UUID()
        let windowB = UUID()

        let passA = Task { await model.refresh(targets: [target("/a")], allowCache: true, client: windowA) }
        await resolver.waitForFirstCall()
        await model.refresh(targets: [target("/b")], allowCache: true, client: windowB)
        #expect(model.pullRequestsByWorktreePath["/b"]?.number == 2)

        await resolver.openGate()
        await passA.value
        // Window A's resolutions still land; window B's badge survives.
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 1)
        #expect(model.pullRequestsByWorktreePath["/b"]?.number == 2)
    }

    @Test func endTrackingInvalidatesTheClientsInFlightPass() async {
        let resolver = GatedResolver(outcomes: [outcome(path: "/a", number: 1)])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let window = UUID()

        let pass = Task { await model.refresh(targets: [target("/a")], allowCache: true, client: window) }
        await resolver.waitForFirstCall()
        model.endTracking(client: window)
        await resolver.openGate()
        await pass.value
        // The closed window's pass must not resurrect its badge.
        #expect(model.pullRequestsByWorktreePath.isEmpty)
    }

    /// Regression for generation recycling: `endTracking` removes the client's
    /// generation entry, so with per-client counters a later refresh for the
    /// SAME client id would restart at 1 — the same token a still-suspended
    /// pre-`endTracking` pass holds — letting the stale pass slip past the
    /// guard and clobber the recycled client's fresh badge. The monotonic
    /// counter makes recycled registrations mint strictly newer tokens.
    @Test func passStartedBeforeEndTrackingCannotClobberARecycledClient() async {
        let resolver = GatedResolver(outcomes: [
            outcome(path: "/a", number: 1),   // call 1: pre-endTracking pass, held in flight
            outcome(path: "/a", number: 2),   // call 2: the recycled client's fresh pass
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let window = UUID()

        let stalePass = Task { await model.refresh(targets: [target("/a")], allowCache: true, client: window) }
        await resolver.waitForFirstCall()
        model.endTracking(client: window)
        // The same client id re-registers and completes a fresh pass.
        await model.refresh(targets: [target("/a")], allowCache: true, client: window)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 2)

        // The pre-endTracking pass then returns; its result must be dropped.
        await resolver.openGate()
        await stalePass.value
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 2)
    }

    // MARK: Shared-model client tracking

    @Test func onePassNeverPrunesAnotherClientsBadges() async {
        let resolver = StubResolver(resolutionsByPath: [
            "/a": .pullRequest(pullRequest(1)),
            "/b": .pullRequest(pullRequest(2)),
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let windowA = UUID()
        let windowB = UUID()

        await model.refresh(targets: [target("/a")], allowCache: true, client: windowA)
        await model.refresh(targets: [target("/b")], allowCache: true, client: windowB)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 1)
        #expect(model.pullRequestsByWorktreePath["/b"]?.number == 2)

        // Window A polls again: /b is not among its targets but is still
        // tracked by window B, so it must survive the prune.
        await model.refresh(targets: [target("/a")], allowCache: true, client: windowA)
        #expect(model.pullRequestsByWorktreePath["/b"]?.number == 2)
    }

    @Test func emptyTargetsClearOnlyThisClientsExclusiveBadges() async {
        let resolver = StubResolver(resolutionsByPath: [
            "/shared": .pullRequest(pullRequest(1)),
            "/only-a": .pullRequest(pullRequest(2)),
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let windowA = UUID()
        let windowB = UUID()

        await model.refresh(targets: [target("/shared"), target("/only-a")], allowCache: true, client: windowA)
        await model.refresh(targets: [target("/shared")], allowCache: true, client: windowB)

        // Window A stops tracking (collapse/close): its exclusive badge goes,
        // the shared one stays for window B.
        await model.refresh(targets: [], allowCache: true, client: windowA)
        #expect(model.pullRequestsByWorktreePath["/only-a"] == nil)
        #expect(model.pullRequestsByWorktreePath["/shared"]?.number == 1)
    }

    @Test func endTrackingPrunesTheClientsBadges() async {
        let resolver = StubResolver(resolutionsByPath: ["/a": .pullRequest(pullRequest(1))])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let window = UUID()

        await model.refresh(targets: [target("/a")], allowCache: true, client: window)
        #expect(!model.pullRequestsByWorktreePath.isEmpty)
        model.endTracking(client: window)
        #expect(model.pullRequestsByWorktreePath.isEmpty)
    }

    /// Pins the double-endTracking safety the section's deinit token relies
    /// on: `onDisappear` deregisters promptly, then the `@State` token's
    /// `deinit` deregisters again — the second (now-unknown-client) call must
    /// be a no-op, and never disturb other clients' badges.
    @Test func endTrackingForUnknownClientIsANoOp() async {
        let resolver = StubResolver(resolutionsByPath: ["/a": .pullRequest(pullRequest(1))])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let window = UUID()

        await model.refresh(targets: [target("/a")], allowCache: true, client: window)
        // A never-registered client leaves tracked badges alone.
        model.endTracking(client: UUID())
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 1)

        // Double-endTracking for the same client: second call is a no-op.
        model.endTracking(client: window)
        model.endTracking(client: window)
        #expect(model.pullRequestsByWorktreePath.isEmpty)
    }

    // MARK: Rate-limit back-off

    @Test func rateLimitedPassSkipsProbesUntilTheDeadline() async {
        // Call 1 reports a rate limit with a future reset; the next refresh
        // must keep the badges and not launch another probe.
        let resolver = CountingResolver(outcomes: [
            SupermuxPullRequestProbe.Outcome(
                resolutions: [.init(path: "/a", resolution: .pullRequest(pullRequest(1)))],
                updatedCache: [:],
                rateLimitRetryDate: Date().addingTimeInterval(3600)
            ),
            outcome(path: "/a", number: 2),
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let targets = [target("/a")]

        await model.refresh(targets: targets, allowCache: true)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 1)
        await model.refresh(targets: targets, allowCache: true)
        #expect(await resolver.callCount == 1)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 1)
    }

    @Test func lapsedRateLimitDeadlineResumesProbing() async {
        // A reset date already in the past must not suppress the next pass,
        // and a clean pass clears the stored deadline.
        let resolver = CountingResolver(outcomes: [
            SupermuxPullRequestProbe.Outcome(
                resolutions: [.init(path: "/a", resolution: .pullRequest(pullRequest(1)))],
                updatedCache: [:],
                rateLimitRetryDate: Date().addingTimeInterval(-1)
            ),
            outcome(path: "/a", number: 2),
            outcome(path: "/a", number: 3),
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        let targets = [target("/a")]

        await model.refresh(targets: targets, allowCache: true)
        await model.refresh(targets: targets, allowCache: true)
        #expect(await resolver.callCount == 2)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 2)
        await model.refresh(targets: targets, allowCache: true)
        #expect(await resolver.callCount == 3)
        #expect(model.pullRequestsByWorktreePath["/a"]?.number == 3)
    }

    @Test func singleCallerSemanticsMatchLegacyBehavior() async {
        // Callers that omit the client id behave exactly like the old
        // single-window model: refresh prunes to the given targets, empty clears.
        let resolver = StubResolver(resolutionsByPath: [
            "/a": .pullRequest(pullRequest(1)),
            "/b": .pullRequest(pullRequest(2)),
        ])
        let model = SupermuxWorktreePullRequestModel(probe: resolver)
        await model.refresh(targets: [target("/a"), target("/b")], allowCache: true)
        #expect(model.pullRequestsByWorktreePath.count == 2)
        await model.refresh(targets: [target("/a")], allowCache: true)
        #expect(model.pullRequestsByWorktreePath.keys.sorted() == ["/a"])
        await model.refresh(targets: [], allowCache: true)
        #expect(model.pullRequestsByWorktreePath.isEmpty)
    }
}
