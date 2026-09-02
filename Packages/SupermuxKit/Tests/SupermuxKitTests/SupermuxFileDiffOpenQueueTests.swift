import Foundation
import Testing

@testable import SupermuxKit

/// Contract tests for ``SupermuxFileDiffOpenQueue``: one open per workspace at
/// a time, later clicks during a flight supersede earlier ones instead of
/// being dropped or stacking tabs, and viewer/source panes are remembered.
struct SupermuxFileDiffOpenQueueTests {
    private let workspace = UUID()
    private let otherWorkspace = UUID()

    private func patch(_ path: String) -> SupermuxFileDiffPatch {
        SupermuxFileDiffPatch(
            repoPath: "/repo", change: SupermuxGitFileChange(path: path, oldPath: nil, kind: .modified),
            staged: false, patch: "diff", truncated: false
        )
    }

    @Test func firstClickLaunchesImmediately() {
        var queue = SupermuxFileDiffOpenQueue()

        #expect(queue.requestOpen(patch("a.txt"), in: workspace) == true)
        #expect(queue.state(for: workspace).isInFlight)
        #expect(queue.state(for: workspace).pending == nil)
    }

    @Test func clicksDuringAFlightQueueAndTheLatestWins() {
        var queue = SupermuxFileDiffOpenQueue()
        _ = queue.requestOpen(patch("a.txt"), in: workspace)

        #expect(queue.requestOpen(patch("b.txt"), in: workspace) == false)
        #expect(queue.requestOpen(patch("c.txt"), in: workspace) == false)

        let viewer = UUID()
        let next = queue.finishOpen(in: workspace, openedSurface: viewer)
        #expect(next == patch("c.txt"))
        #expect(queue.state(for: workspace).isInFlight, "the queued patch is launched by the caller")
        #expect(queue.state(for: workspace).openedSurface == viewer)

        let replacement = UUID()
        #expect(queue.finishOpen(in: workspace, openedSurface: replacement) == nil)
        #expect(queue.state(for: workspace).isInFlight == false)
        #expect(queue.state(for: workspace).openedSurface == replacement)
    }

    @Test func aFailedFlightKeepsThePreviousViewerAndStillLaunchesTheQueuedClick() {
        var queue = SupermuxFileDiffOpenQueue()
        let viewer = UUID()
        _ = queue.requestOpen(patch("a.txt"), in: workspace)
        _ = queue.finishOpen(in: workspace, openedSurface: viewer)
        _ = queue.requestOpen(patch("b.txt"), in: workspace)
        _ = queue.requestOpen(patch("c.txt"), in: workspace)

        #expect(queue.abandonOpen(in: workspace) == patch("c.txt"))
        #expect(queue.state(for: workspace).openedSurface == viewer)
        #expect(queue.abandonOpen(in: workspace) == nil)
        #expect(queue.state(for: workspace).isInFlight == false)
    }

    @Test func workspacesAreIndependent() {
        var queue = SupermuxFileDiffOpenQueue()
        _ = queue.requestOpen(patch("a.txt"), in: workspace)

        #expect(queue.requestOpen(patch("b.txt"), in: otherWorkspace) == true)
        #expect(queue.finishOpen(in: otherWorkspace, openedSurface: nil) == nil)
        #expect(queue.state(for: workspace).isInFlight)
    }

    @Test func recordLaunchRemembersTheReplacedViewerAndSourcePane() {
        var queue = SupermuxFileDiffOpenQueue()
        let source = UUID()
        _ = queue.requestOpen(patch("a.txt"), in: workspace)

        queue.recordLaunch(previousSurface: nil, sourceSurface: source, in: workspace)

        #expect(queue.state(for: workspace).sourceSurface == source)
        #expect(queue.state(for: workspace).openedSurface == nil)
        _ = queue.finishOpen(in: workspace, openedSurface: UUID())
        #expect(queue.state(for: workspace).sourceSurface == source, "the source pane survives the flight")
    }
}
