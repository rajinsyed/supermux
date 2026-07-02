import Foundation
import Testing

import CmuxFoundation
import SupermuxKit

/// Regression tests for `SupermuxChangesModel`'s refresh coordination.
///
/// These exercise the directory-generation token and the
/// `isRefreshing`/`refreshPending` follow-up loop in
/// ``SupermuxChangesModel/refresh()`` using a fake ``CommandRunning`` that
/// deterministically gates each `git status` call. The fake never spawns a
/// real process, so timing is fully controlled and the tests are not flaky.
/// Every wait is bounded so a future regression fails the poll instead of
/// hanging.
@MainActor
@Suite struct SupermuxChangesModelTests {

    /// Joins porcelain-v2 records the way `git status -z` emits them.
    private nonisolated func zJoined(_ records: [String]) -> String {
        records.map { $0 + "\u{0}" }.joined()
    }

    // MARK: - Tests

    /// A status read whose directory was switched away mid-flight must be
    /// discarded rather than overwriting the new directory's snapshot.
    ///
    /// A `/A` read is started and suspended; the model is switched to `/B`
    /// (bumping the directory generation); then `/A` is released so its stale
    /// result arrives *after* the switch. At the first barrier past the `/A`
    /// read — whichever comes first of the explicit refresh finishing or the
    /// `/B` read starting (still gated) — the snapshot must not show `"a"`. A
    /// model without the generation guard writes `"a"` there and fails; the
    /// fixed model discards it. The barrier observes both outcomes, so it never
    /// hangs regardless of the follow-up-loop fix.
    @Test func directorySwitchDiscardsStaleStatusWrite() async {
        let runner = GatedStatusRunner(branchesByDirectory: ["/A": "a", "/B": "b"])

        // Settle the initial /A refresh to a known baseline so the gated reads
        // below are the only ones under test.
        await runner.setBranch("baseline", for: "/A")
        let service = SupermuxGitChangesService(runner: runner)
        let model = SupermuxChangesModel(service: service)
        model.setDirectory("/A")
        await pollUntil { model.snapshot.branch == "baseline" }

        // The next reads return "a" for /A and "b" for /B, and gate.
        await runner.setBranch("a", for: "/A")
        await runner.startGating()

        // Start an explicit /A refresh and wait for its read to be in flight.
        var refreshFinished = false
        let refreshTask = Task { @MainActor in
            await model.refresh()
            refreshFinished = true
        }
        let aCall = await runner.nextStartedCall()
        #expect(aCall.directory == "/A")

        // Switch to /B while the /A read is suspended; this bumps the directory
        // generation that the in-flight /A read captured.
        model.setDirectory("/B")

        // Let the stale /A read finish; its captured generation is now stale.
        await runner.release(aCall)

        // Barrier: the first moment past the /A read — either the explicit
        // refresh has finished or the /B read has started (call count >= 2).
        // /B has not returned yet, so a stale "a" would still be visible.
        await pollUntilAsync {
            if refreshFinished { return true }
            let count = await runner.callCount()
            return count >= 2
        }
        #expect(model.snapshot.branch != "a")

        // Converge to the authoritative /B snapshot. The /B read is issued by
        // the follow-up loop after /A is discarded; wait for it (bounded) rather
        // than checking once, so a slightly delayed start is not missed.
        if let bCall = await waitForStartedCall(from: runner) {
            #expect(bCall.directory == "/B")
            await runner.release(bCall)
        }
        await refreshTask.value
        await pollUntil { model.snapshot.branch == "b" }
        #expect(model.snapshot.branch == "b")
        #expect(model.directory == "/B")
    }

