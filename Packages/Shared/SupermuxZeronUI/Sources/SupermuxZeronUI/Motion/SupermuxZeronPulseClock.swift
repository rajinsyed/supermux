//
//  SupermuxZeronPulseClock.swift
//  SupermuxZeronUI
//
//  ONE process-wide 30 fps loader clock with a 300 ms lease set and a single
//  shared epoch. Ported from zeron's `pulse_delta` (`crates/ui/src/motion.rs`
//  §44-118) via spec 07 §5.1 / §7.1. Plan risk R12.
//
//  ── Why this exists at all (verbatim from motion.rs:46-52) ──
//
//  > The loaders used to run as gpui `with_animation(...repeating...)` elements,
//  > which request a redraw every display frame for as long as they are mounted
//  > — ONE Working session row pinned the whole window at 120 Hz (measured 36 %
//  > CPU on an M-series laptop, with the always-hot Metal pipeline holding
//  > hundreds of MB of graphics buffers).
//
//  The SwiftUI trap is identical, with three vectors, and **all three are
//  banned in this package**:
//
//  1. `withAnimation(.repeatForever(...))` keeps CoreAnimation's render server
//     awake indefinitely — on a ProMotion display that is 120 Hz forever, for a
//     10 × 10 pt spinner.
//  2. `TimelineView(.animation)` drives at the display's native refresh rate.
//     Even `TimelineView(.periodic)` inside each spinner is wrong here: it
//     reintroduces per-view clocks and loses the shared-epoch phase lock.
//  3. A `Timer.publish` / `CADisplayLink` that outlives its spinner.
//
//  ── The shared-epoch phase-lock rule ──
//
//  ``epoch`` is a single process-wide instant created once. Every cell of every
//  loader in every view derives its phase from it, so multi-instance loaders are
//  phase-locked: two Working indicators pulse in perfect unison, and a loader
//  that mounts mid-stream joins the wave already in progress instead of
//  restarting it. **Never give a loader its own start time.**
//
//  ── The lease ──
//
//  Each mounted loader renews a 300 ms lease keyed by its own identity on every
//  paint. The tick prunes expired leases and **stops the timer entirely when the
//  set empties**, so a spinner that scrolls out of the virtualized transcript
//  stops painting, stops renewing, and within 300 ms the clock parks. A window
//  with no spinner mounted schedules nothing at all.
//
//  ── Reduced motion ──
//
//  `pulse_delta` returns a STATIC 0.0 and schedules nothing. Loaders then freeze
//  at their own static phase (bottom-centre bright, corners dim), which is the
//  documented behavior: oneshot entrances snap to their END state, repeating
//  loaders to their START state.
//

public import Foundation
public import SwiftUI

// MARK: - The clock

/// The process-wide 30 fps loader clock.
///
/// A loader view calls ``phase(period:leasedBy:)`` from its `body`; that renews
/// the lease, starts the timer if it is parked, and returns the current phase in
/// `[0, 1)`. When every lease expires the timer invalidates itself.
///
/// The `@Observable` `frame` counter is what re-renders leased views: the tick
/// bumps it, SwiftUI re-evaluates every body that read it, each of those renews
/// its lease, and the cycle continues until nobody reads it any more.
@MainActor
@Observable
public final class SupermuxZeronPulseClock {
    /// The one clock. Deliberately a shared instance rather than an injected
    /// dependency: the phase lock across independently-mounted loaders in
    /// different windows IS the feature, and per-scene instances would break it.
    ///
    /// lint:allow singleton — the process-wide shared epoch is the design (spec
    /// 07 §5.1): two loaders that do not share it visibly de-sync.
    public static let shared = SupermuxZeronPulseClock()

    /// Bumped once per tick. Reading it in a `body` is what subscribes a view.
    public private(set) var frame: UInt64 = 0

    /// The single process-wide epoch every phase derives from.
    @ObservationIgnored public let epoch: Date

