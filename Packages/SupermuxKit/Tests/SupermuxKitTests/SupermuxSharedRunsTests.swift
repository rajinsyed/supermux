import Foundation
import Testing
@testable import SupermuxKit

/// Ways the host's per-folder `git status` runs could fail, written before
/// the code. Two clients (the phone and a viewer Mac, or two mirror panels)
/// look at the same folder; one `git status` there can take seconds:
///
/// 1. A request made while a run is in progress gets that run's answer, which
///    started before the change that prompted the request (a commit), so that
///    client keeps stale git colors until some unrelated file changes.
/// 2. Every request made during a run starts its own git afterwards, so slow
///    runs pile up git processes.
/// 3. The follow-up run never starts when the run in progress ends, so its
///    requests only ever time out.
/// 4. A request when nothing runs waits behind a follow-up that never starts.
/// 5. One folder's run holds up another folder's request.
///
/// Serialized: each case holds runs on a gate it opens itself.
@Suite(.serialized)
struct SupermuxSharedRunsTests {
    @Test func requestsDuringARunShareOneRunStartedAfterIt() throws {
        let log = StartLog()
        let runs = SupermuxSharedRuns<Int> { _ in log.run() }
        defer { log.openGate() }

        let first = runs.join("repo")
        try log.waitForStarts(1)
        let later = (0..<3).map { _ in runs.join("repo") }
        #expect(later.allSatisfy { $0 === later[0] })
        #expect(log.starts == 1)

        log.openGate()
        #expect(first.wait(seconds: 5) == 1)
        #expect(later.map { $0.wait(seconds: 5) } == [2, 2, 2])
        #expect(log.starts == 2)
        #expect(log.mostAtOnce == 1)
    }

    @Test func aRequestWhenNothingRunsStartsAtOnce() throws {
        let log = StartLog()
        let runs = SupermuxSharedRuns<Int> { _ in log.run() }
        log.openGate()
        #expect(runs.join("repo").wait(seconds: 5) == 1)
        #expect(runs.join("repo").wait(seconds: 5) == 2)
        #expect(log.starts == 2)
    }

    @Test func anotherFolderDoesNotWait() throws {
        let log = StartLog()
        let runs = SupermuxSharedRuns<Int> { _ in log.run() }
        defer { log.openGate() }
        _ = runs.join("repo")
        try log.waitForStarts(1)
        _ = runs.join("other")
        try log.waitForStarts(2)
    }
}

/// Counts runs; each waits for the gate, then answers its own start number.
private final class StartLog: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = 0
    private var inFlight = 0
    private var most = 0
    private var open = false

    var starts: Int { locked { started } }
    var mostAtOnce: Int { locked { most } }

    func run() -> Int {
        let (number, wait) = locked { () -> (Int, Bool) in
            started += 1
            inFlight += 1
            most = max(most, inFlight)
            return (started, !open)
        }
        if wait {
            gate.wait()
            gate.signal()
        }
        locked { inFlight -= 1 }
        return number
    }

    /// Lets every run (now and later) finish. Opening it again does nothing.
    func openGate() {
        let opening = locked { () -> Bool in
            defer { open = true }
            return !open
        }
        if opening { gate.signal() }
    }

    func waitForStarts(_ count: Int) throws {
        let deadline = Date().addingTimeInterval(5)
        while starts < count {
            guard Date() < deadline else { throw StartTimeout(count: count) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct StartTimeout: Error {
    let count: Int
}