    /// A refresh requested while one is in flight must run a follow-up read
    /// rather than being silently dropped.
    ///
    /// The first `/A` read is suspended; a direct `refresh()` issued during it
    /// hits the reentrancy guard and records a pending follow-up. After the
    /// first read is released, the `repeat ... while refreshPending` loop runs a
    /// second status read whose (newer) result becomes the final snapshot. A
    /// model that early-returns on re-entry never issues the second read.
    @Test func refreshDuringInFlightRefreshIsHonored() async {
        // Each successive /A status call reports the next branch in the list, so
        // a second read produces a distinguishable value.
        let runner = GatedStatusRunner(
            branchesByDirectory: ["/A": "old"],
            sequencedBranches: ["old", "new"]
        )
        await runner.startGating()
        let service = SupermuxGitChangesService(runner: runner)
        let model = SupermuxChangesModel(service: service)

        // First refresh for /A; wait until its status read is in flight.
        model.setDirectory("/A")
        let first = await runner.nextStartedCall()
        #expect(first.directory == "/A")

        // Request another refresh while the first is suspended. This returns
        // promptly via the reentrancy guard, recording a pending follow-up.
        let pending = Task { @MainActor in await model.refresh() }

        // Release the first read; the pending follow-up should then issue a
        // second status read. Wait for it without blocking forever, so a model
        // that drops the follow-up fails by assertion instead of hanging.
        await runner.release(first)
        let second = await waitForStartedCall(from: runner)
        #expect(second != nil, "a follow-up status read should have started")
        if let second {
            #expect(second.directory == "/A")
            await runner.release(second)
        }
        await pending.value

        await pollUntil { model.snapshot.branch == "new" }
        #expect(model.snapshot.branch == "new")
        let calls = await runner.callCount()
        #expect(calls >= 2)
    }

    // MARK: - Batch staging

