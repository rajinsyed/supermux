import Foundation
import Testing
@testable import SupermuxZeronUI

/// The shared 30 fps loader clock's lease and park behavior (spec 07 §5.1, plan R12).
///
/// The clock is driven through an injected `now`, so nothing here waits on wall
/// time and the lease expiry is exercised deterministically.
@MainActor
struct SupermuxZeronPulseClockTests {

    /// A hand-advanced clock source.
    private final class Ticker: @unchecked Sendable {
        // lint:allow lock — a test-only counter mutated and read from one
        // actor; an actor here would make the `@Sendable` closure async.
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 1_000)

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                return instant
            }
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            instant = instant.addingTimeInterval(seconds)
        }
    }

    /// A `Sendable` one-way flag, for `withObservationTracking`'s escaping
    /// `onChange`.
    private final class Flag: @unchecked Sendable {
        // lint:allow lock — a test-only boolean touched from an escaping
        // `@Sendable` closure and read back synchronously.
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - Lease

    @Test("A clock with no leases is parked and schedules nothing")
    func startsParked() {
        let clock = SupermuxZeronPulseClock(now: Ticker().now)
        #expect(!clock.isRunning)
        #expect(clock.leaseCount == 0)
    }

    @Test("Reading a phase takes a lease and starts the clock")
    func leaseStartsTheClock() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        _ = clock.phase(period: 0.75, leasedBy: "working-indicator")
        #expect(clock.isRunning)
        #expect(clock.leaseCount == 1)
    }

    @Test("A lease survives a few missed frames, then expires at 300 ms")
    func leaseExpiresAfterTheGrace() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        _ = clock.phase(period: 0.75, leasedBy: "spinner")

        // Well inside the 300 ms lease: still live, even though the view has
        // not painted since. "One lease outlives a few missed frames."
        ticker.advance(0.2)
        #expect(clock.tick())
        #expect(clock.leaseCount == 1)

        // Past it: pruned, and the clock parks.
        ticker.advance(0.2)
        #expect(!clock.tick())
        #expect(clock.leaseCount == 0)
        #expect(!clock.isRunning, "an empty lease set must PARK the clock entirely")
    }

    @Test("Re-reading the phase renews the lease indefinitely")
    func repaintRenewsTheLease() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        for _ in 0..<50 {
            _ = clock.phase(period: 0.75, leasedBy: "spinner")
            ticker.advance(SupermuxZeronMetrics.PulseClock.tickInterval)
            #expect(clock.tick())
        }
        #expect(clock.leaseCount == 1)
        #expect(clock.isRunning)
    }

    @Test("Reading the phase OBSERVES the frame counter, so a tick re-renders the spinner")
    func phaseObservesTheFrameCounter() {
        // ── The bug this exists to catch ───────────────────────────────────
        //
        // The spinner's only observable read is `phase(period:leasedBy:)`. If
        // that function never touches the `@Observable` `frame` property, then
        // SwiftUI registers NO dependency for the spinner's body: the clock
        // ticks 30 times a second, bumps `frame`, and wakes nobody. The spinner
        // evaluates its body exactly once and freezes at whatever phase it
        // mounted on — while the lease machinery cheerfully keeps a 30 fps timer
        // alive to drive an animation that never advances.
        //
        // Measured in a hosted SwiftUI view before the fix: 1 body evaluation
        // over 20 ticks. After: 21. That is the whole working indicator.
        //
        // `withObservationTracking` is exactly the mechanism SwiftUI uses, so
        // asserting through it tests the real dependency rather than a proxy.
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        // `onChange` is a `@Sendable` escaping closure, so the flag lives in a
        // reference box rather than a captured `var`.
        let notified = Flag()
        withObservationTracking {
            _ = clock.phase(period: 0.75, leasedBy: "working-indicator")
        } onChange: {
            notified.set()
        }
        #expect(clock.isRunning)
        // A tick that publishes a frame must invalidate the tracked read.
        ticker.advance(SupermuxZeronMetrics.PulseClock.tickInterval)
        _ = clock.tick()
        #expect(
            notified.isSet,
            "phase() must READ `frame`, or every loader in the app is frozen"
        )
    }

    @Test("Reduced motion neither observes nor leases, so it schedules nothing")
    func reducedMotionDoesNotObserve() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        // Keep the clock alive through a second, real leaseholder so that
        // `tick()` genuinely publishes a frame.
        _ = clock.phase(period: 0.75, leasedBy: "other")
        let notified = Flag()
        withObservationTracking {
            _ = clock.phase(period: 0.75, leasedBy: "reduced", reduceMotion: true)
        } onChange: {
            notified.set()
        }
        ticker.advance(SupermuxZeronMetrics.PulseClock.tickInterval)
        _ = clock.tick()
        #expect(
            !notified.isSet,
            "a reduced-motion loader must be a STATIC 0 — no observation, no frames"
        )
    }

    @Test("One spinner scrolling out of the list parks the clock; the other keeps it")
    func multipleLeases() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        _ = clock.phase(period: 0.75, leasedBy: "a")
        _ = clock.phase(period: 2.4, leasedBy: "b")
        #expect(clock.leaseCount == 2)

        // Only `a` keeps painting.
        ticker.advance(0.4)
        _ = clock.phase(period: 0.75, leasedBy: "a")
        #expect(clock.tick())
        #expect(clock.leaseCount == 1, "`b` stopped renewing and must be pruned")
        #expect(clock.isRunning)

        // Now `a` stops too.
        ticker.advance(0.4)
        #expect(!clock.tick())
        #expect(!clock.isRunning)
    }

    @Test("Releasing the last lease parks immediately")
    func explicitReleaseParks() {
        let clock = SupermuxZeronPulseClock(now: Ticker().now)
        _ = clock.phase(period: 0.75, leasedBy: "spinner")
        #expect(clock.isRunning)
        clock.releaseLease("spinner")
        #expect(!clock.isRunning)
        #expect(clock.leaseCount == 0)
    }

    @Test("The frame counter only advances while something is leased")
    func frameCounterAdvancesOnlyWhenLeased() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        #expect(clock.frame == 0)
        _ = clock.phase(period: 0.75, leasedBy: "spinner")
        _ = clock.tick()
        _ = clock.tick()
        #expect(clock.frame == 2)
        // Lease lapses: the tick that prunes it must NOT publish a frame, or a
        // parked clock would still wake every view that read it.
        ticker.advance(1)
        _ = clock.tick()
        #expect(clock.frame == 2)
    }

    // MARK: - Reduced motion

    @Test("Reduced motion returns a static 0 and schedules NOTHING")
    func reducedMotionSchedulesNothing() {
        let clock = SupermuxZeronPulseClock(now: Ticker().now)
        let phase = clock.phase(period: 0.75, leasedBy: "spinner", reduceMotion: true)
        #expect(phase == 0)
        #expect(clock.leaseCount == 0, "reduced motion must not take a lease")
        #expect(!clock.isRunning, "…and must not start the clock")
    }

    // MARK: - The shared epoch

    @Test("Every loader derives its phase from ONE epoch, so they are phase-locked")
    func sharedEpochPhaseLock() {
        let ticker = Ticker()
        let clock = SupermuxZeronPulseClock(now: ticker.now)
        // A spinner that mounts NOW.
        let first = clock.phase(period: 0.75, leasedBy: "a")
        // A second spinner mounting 0.3 s later joins the wave already in
        // progress instead of restarting it — which is exactly what a per-view
        // start time would break.
        ticker.advance(0.3)
        let second = clock.phase(period: 0.75, leasedBy: "b")
        #expect(second != first)
        // 1e-7, not 1e-9: `Date`'s seconds-since-reference storage is a `Double`
        // around 7.8e8, so a 0.3 s advance lands ~6e-8 off in the last bits.
        // That is float noise in the CLOCK, not in the phase math — a tolerance
        // tighter than the timebase's own resolution tests nothing useful.
        #expect(abs(second - (first + 0.4)) < 1e-7, "0.3 s of a 0.75 s period is 0.4 phase")
        // And two spinners read at the SAME instant are identical.
        let third = clock.phase(period: 0.75, leasedBy: "c")
        #expect(third == second)
    }

    @Test("Phase is always in [0, 1) and wraps at the period")
    func phaseWraps() {
        let epoch = Date(timeIntervalSince1970: 0)
        for elapsed in stride(from: 0.0, through: 3.0, by: 0.05) {
            let phase = SupermuxZeronPulseClock.phase(
                epoch: epoch,
                now: epoch.addingTimeInterval(elapsed),
                period: 0.75
            )
            #expect(phase >= 0 && phase < 1, "phase \(phase) escaped [0, 1) at t=\(elapsed)")
        }
        // Exactly one period is phase 0 again.
        #expect(
            SupermuxZeronPulseClock.phase(
                epoch: epoch,
                now: epoch.addingTimeInterval(0.75),
                period: 0.75
            ) == 0
        )
        // A degenerate period must not divide by zero.
        #expect(
            SupermuxZeronPulseClock.phase(
                epoch: epoch,
                now: epoch.addingTimeInterval(1),
                period: 0
            ) == 0
        )
    }

    // MARK: - The spinner's own math

    @Test("The 3×3 wave travels UPWARD and is symmetric about the centre column")
    func gradientWaveTravelsUpward() {
        let phase = SupermuxZeronMetrics.Loaders.matrixCellPhase
        // Resolved table from spec 07 §5.3.
        #expect(phase(0, 0) == 0.75)
        #expect(phase(0, 1) == 0.50)
        #expect(phase(0, 2) == 0.75)
        #expect(phase(1, 0) == 0.50)
        #expect(phase(1, 1) == 0.25)
        #expect(phase(1, 2) == 0.50)
        #expect(phase(2, 0) == 0.25)
        #expect(phase(2, 1) == 0.00)
        #expect(phase(2, 2) == 0.25)
        // The bottom-centre cell LEADS; the top corners trail.
        for row in 0..<3 {
            for col in 0..<3 {
                #expect(phase(2, 1) <= phase(row, col))
            }
            // Symmetry about the centre column.
            #expect(phase(row, 0) == phase(row, 2))
        }
    }

    @Test("`gspinOpacity` is piecewise LINEAR with a flat rest band")
    func gspinOpacityShape() {
        let f = SupermuxZeronMetrics.Loaders.gspinOpacity
        let dim = SupermuxZeronMetrics.Loaders.gspinDim
        // Full at 0, easing linearly down to `dim` by 45 %.
        #expect(abs(f(0, dim) - 1) < 1e-9)
        #expect(abs(f(0.225, dim) - 0.55) < 1e-9, "the midpoint of a LINEAR ramp is 0.55")
        #expect(abs(f(0.45, dim) - dim) < 1e-9)
        // The flat rest band, 45 %→92 % — this is what makes the wave read as a
        // travelling pulse rather than a sine breathe. Do not smooth it.
        #expect(f(0.5, dim) == dim)
        #expect(f(0.7, dim) == dim)
        #expect(f(0.919, dim) == dim)
        // Snapping back up over the last 8 %.
        #expect(abs(f(0.96, dim) - (dim + (1 - dim) * 0.5)) < 1e-9)
        // The last 8 % is a linear ramp, so at t = 0.9999 it has covered
        // 0.0799/0.08 of the way from 0.1 to 1 — i.e. ~0.99887, not ~1.0000.
        // Assert the ramp's own arithmetic rather than an eyeballed epsilon.
        #expect(abs(f(0.9999, dim) - (dim + (1 - dim) * (0.0799 / 0.08))) < 1e-9)
        #expect(f(0.9999, dim) < 1)
        // Wraps, including for negative input.
        #expect(abs(f(1.225, dim) - f(0.225, dim)) < 1e-9)
        #expect(abs(f(-0.55, dim) - f(0.45, dim)) < 1e-9)
    }

    @Test("One shared delta drives all nine cells, and same-phase cells agree exactly")
    func oneSharedDeltaDrivesEveryCell() {
        // ── Why this is NOT a per-cell fixture test ────────────────────────
        //
        // Spec 07 §5.3 solved nine alphas out of
        // `send-pending-overlay/02-after-working-overlay.png` and asserted they
        // are consistent with a single delta ≈ 0.975. Re-deriving that fit from
        // the quoted numbers does not reproduce it: with the SOURCE's
        // `gspin_opacity(delta + phase)` (`loaders.rs:141`, which is what ships
        // here), the best least-squares delta is ≈0.722 with a worst-cell error
        // of 0.13 — an order of magnitude worse than the ±0.02 the spec implies.
        //
        // The measurement cannot discriminate, and says so itself: cells that
        // MUST be identical (same phase, same tint) disagree in the measured
        // data by up to 0.043 — row2col0 = 0.552 vs row2col2 = 0.556 vs
        // row1col1 = 0.595. That is an @1x capture of 2.5 pt circles, where each
        // cell lights ~2 physical pixels, so the solved alphas carry more noise
        // than the phase spread being tested. §5.3's own conclusion for the
        // adjacent cell-pitch discrepancy applies here too: **trust the code**.
        //
        // So this asserts what the source actually guarantees and what the
        // screenshot CAN establish: one delta drives every cell, symmetric
        // cells are bit-identical, and the floor is GSPIN_DIM.
        let dim = SupermuxZeronMetrics.Loaders.gspinDim
        func alpha(_ delta: Double, row: Int, col: Int) -> Double {
            SupermuxZeronMetrics.Loaders.gspinOpacity(
                delta + SupermuxZeronMetrics.Loaders.matrixCellPhase(row: row, col: col),
                dim: dim
            )
        }
        for step in 0..<200 {
            let delta = Double(step) / 200
            for row in 0..<3 {
                // Symmetric columns are the same cell of the wave.
                #expect(alpha(delta, row: row, col: 0) == alpha(delta, row: row, col: 2))
            }
            // The three phase-0.50 cells agree, and the two phase-0.25 cells do.
            #expect(alpha(delta, row: 1, col: 0) == alpha(delta, row: 0, col: 1))
            #expect(alpha(delta, row: 2, col: 0) == alpha(delta, row: 1, col: 1))
            // Every cell stays inside [dim, 1] — the screenshot's floor of
            // 0.09–0.10 is what confirms GSPIN_DIM = 0.1 and the flat rest band.
            for row in 0..<3 {
                for col in 0..<3 {
                    let value = alpha(delta, row: row, col: col)
                    #expect(value >= dim - 1e-9 && value <= 1 + 1e-9)
                }
            }
        }
        // At SOME delta each phase reaches the floor, and at some other it
        // reaches full — the wave really does travel, rather than sitting still.
        let floorReached = (0..<200).contains { step in
            alpha(Double(step) / 200, row: 2, col: 1) <= dim + 1e-9
        }
        let peakReached = (0..<200).contains { step in
            alpha(Double(step) / 200, row: 2, col: 1) > 0.95
        }
        #expect(floorReached && peakReached)
    }

    @Test("The spinner's footprint is 4 × cell — 10 pt at the chat pane's 2.5")
    func spinnerFootprint() {
        let cell = SupermuxZeronMetrics.Loaders.matrixCellSize
        #expect(cell == 2.5)
        // `3·cell + 2·(cell/2)` = `4·cell`.
        #expect(3 * cell + 2 * (cell / 2) == SupermuxZeronMetrics.Loaders.matrixFootprint)
        #expect(SupermuxZeronMetrics.Loaders.matrixFootprint == 10)
    }
}
