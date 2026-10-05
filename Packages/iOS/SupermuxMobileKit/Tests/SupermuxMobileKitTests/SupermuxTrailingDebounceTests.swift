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
/// 5. A burst that never pauses for the settle time (a flapping Wi-Fi, a
///    path update every 900 ms) is never acted on (second review #11).
/// 6. After acting on a long burst, the next update waits out the maximum
///    from the burst before, not a settle of its own.
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
        private var durations: [Duration] = []

        var startedCount: Int { lock.withLock { started } }
        /// What each timer was started for, in order.
        var requested: [Duration] { lock.withLock { durations } }

        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    started += 1
                    durations.append(duration)
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

    /// A clock the test moves by hand.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private var offset: Duration = .zero
        var now: ContinuousClock.Instant { lock.withLock { origin.advanced(by: offset) } }
        func set(_ elapsed: Duration) { lock.withLock { offset = elapsed } }
    }

    @Test("5 and 6. a burst that never pauses acts at most 5 s after its first poke")
    func aBurstThatNeverPausesActsWithinTheMaximumWait() async throws {
        let timer = ManualTimer()
        let clock = ManualClock()
        let recorder = Recorder()
        let debounce = SupermuxTrailingDebounce(
            settle: .seconds(1), maximumWait: .seconds(5),
            now: { clock.now }, sleep: { try await timer.sleep($0) })
        // A poke every 900 ms: never a second's quiet.
        let pokes: [Duration] = [.zero, .milliseconds(900), .milliseconds(1800), .milliseconds(2700),
                                 .milliseconds(3600), .milliseconds(4500), .milliseconds(5400)]
        for (index, time) in pokes.enumerated() {
            clock.set(time)
            debounce.poke { recorder.append(index) }
            try await waitUntil { timer.startedCount == index + 1 }
        }
        let waits = timer.requested
        #expect(Array(waits.prefix(5)) == Array(repeating: .seconds(1), count: 5))
        #expect(waits[5] == .milliseconds(500), "the poke at 4.5 s waited past 5 s: \(waits[5])")
        #expect(waits[6] == .zero, "the poke at 5.4 s waited again: \(waits[6])")
        timer.fireAll()
        try await waitUntil { !recorder.values.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values == [6], "acted on \(recorder.values)")
        // A poke after acting starts a new burst with the full settle time.
        clock.set(.milliseconds(5600))
        debounce.poke { recorder.append(7) }
        try await waitUntil { timer.startedCount == pokes.count + 1 }
        #expect(timer.requested.last == .seconds(1))
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