    /// The Untracked section's Stage All must issue ONE `git add` carrying
    /// every path plus one status refresh — never a per-file add+refresh cycle.
    @Test func batchStageIssuesOneAddForAllPaths() async {
        let untracked = ["a.txt", "b.txt", "c.txt"].map {
            SupermuxGitFileChange(path: $0, oldPath: nil, kind: .untracked)
        }
        let runner = RecordingMutationRunner()
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))
        model.setDirectory("/repo")
        await pollUntil { model.snapshot.isRepository }
        let statusCallsBefore = await runner.statusCallCount()

        await model.stage(changes: untracked)

        let addCalls = await runner.addCalls()
        #expect(addCalls == [["add", "--", "a.txt", "b.txt", "c.txt"]])
        // Exactly one follow-up refresh for the whole batch.
        #expect(await runner.statusCallCount() == statusCallsBefore + 1)
    }

    /// An empty batch is a pure no-op: no mutation, no refresh.
    @Test func emptyBatchStageDoesNothing() async {
        let runner = RecordingMutationRunner()
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))
        model.setDirectory("/repo")
        await pollUntil { model.snapshot.isRepository }
        let statusCallsBefore = await runner.statusCallCount()

        await model.stage(changes: [])

        #expect(await runner.addCalls().isEmpty)
        #expect(await runner.statusCallCount() == statusCallsBefore)
    }

    // MARK: - Stash enablement

    /// Tracked edit plus a stash: every stash action applies.
    @Test func trackedChangeWithStashEnablesEveryStashAction() async {
        let model = await makeModel(forStatus: zJoined([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 0000000 0000000 edit.txt",
            "# stash 1",
        ]))
        #expect(model.isStashMenuAvailable)
        #expect(model.canStashTracked)
        #expect(model.canStashIncludingUntracked)
        #expect(model.canPopStash)
    }

    /// Untracked files only: plain stash is a no-op (disabled); include-untracked
    /// applies; nothing to pop.
    @Test func untrackedOnlyEnablesIncludeUntrackedButNotPlainStash() async {
        let model = await makeModel(forStatus: zJoined(["# branch.head main", "? new.txt"]))
        #expect(model.isStashMenuAvailable)
        #expect(!model.canStashTracked)
        #expect(model.canStashIncludingUntracked)
        #expect(!model.canPopStash)
    }

    /// Clean tree with a stash: only Pop applies, and the menu still appears.
    @Test func cleanRepoWithStashEnablesOnlyPop() async {
        let model = await makeModel(forStatus: zJoined(["# branch.head main", "# stash 2"]))
        #expect(model.isStashMenuAvailable)
        #expect(!model.canStashTracked)
        #expect(!model.canStashIncludingUntracked)
        #expect(model.canPopStash)
    }

    /// Unmerged paths: `git stash` refuses, so every stash action is disabled
    /// even with a stash present.
    @Test func conflictDisablesAllStashActions() async {
        let model = await makeModel(forStatus: zJoined([
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 0 0 0 merge.txt",
            "# stash 1",
        ]))
        #expect(model.snapshot.hasConflicts)
        #expect(!model.canStashTracked)
        #expect(!model.canStashIncludingUntracked)
        #expect(!model.canPopStash)
    }

    /// Clean tree with no stash: there is nothing to do, so the menu is hidden.
    @Test func cleanRepoWithoutStashHidesMenu() async {
        let model = await makeModel(forStatus: "# branch.head main\u{0}")
        #expect(!model.isStashMenuAvailable)
    }

    /// Builds a model whose status reads return `stdout`, settled on its first
    /// snapshot. Uses ``FixedStatusRunner`` so no real git process runs.
    private func makeModel(forStatus stdout: String) async -> SupermuxChangesModel {
        let service = SupermuxGitChangesService(runner: FixedStatusRunner(statusStdout: stdout))
        let model = SupermuxChangesModel(service: service)
        model.setDirectory("/repo")
        await pollUntil { model.snapshot.isRepository }
        return model
    }

    /// A `CommandRunning` that returns a fixed `git status` stdout (and a clean
    /// exit for anything else), so model enablement can be exercised against
    /// crafted repository states without a real git process.
    private struct FixedStatusRunner: CommandRunning {
        let statusStdout: String
        func run(
            directory: String, executable: String, arguments: [String], timeout: TimeInterval?
        ) async -> CommandResult {
            let isStatus = executable == "git"
                && subcommand(of: arguments) == "status"
            return CommandResult(
                stdout: isStatus ? statusStdout : "",
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
    }

    /// A `CommandRunning` fake recording `git add` invocations and answering
    /// `status` with a plain repository, to pin the batch-staging contract
    /// (one add + one refresh per batch).
    private actor RecordingMutationRunner: CommandRunning {
        private var recordedAddCalls: [[String]] = []
        private var statusCalls = 0

        func addCalls() -> [[String]] { recordedAddCalls }
        func statusCallCount() -> Int { statusCalls }

        nonisolated func run(
            directory: String, executable: String, arguments: [String], timeout: TimeInterval?
        ) async -> CommandResult {
            await handle(arguments: arguments)
        }

        private func handle(arguments: [String]) -> CommandResult {
            var stdout = ""
            switch subcommand(of: arguments) {
            case "add":
                recordedAddCalls.append(arguments)
            case "status":
                statusCalls += 1
                stdout = "# branch.head main\u{0}"
            default:
                break
            }
            return CommandResult(
                stdout: stdout, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil
            )
        }
    }

    // MARK: - Fake runner

    /// A gated `git status --porcelain=v2 --branch` invocation observed by the
    /// fake, paired with the continuation that produces its result.
    private struct GatedStatusCall: Sendable {
        let index: Int
        let directory: String
        let release: CheckedContinuation<CommandResult, Never>
    }

    /// A `CommandRunning` fake whose `git status` calls can be gated.
    ///
    /// While gating is off (the default) status reads return immediately, which
    /// lets a test settle an initial snapshot. After ``startGating()`` each
    /// status read suspends until the test releases it, so timing is fully
    /// deterministic. Started gated calls are buffered and vended one at a time
    /// via ``nextStartedCall()`` so a test never polls or sleeps to learn a read
    /// has begun. The release payload's branch comes from `sequencedBranches`
    /// when set (so successive calls differ) otherwise from the per-directory
    /// map (so different `repoPath`s yield distinguishable branches). Any
    /// non-status command (none are issued by these tests) returns a clean exit.
    private actor GatedStatusRunner: CommandRunning {
        private var branchesByDirectory: [String: String]
        private let sequencedBranches: [String]
        private var gating = false
        private var statusCallCount = 0

        private var pendingStarted: [GatedStatusCall] = []
        private var waiter: CheckedContinuation<GatedStatusCall, Never>?

        init(branchesByDirectory: [String: String], sequencedBranches: [String] = []) {
            self.branchesByDirectory = branchesByDirectory
            self.sequencedBranches = sequencedBranches
        }

        func callCount() -> Int { statusCallCount }

        func startGating() { gating = true }

        func setBranch(_ branch: String, for directory: String) {
            branchesByDirectory[directory] = branch
        }

        nonisolated func run(
            directory: String,
            executable: String,
            arguments: [String],
            timeout: TimeInterval?
        ) async -> CommandResult {
            let isStatus = executable == "git"
                && arguments == [
                    "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--show-stash",
                ]
            guard isStatus else {
                return CommandResult(
                    stdout: "",
                    stderr: nil,
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                )
            }
            return await handleStatus(directory: directory)
        }

        private func handleStatus(directory: String) async -> CommandResult {
            let index = statusCallCount
            statusCallCount += 1
            guard gating else {
                return result(branchIndex: index, directory: directory)
            }
            return await withCheckedContinuation { release in
                let call = GatedStatusCall(index: index, directory: directory, release: release)
                if let waiter {
                    self.waiter = nil
                    waiter.resume(returning: call)
                } else {
                    pendingStarted.append(call)
                }
            }
        }

        /// Awaits the next gated status call that has begun (and is suspended on
        /// its gate). The returned call is already gated, so there is no
        /// lost-release race when the test releases it.
        func nextStartedCall() async -> GatedStatusCall {
            if !pendingStarted.isEmpty {
                return pendingStarted.removeFirst()
            }
            return await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }

        /// Returns a started gated call if one is already buffered, without
        /// suspending. Used at a barrier where a follow-up read may or may not
        /// have started.
        func startedCallIfAvailable() -> GatedStatusCall? {
            pendingStarted.isEmpty ? nil : pendingStarted.removeFirst()
        }

        /// Resumes `call`'s gate so the awaiting status read completes.
        func release(_ call: GatedStatusCall) {
            call.release.resume(returning: result(branchIndex: call.index, directory: call.directory))
        }

        private func result(branchIndex: Int, directory: String) -> CommandResult {
            let branch: String
            if !sequencedBranches.isEmpty {
                branch = sequencedBranches[min(branchIndex, sequencedBranches.count - 1)]
            } else {
                branch = branchesByDirectory[directory] ?? "unknown"
            }
            return CommandResult(
                stdout: "# branch.head \(branch)\u{0}",
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
    }

    // MARK: - Helpers

    /// Waits, with a bound, for a started gated status call to appear, yielding
    /// between checks. Returns `nil` if none starts within the bound so a model
    /// that drops a follow-up read fails by assertion rather than hanging.
    private func waitForStartedCall(from runner: GatedStatusRunner) async -> GatedStatusCall? {
        for _ in 0..<10_000 {
            if let call = await runner.startedCallIfAvailable() { return call }
            await Task.yield()
        }
        return nil
    }

    /// A slow mutation finishing after a workspace switch must not apply its
    /// outcome to the new directory's panel: the commit's success side effect
    /// (clearing the message box) and its error reporting are generation-
    /// guarded, so a draft typed for the switched-to directory survives.
    @Test func slowCommitOutcomeDoesNotBleedOntoSwitchedDirectory() async {
        let runner = GatedCommitRunner()
        let service = SupermuxGitChangesService(runner: runner)
        let model = SupermuxChangesModel(service: service)
        model.setDirectory("/repoA")
        await pollUntil { model.snapshot.isRepository }

        model.commitMessage = "message for A"
        let commitTask = Task { await model.commit() }
        await pollUntil { model.isWorking }

        // Switch away mid-commit (clears the box for /repoB), then draft a new
        // message; A's commit completing must not wipe it or surface an error.
        model.setDirectory("/repoB")
        model.commitMessage = "draft for B"
        await runner.releaseCommit()
        await commitTask.value

        #expect(model.commitMessage == "draft for B")
        #expect(model.lastError == nil)
    }

    /// A `CommandRunning` whose `git commit` suspends until released, so a
    /// workspace switch can be interleaved mid-mutation deterministically.
    private actor GatedCommitRunner: CommandRunning {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func releaseCommit() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        nonisolated func run(
            directory: String, executable: String, arguments: [String], timeout: TimeInterval?
        ) async -> CommandResult {
            let sub = subcommand(of: arguments)
            if sub == "commit" {
                await waitForRelease()
            }
            return CommandResult(
                stdout: sub == "status" ? "# branch.head main\u{0}" : "",
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }

        private func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Polls a synchronous main-actor `condition`, yielding between checks,
    /// until it is true or a bounded number of iterations elapse. Avoids real
    /// sleeps; the bound only guards against a hang on regression.
    private func pollUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Polls an async `condition` (which may touch the runner actor), yielding
    /// between checks, until it is true or a bounded number of iterations
    /// elapse.
    private func pollUntilAsync(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
    }
}

/// The git subcommand of an argument vector, skipping global flags such as
/// `--no-optional-locks` that the service prepends to read-only invocations.
private func subcommand(of arguments: [String]) -> String? {
    arguments.first { !$0.hasPrefix("-") }
}
