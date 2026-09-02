import CmuxFoundation
import Foundation
import Testing

@testable import SupermuxKit

/// Ordering contract for `SupermuxChangesModel.fileDiffPatch(for:staged:)`:
/// when a second row is activated before the first capture finishes, the
/// first capture is superseded and yields nothing, so a slow older diff can
/// never land after (and over) the newer one.
///
/// Uses a gated fake ``CommandRunning`` (no real git) so the completion order
/// is controlled by the test rather than by process timing.
@MainActor
@Suite struct SupermuxChangesFileDiffOrderingTests {

    private func change(_ path: String) -> SupermuxGitFileChange {
        SupermuxGitFileChange(path: path, oldPath: nil, kind: .modified)
    }

    @Test func supersededCaptureYieldsNothingEvenWhenItFinishesLast() async throws {
        let runner = GatedRunner(gatedPathFragment: "first.txt")
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))
        model.setDirectory("/repo")

        let first = Task { await model.fileDiffPatch(for: change("first.txt"), staged: false) }
        while await runner.gatedCallCount() == 0 { await Task.yield() }

        let second = await model.fileDiffPatch(for: change("second.txt"), staged: false)
        await runner.openGate()
        let firstPatch = await first.value

        #expect(second?.change.path == "second.txt")
        #expect(firstPatch == nil)
        #expect(model.lastError == nil)
    }

    @Test func aLoneCaptureStillYieldsItsPatch() async {
        let runner = GatedRunner(gatedPathFragment: "never-gated")
        let model = SupermuxChangesModel(service: SupermuxGitChangesService(runner: runner))
        model.setDirectory("/repo")

        let patch = await model.fileDiffPatch(for: change("only.txt"), staged: false)

        #expect(patch?.change.path == "only.txt")
    }

    // MARK: - Fake runner

    /// Answers every git pipeline with a small base64-armored text diff, but
    /// holds any invocation whose script names `gatedPathFragment` until
    /// ``openGate()`` is called.
    private actor GatedRunner: CommandRunning {
        private let gatedPathFragment: String
        private var isGateOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var gatedCalls = 0

        init(gatedPathFragment: String) {
            self.gatedPathFragment = gatedPathFragment
        }

        func gatedCallCount() -> Int { gatedCalls }

        func openGate() {
            isGateOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
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
            let script = arguments.last ?? ""
            if script.contains(gatedPathFragment) {
                gatedCalls += 1
                if !isGateOpen {
                    await withCheckedContinuation { waiters.append($0) }
                }
            }
            let diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n"
            return CommandResult(
                stdout: Data(diff.utf8).base64EncodedString(), stderr: nil,
                exitStatus: 0, timedOut: false, executionError: nil
            )
        }
    }
}
