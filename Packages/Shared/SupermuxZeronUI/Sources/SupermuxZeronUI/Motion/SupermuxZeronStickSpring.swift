//
//  SupermuxZeronStickSpring.swift
//  SupermuxZeronUI
//
//  The transcript's stick-to-bottom spring, transcribed line-for-line from
//  zeron's `StickSpring` (`crates/ui/src/transcript.rs:140-213`) via spec 07
//  §3.2. Provenance: mugen §1e, whose `DEFAULT_SPRING` follows the shape of
//  stackblitz/use-stick-to-bottom.
//
//  ── This file is PURE ──
//
//  No view types, no scroll views, no clocks. Everything here is a value
//  transform over `(position, target, frames)`, which is what makes the whole
//  motion model unit-testable without a running window. The frame pump, the
//  measurements it feeds in, and the scroll writes it makes all live in the
//  platform shell (`SupermuxZeronSpringDriver` / `SupermuxZeronScrollHost`).
//
//  ── Sign convention ──
//
//  `position` and `target` are scroll offsets where **larger = closer to the
//  bottom**, matching a flipped `NSScrollView`/`UIScrollView` content offset.
//  zeron's list reports `max_offset` and a NEGATIVE-going-up `scroll_px_offset`
//  and derives `distance = max(max + cur, 0)`; the same quantity here is
//  `max(target - position, 0)` (``distanceFromBottom(position:maxOffset:)``).
//
//  ── Why the inverted-list shortcut is not available ──
//
//  A rotated/reversed `ScrollView` gives free stickiness but hard-snaps once per
//  document commit — precisely the artifact this spring exists to remove. It
//  also cannot represent ``chaseMaxLead``: while streaming, the viewport
//  deliberately rides ~16 pt ABOVE the true bottom, which a hard-pinned list has
//  no way to express.
//

public import Foundation

// MARK: - The integrator

/// The stick-to-bottom spring.
///
/// Velocity relaxes toward `(damping·v + stiffness·diff) / mass` per 60 fps
/// sub-frame; position advances by `v + targetVel`, where `targetVel` is a
/// feed-forward EMA of target growth in points per frame; and the chase point
/// sits up to ``SupermuxZeronMetrics/Spring/chaseMaxLead`` points above the true
/// bottom, proportional to that growth.
///
/// ```swift
/// var spring = SupermuxZeronStickSpring()
/// let next = spring.step(position: pos, target: maxOffset, frames: frames)
/// if next > pos { host.scrollBy(next - pos) }   // ONE-SIDED: never scroll up
/// ```
public struct SupermuxZeronStickSpring: Sendable, Equatable {
    /// Spring velocity, points per 60 fps frame.
    public private(set) var velocity: Double = 0
    /// Feed-forward: smoothed target growth, points per 60 fps frame.
    public private(set) var targetVelocity: Double = 0
    /// The target observed at the previous tick. `nil` means fresh or parked.
    public private(set) var lastTarget: Double?

    public init() {}

    /// Parks the spring. The next tick starts cold.
    public mutating func reset() {
        velocity = 0
        targetVelocity = 0
        lastTarget = nil
    }

    /// Residual motion below mugen's settle thresholds.
    ///
    /// Deliberately a **signed** comparison, exactly as the Rust
    /// (`velocity < 0.05 && target_vel < 0.05`) — not `abs()`. Both quantities
    /// are non-negative in every reachable state because `diff` is one-sided
    /// and `targetVelocity` only ever tracks non-negative growth, so the signed
    /// form is equivalent *and* is what the reference implementation ships.
    public var isIdle: Bool {
        velocity < SupermuxZeronMetrics.Spring.idleVelocityThreshold
            && targetVelocity < SupermuxZeronMetrics.Spring.idleVelocityThreshold
    }

