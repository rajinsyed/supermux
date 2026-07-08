import Foundation

/// Polls a main-actor condition until it holds or the deadline passes.
/// Store tests await asynchronous state transitions (run-loop fetches,
/// event-driven refetches) through this instead of fixed sleeps.
struct TestWait {
    var timeout: Duration = .seconds(5)

    struct TimedOut: Error {}

    @MainActor
    func until(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
