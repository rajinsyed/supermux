import Foundation
import Testing

import CmuxProcess
import SupermuxKit

/// Behavior tests for ``SupermuxChangesModel``'s incoming-commit feed and the
/// background ``SupermuxChangesModel/fetchAndRefresh()`` flow.
///
/// Uses a recording fake ``CommandRunning`` that answers `git status` (with a
/// configurable behind count that a `git fetch` can advance) and the incoming
/// `git log HEAD..@{upstream}` deterministically, so the tests assert the
/// load-on-expand, behind-gating, no-upstream, and fetch-then-refresh contracts
/// without real processes or timing flakiness.
@MainActor
@Suite struct SupermuxChangesIncomingModelTests {

    @Test func expandingIncomingLoadsCommitsWhenBehind() async {
        let runner = IncomingRunner(behind: 3, incomingCount: 3)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setIncomingExpanded(true)

        #expect(await runner.incomingLogCallCount() == 1)
        #expect(model.incomingCommits.count == 3)
        #expect(model.incomingCommits.first?.subject == "Subject 0")
        #expect(model.hasMoreIncoming == false)
        #expect(model.isLoadingIncoming == false)
    }

    /// Section-visibility counts track `ahead`/`behind` so the panel can hide an
    /// empty section without loading its commit list.
    @Test func sectionCountsTrackAheadAndBehind() async {
        let runner = IncomingRunner(ahead: 3, behind: 2, incomingCount: 2)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()

        #expect(model.outgoingCount == 3)
        #expect(model.incomingCount == 2)
        // Counts come from status alone — no commit-log read needed.
        #expect(await runner.incomingLogCallCount() == 0)
    }

    /// No upstream → nothing is pullable, so the incoming count is zero (the
    /// Incoming section stays hidden) even if commits exist on a remote.
    @Test func incomingCountZeroWithoutUpstream() async {
        let runner = IncomingRunner(hasUpstream: false, incomingCount: 3)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()

        #expect(model.incomingCount == 0)
    }

    /// With an upstream but nothing behind, the `HEAD..@{upstream}` range is
    /// provably empty, so the model skips the incoming `git log` entirely.
    @Test func behindZeroSkipsIncomingLog() async {
        let runner = IncomingRunner(behind: 0, incomingCount: 3)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setIncomingExpanded(true)

        #expect(await runner.incomingLogCallCount() == 0)
        #expect(model.incomingCommits.isEmpty)
        #expect(model.isLoadingIncoming == false)
    }

    /// No upstream → nothing to pull → no incoming log read, list stays empty.
    @Test func noUpstreamSkipsIncomingLog() async {
        let runner = IncomingRunner(hasUpstream: false, behind: 0, incomingCount: 3)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setIncomingExpanded(true)

        #expect(await runner.incomingLogCallCount() == 0)
        #expect(model.incomingCommits.isEmpty)
    }

    @Test func collapsingIncomingClearsCommits() async {
        let runner = IncomingRunner(behind: 2, incomingCount: 2)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setIncomingExpanded(true)
        #expect(model.incomingCommits.count == 2)

        await model.setIncomingExpanded(false)
        #expect(model.incomingCommits.isEmpty)
        #expect(model.hasMoreIncoming == false)

        let countBefore = await runner.incomingLogCallCount()
        await model.refresh()
        // A collapsed section performs no further incoming-log reads.
        #expect(await runner.incomingLogCallCount() == countBefore)
    }

    /// `fetchAndRefresh` runs a fetch then refreshes: a remote commit invisible
    /// before the fetch (behind 0) becomes visible after it advances `behind`.
    @Test func fetchAndRefreshSurfacesIncomingAfterFetch() async {
        let runner = IncomingRunner(behind: 0, behindAfterFetch: 2, incomingCount: 2)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.setIncomingExpanded(true)
        #expect(model.incomingCommits.isEmpty)
        #expect(model.snapshot.behind == 0)

        await model.fetchAndRefresh()

        #expect(await runner.fetchCallCount() == 1)
        #expect(model.snapshot.behind == 2)
        #expect(model.incomingCount == 2)
        #expect(model.incomingCommits.count == 2)
    }

    /// The background fetch must defer to a user mutation: while a push is in
    /// flight (`isWorking`), `fetchAndRefresh` skips the network fetch so the
    /// silent fetch cannot race the push's own fetch into a ref-lock error.
    @Test func autoFetchSkippedWhileMutating() async {
        let runner = BlockingMutationRunner()
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()

        // Start a push that blocks inside the runner, holding isWorking == true.
        let pushTask = Task { await model.push() }
        await runner.waitUntilMutationStarted()

        await model.fetchAndRefresh()
        #expect(await runner.fetchCallCount() == 0)

        // Release the push; once isWorking clears, fetch is allowed again.
        await runner.releaseMutation()
        await pushTask.value
        await model.fetchAndRefresh()
        #expect(await runner.fetchCallCount() == 1)
    }

