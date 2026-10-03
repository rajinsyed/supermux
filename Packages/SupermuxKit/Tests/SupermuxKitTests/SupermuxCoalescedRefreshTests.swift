import Foundation
import Testing
@testable import SupermuxKit

/// Ways a coalesced refresh (a mirror's git colors, asked for on every live
/// change, up to once a second, while one `git status` over there can take
/// seconds) could fail, written before the code:
///
/// 1. Every request starts its own run, so slow runs pile up without bound
///    and queue the panel's listings behind them.
/// 2. Two runs overlap.
/// 3. A request made while a run is in flight gets that run's answer, which
///    may predate the change that prompted the request (a stale color).
/// 4. Requests made during a run start one run each afterwards instead of
///    sharing a single re-run.
/// 5. A request made after everything settled never runs (or never answers).
struct SupermuxCoalescedRefreshTests {
    @Test func requestsDuringARunShareOneFreshRerun() async throws {
        let runs = RunLog()
        let refresh = SupermuxCoalescedRefresh<Int>()
        let body: @Sendable () async -> Int = { await runs.run() }

        let first = Task { await refresh.run(body) }
        try await runs.waitForStarts(1)
        let later = (0..<4).map { _ in Task { await refresh.run(body) } }

        #expect(await first.value == 1)
        for request in later {
            #expect(await request.value == 2)
        }
        #expect(await runs.starts == 2)
        #expect(await runs.mostAtOnce == 1)
    }

    @Test func aRequestAfterEverythingSettledRunsAgain() async {
        let runs = RunLog()
        let refresh = SupermuxCoalescedRefresh<Int>()
        let body: @Sendable () async -> Int = { await runs.run() }
        #expect(await refresh.run(body) == 1)
        #expect(await refresh.run(body) == 2)
        #expect(await runs.starts == 2)
    }
}

/// Counts runs; each takes a moment and answers its own number.
private actor RunLog {
    private(set) var starts = 0
    private(set) var mostAtOnce = 0
    private var inFlight = 0

    func run() async -> Int {
        starts += 1
        let number = starts
        inFlight += 1
        mostAtOnce = max(mostAtOnce, inFlight)
        try? await Task.sleep(for: .milliseconds(300))
        inFlight -= 1
        return number
    }

    func waitForStarts(_ count: Int) async throws {
        while starts < count { try await Task.sleep(for: .milliseconds(10)) }
    }
}
