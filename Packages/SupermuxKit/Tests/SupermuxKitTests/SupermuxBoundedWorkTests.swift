import Foundation
import Testing
@testable import SupermuxKit

/// Ways the host's bound on one `files.*` call could fail, written before the
/// code. The call runs blocking file I/O (a listing on a stalled volume, a
/// multi-GB duplicate, a trash of many items) for another Mac, which waits
/// with a reply deadline that makes the whole device link reconnect when it
/// is missed:
///
/// 1. Work that finishes in time answers with something else (the fallback),
///    so a fast call reads as timed out.
/// 2. Work that runs past the bound holds the answer until it finishes, so
///    the viewer misses its deadline anyway.
/// 3. Work that finishes after the bound resumes the caller a second time
///    (a crash) or replaces the answer already sent.
/// 4. Stuck work runs on Swift's cooperative pool, so a handful of stuck
///    calls starves every other task in the app.
struct SupermuxBoundedWorkTests {
    @Test func workThatFinishesInTimeAnswersWithItsOwnValue() async {
        let value = await SupermuxBoundedWork(timeout: 5).run({ "done" }, orAfterTimeout: { "timed out" })
        #expect(value == "done")
    }

    @Test func workPastTheBoundAnswersAtTheBound() async {
        let gate = DispatchSemaphore(value: 0)
        let clock = ContinuousClock()
        let started = clock.now
        let value = await SupermuxBoundedWork(timeout: 0.2).run({
            gate.wait()
            return "done"
        }, orAfterTimeout: { "timed out" })
        let waited = clock.now - started
        gate.signal()
        #expect(value == "timed out")
        #expect(waited < .seconds(2))
    }

    @Test func workThatFinishesLateIsIgnored() async throws {
        let finished = LateFinish()
        let value = await SupermuxBoundedWork(timeout: 0.1).run({
            Thread.sleep(forTimeInterval: 0.3)
            finished.mark()
            return 1
        }, orAfterTimeout: { 0 })
        #expect(value == 0)
        // Outlive the late finish: resuming the caller again would trap here.
        try await Task.sleep(for: .milliseconds(600))
        #expect(finished.isMarked)
    }

    @Test func stuckWorkLeavesSwiftConcurrencyFree() async {
        let gate = DispatchSemaphore(value: 0)
        let stuck = 4 * ProcessInfo.processInfo.activeProcessorCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<stuck {
                group.addTask {
                    _ = await SupermuxBoundedWork(timeout: 0.05).run({
                        gate.wait()
                        return 0
                    }, orAfterTimeout: { -1 })
                }
            }
            await group.waitForAll()
        }
        let clock = ContinuousClock()
        let started = clock.now
        let answer = await Task.detached { 42 }.value
        #expect(answer == 42)
        #expect(clock.now - started < .seconds(1))
        for _ in 0..<stuck { gate.signal() }
    }
}

/// Records that work ran to its end after its caller was answered.
private final class LateFinish: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}