    // MARK: - Fake runners

    /// A `CommandRunning` fake answering `status` (with a behind count a `fetch`
    /// can advance via `behindAfterFetch`) and the incoming `git log`. Records
    /// every invocation's arguments.
    private actor IncomingRunner: CommandRunning {
        private var calls: [[String]] = []
        private let hasUpstream: Bool
        private let ahead: Int
        private let behind: Int
        private let behindAfterFetch: Int?
        private let incomingCount: Int
        private var didFetch = false

        init(
            hasUpstream: Bool = true,
            ahead: Int = 0,
            behind: Int = 0,
            behindAfterFetch: Int? = nil,
            incomingCount: Int = 0
        ) {
            self.hasUpstream = hasUpstream
            self.ahead = ahead
            self.behind = behind
            self.behindAfterFetch = behindAfterFetch
            self.incomingCount = incomingCount
        }

        func fetchCallCount() -> Int { calls.filter { $0.contains("fetch") }.count }

        func incomingLogCallCount() -> Int {
            calls.filter { $0.first == "log" && $0.contains("HEAD..@{upstream}") }.count
        }

        nonisolated func run(
            directory: String,
            executable: String,
            arguments: [String],
            timeout: TimeInterval?
        ) async -> CommandResult {
            await handle(arguments: arguments)
        }

        private func handle(arguments: [String]) -> CommandResult {
            calls.append(arguments)
            if arguments.contains("fetch") {
                didFetch = true
                return result(stdout: "")
            }
            switch arguments.first {
            case "status":
                var stdout = "# branch.head main\n"
                if hasUpstream {
                    let value = didFetch ? (behindAfterFetch ?? behind) : behind
                    stdout += "# branch.upstream origin/main\n# branch.ab +\(ahead) -\(value)\n"
                }
                return result(stdout: stdout)
            case "log" where arguments.contains("HEAD..@{upstream}"):
                let limit = Self.maxCount(in: arguments) ?? incomingCount
                let count = max(0, min(limit, incomingCount))
                let stdout = (0..<count).map { index in
                    ["hash\(index)", "h\(index)", "Author \(index)", "\(index) days ago", "Subject \(index)"]
                        .joined(separator: "\u{0}") + "\u{0}"
                }.joined()
                return result(stdout: stdout)
            default:
                return result(stdout: "")
            }
        }

        private func result(stdout: String) -> CommandResult {
            CommandResult(stdout: stdout, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
        }

        private static func maxCount(in arguments: [String]) -> Int? {
            for argument in arguments where argument.hasPrefix("--max-count=") {
                return Int(argument.dropFirst("--max-count=".count))
            }
            return nil
        }
    }

    /// A `CommandRunning` fake that answers `status`/`log`/`fetch` immediately
    /// but suspends a `push` until ``releaseMutation()`` is called, so a test can
    /// hold the model's `isWorking` true while exercising the auto-fetch guard.
    private actor BlockingMutationRunner: CommandRunning {
        private var calls: [[String]] = []
        private var mutationStarted = false
        private var releaseRequested = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func fetchCallCount() -> Int { calls.filter { $0.contains("fetch") }.count }

        /// Suspends until a `push` reaches the runner.
        func waitUntilMutationStarted() async {
            if mutationStarted { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }

        /// Lets the in-flight `push` complete.
        func releaseMutation() {
            releaseRequested = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        nonisolated func run(
            directory: String,
            executable: String,
            arguments: [String],
            timeout: TimeInterval?
        ) async -> CommandResult {
            await handle(arguments: arguments)
        }

        private func handle(arguments: [String]) async -> CommandResult {
            calls.append(arguments)
            if arguments.first == "push" {
                mutationStarted = true
                startedWaiter?.resume()
                startedWaiter = nil
                if !releaseRequested {
                    await withCheckedContinuation { releaseWaiter = $0 }
                }
                return ok("")
            }
            if arguments.first == "status" {
                return ok("# branch.head main\n# branch.upstream origin/main\n# branch.ab +1 -0\n")
            }
            return ok("")
        }

        private func ok(_ stdout: String) -> CommandResult {
            CommandResult(stdout: stdout, stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
        }
    }
}