    /// Advances one tick and returns the new position.
    ///
    /// Never overshoots `target`, is monotone while approaching, and snaps
    /// exactly once within ``SupermuxZeronMetrics/Spring/snapEpsilonPX``.
    ///
    /// - Parameters:
    ///   - position: current scroll offset (larger = closer to the bottom).
    ///   - target: the bottom-most offset, i.e. `maxOffset`.
    ///   - frames: elapsed time in 60 fps frames. **The caller clamps this** to
    ///     ``SupermuxZeronMetrics/Spring/maxCatchupFrames`` — the cap is not
    ///     applied here, matching the Rust, so a hitch catches up by
    ///     sub-stepping instead of teleporting.
    public mutating func step(position: Double, target: Double, frames: Double) -> Double {
        typealias Spring = SupermuxZeronMetrics.Spring
        var pos = position
        var remaining = frames

        // ---- feed-forward: EMA of target growth ---------------------------
        let grew = lastTarget.map { target - $0 } ?? 0
        lastTarget = target
        if grew < -1.0 {
            // The target SHRANK (a row collapsed or was removed), so the growth
            // estimate is stale. Carrying it would push the view past a bottom
            // that just moved up.
            targetVelocity = 0
        } else {
            let observed = max(grew, 0) / max(remaining, 0.25)
            targetVelocity += Spring.growthEMA * (observed - targetVelocity)
        }

        // ---- the chase point: up to 32 pt ABOVE the true bottom ------------
        // Proportional to growth, clamped. Keeps the growing tail visible
        // instead of hugging a moving edge.
        let chase = target - min(targetVelocity * Spring.chaseGrowthGain, Spring.chaseMaxLead)

        // ---- fixed-timestep sub-frame integration --------------------------
        var v = velocity
        while remaining > 0 {
            // A sub-frame is never longer than one 60 fps frame, which is what
            // makes the integration frame-rate independent: a 120 Hz display
            // just runs one sub-step at h ≈ 0.5.
            let h = min(remaining, 1.0)
            remaining -= h
            // One-sided: the spring only ever pulls DOWN. It can never yank the
            // view back up when content shrinks.
            let diff = max(chase - pos, 0)
            v += h * ((Spring.damping * v + Spring.stiffness * diff) / Spring.mass - v)
            // Position advances by `v + targetVelocity` — the feed-forward term
            // is added OUTSIDE the spring, which is why steady-state streaming
            // tracks growth exactly. The clamp is per sub-frame, not just at
            // the end.
            pos = min(pos + (v + targetVelocity) * h, target)
        }
        velocity = v

        // ---- single exact snap ---------------------------------------------
        return (target - pos <= Spring.snapEpsilonPX) ? target : pos
    }
}

// MARK: - Pin policy (pure)

public extension SupermuxZeronStickSpring {
    /// `max(maxOffset - position, 0)` — how far the viewport sits above the end.
    static func distanceFromBottom(position: Double, maxOffset: Double) -> Double {
        max(maxOffset - position, 0)
    }

    /// Wall-clock delta expressed in 60 fps frames, clamped to the catch-up cap.
    ///
    /// `nil` for `previousTick` means the first tick after a wake, which the
    /// Rust treats as exactly one frame.
    static func frames(since previousTick: Date?, now: Date) -> Double {
        guard let previousTick else { return 1.0 }
        let elapsedMS = now.timeIntervalSince(previousTick) * 1000
        return min(
            max(elapsedMS / SupermuxZeronMetrics.Spring.frameMS, 0),
            SupermuxZeronMetrics.Spring.maxCatchupFrames
        )
    }

    /// Whether a **user** scroll should re-engage the bottom pin.
    ///
    /// Inside the 70 pt stick band *and* moving toward the bottom. Direction
    /// matters: a small wheel-up notch near the bottom stays inside the band,
    /// and re-sticking on it would snap the view straight back — making the pin
    /// unbreakable.
    static func shouldRestick(distance: Double, previousDistance: Double) -> Bool {
        distance <= SupermuxZeronMetrics.Spring.stickThresholdPX && distance < previousDistance
    }

    /// Whether a **user** scroll should break the bottom pin.
    ///
    /// The `+1` point of hysteresis suppresses jitter. Content growth must never
    /// reach this test: the host's scroll callback fires only from the
    /// wheel/touch input path (mugen §1e — "interrupt detection from USER INPUT,
    /// not scrollbar position").
    static func shouldBreakPin(distance: Double, previousDistance: Double) -> Bool {
        distance > previousDistance + SupermuxZeronMetrics.Spring.escapeHysteresisPX
            && distance > SupermuxZeronMetrics.Spring.atBottomPX
    }

    /// Whether the jump-to-bottom pill shows.
    ///
    /// With a live own-turn runway the second clause becomes `!anchor.held`,
    /// because "bottom" then IS the held position.
    static func showsJumpPill(distance: Double, pinned: Bool) -> Bool {
        distance > SupermuxZeronMetrics.Spring.jumpThresholdPX && !pinned
    }

    /// The instant teleport applied before a glide, in points.
    ///
    /// Travel beyond `2.5` viewports is covered by a jump; only the remainder
    /// glides. Returns 0 when the viewport is unmeasured or the distance is
    /// already inside the budget.
    static func teleportExcess(distance: Double, viewportHeight: Double) -> Double {
        guard viewportHeight > 0 else { return 0 }
        let budget = SupermuxZeronMetrics.Spring.glideMaxViewports * viewportHeight
        return max(distance - budget, 0)
    }
}

