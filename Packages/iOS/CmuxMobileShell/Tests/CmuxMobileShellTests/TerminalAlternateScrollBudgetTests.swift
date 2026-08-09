import Testing

@testable import CmuxMobileShell

@Suite("Terminal alternate-screen scroll budget")
struct TerminalAlternateScrollBudgetTests {
    @Test("a burst passes through untouched and preserves sign")
    func burstPassesThrough() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        #expect(budget.admit(lines: -4, at: 10.0) == -4)
        #expect(budget.admit(lines: 2, at: 10.01) == 2)
    }

    @Test("a fast drag's surplus is dropped, not deferred")
    func fastDragSurplusIsDropped() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        // A 300 ms fast drag emitting ~40 lines: 6 burst + 0.3 s × 30/s = 15.
        var delivered = 0.0
        var now = 20.0
        for _ in 0..<10 {
            delivered += budget.admit(lines: 4, at: now)
            now += 0.03
        }

        #expect(delivered < 16)
        // The dropped surplus never plays back later: after a long idle only
        // one fresh burst is available, not the deferred remainder.
        #expect(budget.admit(lines: 40, at: now + 10) == 6)
    }

    @Test("a sustained slow drag is never throttled")
    func slowDragUnthrottled() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        // 0.5 line every 60 Hz frame ≈ 30 lines/second, exactly the refill.
        var now = 30.0
        for _ in 0..<60 {
            #expect(budget.admit(lines: 0.5, at: now) == 0.5)
            now += 1.0 / 60.0
        }
    }

    @Test("direction reversal spends magnitude, not signed sum")
    func reversalSpendsMagnitude() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        #expect(budget.admit(lines: 4, at: 40.0) == 4)
        // Only 2 of the reversed 5 remain in the bucket; a signed sum would
        // wrongly restore capacity and admit all 5.
        #expect(budget.admit(lines: -5, at: 40.0) == -2)
    }

    @Test("a backwards clock step admits nothing extra, even after recovery")
    func backwardsClockIsSafe() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        #expect(budget.admit(lines: 6, at: 50.0) == 6)
        #expect(budget.admit(lines: 6, at: 49.0) == 0)
        // The stored refill timestamp must not move backwards: a recovered
        // clock at the original time has zero NEW elapsed time, so a bucket
        // drained at t=50 cannot double-count the 49→50 interval.
        #expect(budget.admit(lines: 6, at: 50.0) == 0)
    }

    @Test("an exhausted burst admits only refilled capacity on reversal")
    func exhaustedBurstReversal() {
        var budget = TerminalAlternateScrollBudget(
            burstLines: 6,
            refillLinesPerSecond: 30
        )

        #expect(budget.admit(lines: 6, at: 70.0) == 6)
        // 50 ms later the user reverses hard: only the ~1.5 refilled lines
        // are admitted. The in-flight burst cannot be recalled, so reversal
        // must not receive a fresh full burst on top of it.
        #expect(abs(budget.admit(lines: -6, at: 70.05) - (-1.5)) < 0.001)
    }

    @Test("zero lines are a no-op")
    func zeroLinesNoOp() {
        var budget = TerminalAlternateScrollBudget()

        #expect(budget.admit(lines: 0, at: 60.0) == 0)
    }

    @Test("the budget cap scales with the user's scroll-speed preference")
    func budgetScalesWithScrollSpeed() {
        // The same saturating fast drag at three speeds. If the cap were
        // absolute, all three would deliver identical totals and the Settings
        // slider would be invisible on TUIs (the reported dogfood bug).
        func delivered(atSpeed speed: Double) -> Double {
            var budget = TerminalAlternateScrollBudget(
                burstLines: 4,
                refillLinesPerSecond: 20
            )
            var now = 100.0
            var total = 0.0
            for _ in 0..<26 {
                // A fast drag's per-frame gesture delta (0.85 unscaled lines),
                // pre-scaled by the preference as the surface does.
                total += abs(budget.admit(lines: -0.85 * speed, speed: speed, at: now))
                now += 0.0125
            }
            return total
        }

        let slow = delivered(atSpeed: 0.5)
        let normal = delivered(atSpeed: 1.0)
        let fast = delivered(atSpeed: 1.5)

        #expect(abs(slow - normal * 0.5) < 0.001)
        #expect(abs(fast - normal * 1.5) < 0.001)
        #expect(slow < normal)
        #expect(normal < fast)
    }

    @Test("physical trace gestures hit the limiter")
    func physicalTraceGestureIsBounded() {
        // Replays the shape of the traced fast gesture G5: ~26 flushes over
        // ~0.32 s totaling ~5.3 lines while dragging, followed by the burst
        // the backlog theory blames — the same drag at 4× speed.
        var budget = TerminalAlternateScrollBudget(
            burstLines: 4,
            refillLinesPerSecond: 20
        )

        var now = 80.0
        var delivered = 0.0
        for _ in 0..<26 {
            delivered += abs(budget.admit(lines: -0.85, at: now))
            now += 0.0125
        }

        // 22.1 requested lines in 0.325 s: the budget must cap delivery near
        // burst + elapsed × refill (4 + 6.5), proving a fast drag cannot pile
        // up a multi-second TUI replay.
        #expect(delivered <= 11)
        #expect(delivered >= 8)
    }
}
