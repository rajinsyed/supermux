import Foundation
import SupermuxMobileKit
import Testing

/// The phone's network-change debounce (review finding I2). Failure modes,
/// listed before the code:
///
/// 1. The first path update of a burst is acted on and the later ones are
///    dropped, so the network is judged halfway through a move (Wi-Fi gone,
///    cellular not up yet) and never again.
/// 2. Every update of a burst is acted on (a probe and a check per update).
/// 3. The action runs before the network has been quiet for the settle time.
/// 4. A cancel leaves the pending action to run.
@Suite struct SupermuxTrailingDebounceTests {
    /// Records which pokes acted.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var acted: [Int] = []
        var values: [Int] { lock.withLock { acted } }
        func append(_ value: Int) { lock.withLock { acted.append(value) } }
    }

    /// A timer that fires only when the test says so.
    private final class ManualTimer: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, any Error>] = []
        private var started = 0

        var startedCount: Int { lock.withLock { started } }

        func sleep(_: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    started += 1
                    waiters.append(continuation)
                }
            }
            try Task.checkCancellation()
        }

        /// Fires every timer started so far.
        func fireAll() {
            let fired = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { waiters = [] }
                return waiters
            }
            for waiter in fired { waiter.resume() }
        }
    }

    @Test("1 and 2. a burst acts once, on its last poke")
    func aBurstActsOnceOnItsLastPoke() async throws {
        let timer = ManualTimer()
        let recorder = Recorder()
        let debounce = SupermuxTrailingDebounce(settle: .seconds(1), sleep: { try await timer.sleep($0) })
        for poke in 1...3 {
            debounce.poke { recorder.append(poke) }
        }
        try await waitUntil { timer.startedCount == 3 }
        timer.fireAll()
        try await waitUntil { !recorder.values.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values == [3], "acted on \(recorder.values)")
    }

    @Test("3. nothing runs before the settle time")
    func nothingRunsBeforeTheSettleTime() async throws {
        let recorder = Recorder()
        let debounce = SupermuxTrailingDebounce(settle: .milliseconds(300))
        debounce.poke { recorder.append(1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.isEmpty, "acted before the network settled")
        try await waitUntil { recorder.values == [1] }
    }

    @Test("4. a cancel drops the pending action")
    func cancelDropsThePendingAction() async throws {
        let timer = ManualTimer()
        let recorder = Recorder()
        let debounce = SupermuxTrailingDebounce(settle: .seconds(1), sleep: { try await timer.sleep($0) })
        debounce.poke { recorder.append(1) }
        try await waitUntil { timer.startedCount == 1 }
        debounce.cancel()
        timer.fireAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.isEmpty)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