// MARK: - Own-send runway (pure)

/// The own-send reservation and entry glide (spec 07 §3.6, spec 02 §2.5).
///
/// Every local send reserves the whole remaining viewport below the prompt so
/// the reply streams into empty space **without the layout ever moving** — the
/// notes-app / iMessage "your message jumps to the top and the reply fills in
/// below" behavior. The reservation is implemented as an extra bottom pad on the
/// last row that shrinks 1:1 as the turn grows.
///
/// Pure by construction so the host can drive it from a display link and a test
/// can drive it from a loop.
public struct SupermuxZeronOwnTurnGlide: Sendable, Equatable {
    public init() {}

    /// The room under the prompt's top-inset position not yet consumed by the
    /// turn's own content. Zero once the reply has filled the reservation, at
    /// which point dropping the pad is height-neutral and the ordinary bottom
    /// pin takes over with no jump.
    ///
    /// Fixtures (`own_turn_reservation_is_a_min_height_for_the_turn`):
    /// `(700, 100) → 600`, `(700, 450) → 250`, `(700, 700) → 0`,
    /// `(700, 1200) → 0`.
    public static func reservation(usable: Double, turnHeight: Double) -> Double {
        max(usable - turnHeight, 0)
    }

    /// Where a freshly-sent prompt rests below the viewport top.
    ///
    /// **Zero when the anchor is row 0** — row 0 already carries the titlebar
    /// chrome inside its own 62 pt top gap, and adding the inset on top parked a
    /// new chat's first prompt a double-chrome ~66 pt low (user report).
    public static func topInset(anchorIndex: Int) -> Double {
        anchorIndex == 0 ? 0 : Double(SupermuxZeronMetrics.OwnSend.topInset)
    }

    /// `viewportHeight - inset - (bottomClearance + 24 + 8) + 2`.
    ///
    /// The trailing 2 pt is `scrollSlack`: **not** scroll room. Twenty-four
    /// points of it read as "a janky overshoot-and-fight zone" in a user report;
    /// it exists only to keep the held layout out of gpui's
    /// shorter-than-viewport regime. Two points of travel is below perception,
    /// and the value is retained here purely for parity.
    public static func usableHeight(
        viewportHeight: Double,
        inset: Double,
        bottomClearance: Double
    ) -> Double {
        let basePad = bottomClearance
            + Double(SupermuxZeronMetrics.Theme.transcriptFadeBand)
            + Double(SupermuxZeronMetrics.Transcript.lastRowExtraClearance)
        return viewportHeight - inset - basePad + Double(SupermuxZeronMetrics.OwnSend.scrollSlack)
    }

    /// The refined reservation for one step, floored so the pad never shrinks
    /// faster than the viewport allows.
    ///
    /// The step runs one frame behind content growth, so snapping straight to
    /// the raw target pulled the end up through the viewport — a visible yank
    /// (user report: "stutter push back").
    public static func refinedRunway(
        current: Double,
        usable: Double,
        turnHeight: Double,
        distanceFromBottom: Double
    ) -> Double {
        let raw = reservation(usable: usable, turnHeight: turnHeight)
        let floor = current - max(distanceFromBottom - Double(SupermuxZeronMetrics.OwnSend.scrollSlack), 0)
        return max(raw, min(floor, current))
    }

    /// The eased fraction of the remaining travel to cover this tick.
    ///
    /// `1 - 0.85^frames` — an exponential ease-out. Ten percent remains after
    /// `ln(0.1)/ln(0.85) ≈ 14.2` frames ≈ 237 ms, matching zeron's "~90 %
    /// covered in ~230 ms".
    public static func glideEase(frames: Double) -> Double {
        1 - pow(SupermuxZeronMetrics.OwnSend.glideRetain, max(frames, 0))
    }

    /// Whether the absolute hold must re-assert the prompt's position.
    ///
    /// **One-sided by design**: only upward drift is corrected. Sinking into the
    /// slack is legal rest space, because snapping back up from there made the
    /// bottom bounce on every scroll event (user report).
    public static func holdNeedsCorrection(error: Double) -> Bool {
        let slack = Double(SupermuxZeronMetrics.OwnSend.scrollSlack)
        let tolerance = Double(SupermuxZeronMetrics.OwnSend.driftTolerancePX)
        return error > 0.5 || error < -(slack + tolerance)
    }
}
