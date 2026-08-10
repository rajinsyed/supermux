// SUPERMUX:begin supermux-mobile-selection-sync
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspacePanelStreamActivationSequenceTests {
    @Test func focusAndPreviousStopCompleteBeforeCurrentStreamStarts() async {
        let (focusStream, focusContinuation) = AsyncStream<Void>.makeStream()
        let (stopStream, stopContinuation) = AsyncStream<Void>.makeStream()
        var events: [String] = []
        let focusTask = Task { @MainActor in
            for await _ in focusStream { break }
            events.append("focus")
            return true
        }

        let activation = Task { @MainActor in
            await WorkspacePanelStreamActivationSequence.run(
                focusTask: focusTask,
                isSelectionCurrent: { true },
                stopPrevious: {
                    events.append("stop")
                    for await _ in stopStream { break }
                },
                abandonCurrent: {
                    events.append("abandon")
                },
                startCurrent: {
                    events.append("start")
                }
            )
        }

        await Task.yield()
        #expect(events.isEmpty)

        focusContinuation.yield(())
        focusContinuation.finish()
        await waitUntil { events.count == 2 }
        #expect(events == ["focus", "stop"])

        stopContinuation.yield(())
        stopContinuation.finish()
        await activation.value
        #expect(events == ["focus", "stop", "start"])
    }

    @Test func staleSelectionStillStopsPreviousAndAbandonsCurrent() async {
        var events: [String] = []

        await WorkspacePanelStreamActivationSequence.run(
            focusTask: nil,
            isSelectionCurrent: { false },
            stopPrevious: { events.append("stop") },
            abandonCurrent: { events.append("abandon") },
            startCurrent: { events.append("start") }
        )

        #expect(events == ["stop", "abandon"])
    }

    @Test func selectionChangingDuringStopCannotStartOlderPanel() async {
        let (stopStream, stopContinuation) = AsyncStream<Void>.makeStream()
        var isCurrent = true
        var events: [String] = []
        let activation = Task { @MainActor in
            await WorkspacePanelStreamActivationSequence.run(
                focusTask: nil,
                isSelectionCurrent: { isCurrent },
                stopPrevious: {
                    events.append("stop")
                    for await _ in stopStream { break }
                },
                abandonCurrent: { events.append("abandon") },
                startCurrent: { events.append("start") }
            )
        }

        await waitUntil { events == ["stop"] }
        isCurrent = false
        stopContinuation.yield(())
        stopContinuation.finish()
        await activation.value

        #expect(events == ["stop", "abandon"])
    }

    @Test func failedFocusStopsPreviousButNeverStartsCurrent() async {
        var events: [String] = []
        let focusTask = Task { @MainActor in false }

        await WorkspacePanelStreamActivationSequence.run(
            focusTask: focusTask,
            isSelectionCurrent: { true },
            stopPrevious: { events.append("stop") },
            abandonCurrent: { events.append("abandon") },
            startCurrent: { events.append("start") }
        )

        #expect(events == ["stop", "abandon"])
    }

    private func waitUntil(
        _ condition: () -> Bool
    ) async {
        for _ in 0..<1_000 {
            guard !condition() else { return }
            await Task.yield()
        }
    }
}
// SUPERMUX:end supermux-mobile-selection-sync