    /// Lease deadlines, keyed by leaseholder identity.
    @ObservationIgnored private var leases: [String: Date] = [:]
    /// The running tick, or `nil` when parked.
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Injected clock, so tests can drive phase without waiting on wall time.
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.epoch = now()
    }

    /// Whether the tick loop is currently scheduled.
    public var isRunning: Bool { ticker != nil }

    /// The number of live (un-pruned) leases.
    public var leaseCount: Int { leases.count }

    /// Renews `holder`'s lease and returns the current phase of `period`.
    ///
    /// - Parameters:
    ///   - period: the loop length in seconds — 2.4 for `ZERON_PULSE`, 0.75 for
    ///     `GRADIENT_SPIN`.
    ///   - holder: a stable per-loader identity. Two loaders sharing an id share
    ///     one lease, which is harmless: the lease is a liveness signal, not a
    ///     reference count.
    ///   - reduceMotion: when true, returns a static 0 and schedules nothing.
    /// - Returns: phase in `[0, 1)`.
    @discardableResult
    public func phase(
        period: TimeInterval,
        leasedBy holder: String,
        reduceMotion: Bool = false
    ) -> Double {
        guard !reduceMotion else { return 0 }
        // OBSERVE the frame counter. This read is what subscribes the calling
        // `body` to the clock, and it is load-bearing: without it a spinner
        // evaluates its body exactly ONCE and then freezes, because nothing in
        // its `body` ever touches observable state again. `tick()` bumping
        // `frame` with no observer registered wakes nobody, and the whole
        // lease/park machinery below then keeps a 30 fps timer alive to drive
        // an animation that never advances — measured: 1 body evaluation over
        // 20 ticks before this line existed, 21 after.
        //
        // It must be read BEFORE the early returns above are passed, i.e. on
        // every non-reduced-motion call, and it must not be `@ObservationIgnored`.
        _ = frame
        let instant = now()
        leases[holder] = instant.addingTimeInterval(SupermuxZeronMetrics.PulseClock.lease)
        startIfNeeded()
        return Self.phase(epoch: epoch, now: instant, period: period)
    }

    /// Renews `holder`'s lease and starts the clock, WITHOUT deriving a phase.
    ///
    /// The streaming markdown veil needs the tick but not the epoch: a chunk's
    /// age is measured against its own arrival time, not against a shared phase
    /// (the phase lock exists so multiple loaders pulse in unison, which has no
    /// meaning for independently-arriving text chunks). This is the same lease
    /// on the same 30 fps timer, minus the phase math.
    public func renewLease(_ holder: String) {
        leases[holder] = now().addingTimeInterval(SupermuxZeronMetrics.PulseClock.lease)
        startIfNeeded()
    }

    /// Drops a lease immediately instead of waiting for it to expire. Optional —
    /// the 300 ms expiry is the real mechanism; this is for deterministic tests
    /// and for a shell that knows a surface just closed.
    public func releaseLease(_ holder: String) {
        leases.removeValue(forKey: holder)
        if leases.isEmpty { park() }
    }

    /// One tick: prune, park if empty, otherwise publish a frame.
    ///
    /// Exposed so tests can step the clock without a running task.
    /// - Returns: whether the clock is still running after this tick.
    @discardableResult
    public func tick() -> Bool {
        let instant = now()
        leases = leases.filter { $0.value >= instant }
        guard !leases.isEmpty else {
            park()
            return false
        }
        frame &+= 1
        return true
    }

    private func startIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(SupermuxZeronMetrics.PulseClock.tickInterval)
                )
                guard let self, !Task.isCancelled else { return }
                if !self.tick() { return }
            }
        }
    }

    private func park() {
        ticker?.cancel()
        ticker = nil
    }

    /// The pure phase function: `fract(elapsed / period)`.
    ///
    /// Split out so it is testable and so every consumer — spinner cells,
    /// skeletons, a future loader — provably shares one derivation.
    public static func phase(epoch: Date, now: Date, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(epoch)
        let raw = (elapsed / period).truncatingRemainder(dividingBy: 1)
        return raw < 0 ? raw + 1 : raw
    }
}

// MARK: - View access

/// Environment key for the pulse clock.
///
/// Hand-written rather than `@Entry` (macOS 15+; this package's floor is 14),
/// and Optional rather than defaulting to `.shared`, because a nonisolated
/// `defaultValue` cannot touch a `@MainActor` singleton. Consumers resolve
/// `?? .shared` inside `body`, which is already main-actor isolated.
private struct SupermuxZeronPulseClockKey: EnvironmentKey {
    static let defaultValue: SupermuxZeronPulseClock? = nil
}

public extension EnvironmentValues {
    /// An override for the pulse clock loaders read. `nil` means
    /// ``SupermuxZeronPulseClock/shared``; previews and tests substitute a
    /// hand-driven instance.
    var supermuxZeronPulseClock: SupermuxZeronPulseClock? {
        get { self[SupermuxZeronPulseClockKey.self] }
        set { self[SupermuxZeronPulseClockKey.self] = newValue }
    }
}
