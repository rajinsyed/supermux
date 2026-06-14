import Foundation
import Testing

import CmuxProcess
import SupermuxKit

/// Behavior tests for ``SupermuxChangesModel``'s commit-history loading.
///
/// Uses a recording fake ``CommandRunning`` that answers `git status` and
/// `git log` deterministically (no real process), so the tests assert the
/// load-on-expand, paging, and collapse contracts without timing flakiness.
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

    @Test func expandingLoadsCommitsExactlyOnce() async {
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

    @Test func unchangedHeadSkipsReloadButHeadChangeReloads() async {
        let runner = RecordingRunner(totalCommits: 3)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)
        #expect(await runner.logCallCount() == 1)
        #expect(model.commits.count == 3)

        // A refresh with no HEAD movement must not re-read the log.
        await model.refresh()
        #expect(await runner.logCallCount() == 1)

        // After HEAD moves, the next refresh reloads the log.
        await runner.setHead("head-1")
        await model.refresh()
        #expect(await runner.logCallCount() == 2)
    }

    @Test func pushAheadChangeReloadsUnpushedList() async {
        // Starts ahead by 2; a push drops ahead to 0 without moving HEAD, which
        // the composite signature must treat as a reason to re-read the log.
        let runner = RecordingRunner(totalCommits: 5, ahead: 2)
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))

        model.setDirectory("/repo")
        await model.refresh()
        await model.setHistoryExpanded(true)
        #expect(await runner.logCallCount() == 1)

        await runner.setAhead(0)
        await model.refresh()
        #expect(await runner.logCallCount() == 2)
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

    /// A `CommandRunning` fake that answers `status` with a clean `main`
    /// repository and `log` with `totalCommits` synthetic commits, honoring the
    /// request's `--max-count`. Records every invocation's arguments.
    private actor RecordingRunner: CommandRunning {
        private var calls: [[String]] = []
        private let totalCommits: Int
        private var head: String
        private var ahead: Int

        init(totalCommits: Int, head: String = "head-0", ahead: Int = 0) {
            self.totalCommits = totalCommits
            self.head = head
            self.ahead = ahead
        }

        /// Moves `HEAD`, so the next status read reports a new `branch.oid`.
        func setHead(_ head: String) { self.head = head }

        /// Changes the ahead count (and thus the upstream signature), as a push
        /// or fetch would, without moving `HEAD`.
        func setAhead(_ ahead: Int) { self.ahead = ahead }

        func logCalls() -> [[String]] { calls.filter { $0.first == "log" } }
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
            switch arguments.first {
            case "status":
                var stdout = "# branch.oid \(head)\n# branch.head main\n"
                if ahead > 0 {
                    stdout += "# branch.upstream origin/main\n# branch.ab +\(ahead) -0\n"
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
