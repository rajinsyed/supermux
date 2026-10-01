import Foundation
import Testing
@testable import SupermuxKit

/// Ways the host's file lookups on a device RPC path could fail, written
/// before the code. `projects.list` stats every project's icon; a project in
/// ~/Documents while macOS's privacy prompt for it is unanswered (nobody
/// answers it on a headless Mac) blocks that stat in the kernel indefinitely:
///
/// 1. A stuck lookup holds its caller past the bound, so the viewer's reply
///    deadline passes and the whole device link reconnects.
/// 2. Each request starts another lookup on the stuck path, so every retry
///    strands one more thread.
/// 3. Lookups run on Swift's cooperative pool, so a dozen stuck ones wedge
///    the app (socket, timers, Quit).
/// 4. A lookup that finishes in time is answered as missing.
/// 5. One stuck path hides the values of the other paths.
/// 6. After a stuck lookup ends, its path is never looked up again.
/// 7. A call whose lookups all finished still waits for the bound.
///
/// Stuck lookups wait on a gate a watchdog opens after 3 s, so a failing case
/// fails its timing check instead of hanging the run.
@Suite(.serialized)
struct SupermuxBoundedLookupsTests {
    @Test func aStuckLookupAnswersAtTheBound() async {
        let gate = Gate()
        let lookups = SupermuxBoundedLookups<Int>()
        let started = ContinuousClock.now
        let values = await lookups.values(["stuck": { gate.wait(); return 1 }], timeout: 0.2)
        #expect(values.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
        gate.open()
    }

    @Test func aStuckKeyIsJoinedNotStartedAgain() async {
        let gate = Gate()
        let starts = Counter()
        let lookups = SupermuxBoundedLookups<Int>()
        let stuck: @Sendable () -> Int = {
            starts.increment()
            gate.wait()
            return 1
        }
        _ = await lookups.values(["icon": stuck], timeout: 0.1)
        _ = await lookups.values(["icon": stuck], timeout: 0.1)
        _ = await lookups.value("icon", timeout: 0.1, lookup: stuck)
        #expect(starts.value == 1)
        gate.open()
    }

    @Test func stuckLookupsLeaveSwiftConcurrencyFree() async {
        let gate = Gate()
        let lookups = SupermuxBoundedLookups<Int>()
        let stuck = 4 * ProcessInfo.processInfo.activeProcessorCount
        var all: [String: @Sendable () -> Int] = [:]
        for index in 0..<stuck { all["path-\(index)"] = { gate.wait(); return index } }
        _ = await lookups.values(all, timeout: 0.1)
        let started = ContinuousClock.now
        let answer = await Task.detached { 42 }.value
        #expect(answer == 42)
        #expect(ContinuousClock.now - started < .seconds(1))
        gate.open()
    }

    @Test func aStuckKeyDoesNotHideAnother() async {
        let gate = Gate()
        let lookups = SupermuxBoundedLookups<String>()
        let values = await lookups.values([
            "stuck": { gate.wait(); return "late" },
            "quick": { "fine" },
        ], timeout: 0.3)
        #expect(values == ["quick": "fine"])
        gate.open()
    }

    @Test func aKeyIsLookedUpAgainAfterItsLookupEnds() async throws {
        let gate = Gate()
        let starts = Counter()
        let lookups = SupermuxBoundedLookups<Int>()
        let lookup: @Sendable () -> Int = {
            let number = starts.increment()
            if number == 1 { gate.wait() }
            return number
        }
        #expect(await lookups.value("icon", timeout: 0.1, lookup: lookup) == nil)
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await lookups.value("icon", timeout: 2, lookup: lookup) == 2)
    }

    @Test func finishedLookupsAnswerAtOnceWithTheirValues() async {
        let lookups = SupermuxBoundedLookups<Int>()
        let started = ContinuousClock.now
        let values = await lookups.values(["a": { 1 }, "b": { 2 }], timeout: 5)
        #expect(values == ["a": 1, "b": 2])
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}

/// Holds stuck lookups until opened; a watchdog opens it after 3 s.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isOpen = false

    init() {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 3)
            open()
        }
    }

    func wait() {
        semaphore.wait()
        semaphore.signal()
    }

    func open() {
        lock.lock()
        let opening = !isOpen
        isOpen = true
        lock.unlock()
        if opening { semaphore.signal() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
