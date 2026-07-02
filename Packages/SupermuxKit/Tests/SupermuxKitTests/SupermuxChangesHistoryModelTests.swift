import Foundation
import Testing

import CmuxFoundation
import SupermuxKit

/// Behavior tests for ``SupermuxChangesModel``'s unpushed-commits loading.
///
/// Uses a recording fake ``CommandRunning`` that answers `git status` and
/// `git log` deterministically (no real process), so the tests assert the
/// load-on-expand, refetch, paging, push-clears, and collapse contracts without
/// timing flakiness.
@MainActor
@Suite struct SupermuxChangesHistoryModelTests {

    @Test func noCommitLogReadBeforeExpansion() async {
        let runner = RecordingRunner(totalCommits: 5)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()

        #expect(await runner.logCallCount() == 0)
        #expect(model.commits.isEmpty)
    }

    @Test func expandingLoadsCommits() async {
        let runner = RecordingRunner(totalCommits: 5)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh() // settle the directory-change refresh first

        await model.setHistoryExpanded(true)

        #expect(await runner.logCallCount() == 1)
        #expect(model.commits.count == 5)
        #expect(model.commits.first?.subject == "Subject 0")
        #expect(model.hasMoreCommits == false)
        #expect(model.isLoadingCommits == false)
    }

    /// While expanded, each refresh re-reads the (small) unpushed set so it
    /// reflects every change — there is no cached skip on the no-upstream path.
    @Test func expandedRefreshRefetchesUnpushedList() async {
        let runner = RecordingRunner(totalCommits: 5)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)
        #expect(await runner.logCallCount() == 1)

        await model.refresh()
        #expect(await runner.logCallCount() == 2)
    }

    @Test func paginationReportsMoreAndGrowsTheLimit() async {
        let runner = RecordingRunner(totalCommits: 250)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()

        await model.setHistoryExpanded(true)
        #expect(model.commits.count == 100)
        #expect(model.hasMoreCommits)

        await model.loadMoreCommits()
        #expect(model.commits.count == 200)
        #expect(model.hasMoreCommits)

        // The newest page read one past the grown limit to detect "more".
        let logCalls = await runner.logCalls()
        #expect(logCalls.last?.contains("--max-count=201") == true)
    }

    /// With an upstream and nothing ahead, the range is provably empty, so the
    /// model skips the `git log` entirely.
    @Test func upstreamWithNothingAheadSkipsLogRead() async {
        let runner = RecordingRunner(totalCommits: 5, hasUpstream: true, ahead: 0)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)

        #expect(await runner.logCallCount() == 0)
        #expect(model.commits.isEmpty)
        #expect(model.isLoadingCommits == false)
    }

    /// A push drops ahead to 0 without moving HEAD; the next refresh must clear
    /// the unpushed list (and can do so via the skip, with no new log read).
    @Test func pushClearsUnpushedList() async {
        let runner = RecordingRunner(totalCommits: 5, hasUpstream: true, ahead: 2)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)
        #expect(model.commits.count == 5)
        #expect(await runner.logCallCount() == 1)

        await runner.setAhead(0)
        await model.refresh()
        #expect(model.commits.isEmpty)
        #expect(await runner.logCallCount() == 1)
    }

    @Test func collapsingClearsCommitsAndStopsReading() async {
        let runner = RecordingRunner(totalCommits: 5)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)
        #expect(model.commits.count == 5)

        await model.setHistoryExpanded(false)
        #expect(model.commits.isEmpty)
        #expect(model.hasMoreCommits == false)

        let countBeforeRefresh = await runner.logCallCount()
        await model.refresh()
        // A collapsed panel performs no further commit-log reads.
        #expect(await runner.logCallCount() == countBeforeRefresh)
    }

    // MARK: - Fake runner

    /// A `CommandRunning` fake that answers `status` with a `main` repository
    /// (optionally tracking an upstream `ahead` commits) and `log` with
    /// `totalCommits` synthetic commits, honoring the request's `--max-count`.
    /// Records every invocation's arguments.
    private actor RecordingRunner: CommandRunning {
        private var calls: [[String]] = []
        private let totalCommits: Int
        private let hasUpstream: Bool
        private var ahead: Int

        init(totalCommits: Int, hasUpstream: Bool = false, ahead: Int = 0) {
            self.totalCommits = totalCommits
            self.hasUpstream = hasUpstream
            self.ahead = ahead
        }

        /// Changes the ahead count, as a push or fetch would, without moving HEAD.
        func setAhead(_ ahead: Int) { self.ahead = ahead }

        func logCalls() -> [[String]] {
            calls.filter { $0.first(where: { !$0.hasPrefix("-") }) == "log" }
        }
        func logCallCount() -> Int { logCalls().count }

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
            // Skip global flags (`--no-optional-locks`) to find the subcommand.
            switch arguments.first(where: { !$0.hasPrefix("-") }) {
            case "status":
                var stdout = "# branch.head main\u{0}"
                if hasUpstream {
                    stdout += "# branch.upstream origin/main\u{0}# branch.ab +\(ahead) -0\u{0}"
                }
                return result(stdout: stdout)
            case "log":
                let limit = Self.maxCount(in: arguments) ?? totalCommits
                let count = max(0, min(limit, totalCommits))
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
}
