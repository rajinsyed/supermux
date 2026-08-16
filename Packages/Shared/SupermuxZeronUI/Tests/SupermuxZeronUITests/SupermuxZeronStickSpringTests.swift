import Foundation
import Testing
@testable import SupermuxZeronUI

/// The stick spring's reference fixtures.
///
/// Every expectation here comes from one of two places, never from this port's
/// own output:
///
/// * zeron's Rust tests (`transcript.rs:4072-4205`) — `spring_converges_to_a_
///   fixed_target`, `spring_never_overshoots_or_oscillates`,
///   `spring_feed_forward_tracks_constant_growth`,
///   `spring_feed_forward_resets_when_target_shrinks`,
///   `spring_catchup_frames_glide_instead_of_teleporting`,
///   `restick_is_direction_aware`,
///   `own_turn_reservation_is_a_min_height_for_the_turn`.
/// * spec 07 §3.3's independently-simulated positions, which I re-derived from
///   the transcribed pseudocode before writing the Swift and which agree to the
///   digit: f1 = 16.0, f2 = 40.3, f5 = 125.6, f10 = 239.8, f20 = 348.2,
///   f30 = 383.4, f60 = 399.4, landing at frame 61; steady-state lag 15.72 at a
///   2 px/frame stream.
///
/// The spring is the highest-risk piece of the port and it is PURE, so it is
/// tested hard.
struct SupermuxZeronStickSpringTests {

    // MARK: - Convergence

    @Test("A fixed 400 pt target lands exactly, at frame 61")
    func convergesToFixedTarget() {
        var spring = SupermuxZeronStickSpring()
        let target = 400.0
        var pos = 0.0
        var frames = 0
        while pos < target, frames < 600 {
            pos = spring.step(position: pos, target: target, frames: 1)
            frames += 1
        }
        #expect(pos == target, "the spring must land EXACTLY on the target")
        #expect(frames == 61, "spec 07 §3.3 fixture: landing at frame 61, got \(frames)")
        // Once landed it stays landed, and idles out.
        for _ in 0..<120 {
            pos = spring.step(position: pos, target: target, frames: 1)
            #expect(pos == target)
        }
        #expect(spring.isIdle, "no residual motion at rest")
    }

    @Test("The per-frame trajectory matches spec 07 §3.3 to 0.1 pt")
    func trajectoryFixtures() {
        var spring = SupermuxZeronStickSpring()
        let target = 400.0
        var pos = 0.0
        let expected: [Int: Double] = [
            1: 16.0, 2: 40.3, 5: 125.6, 10: 239.8, 20: 348.2, 30: 383.4, 60: 399.4,
        ]
        for frame in 1...60 {
            pos = spring.step(position: pos, target: target, frames: 1)
            guard let want = expected[frame] else { continue }
            #expect(
                abs(pos - want) <= 0.1,
                "frame \(frame): pos \(pos), spec says \(want)"
            )
        }
    }

    @Test("Never overshoots and never oscillates")
    func neverOvershootsOrOscillates() {
        var spring = SupermuxZeronStickSpring()
        let target = 250.0
        var pos = 0.0
        var last = pos
        for _ in 0..<600 {
            pos = spring.step(position: pos, target: target, frames: 1)
            #expect(pos <= target, "overshoot: \(pos) > \(target)")
            #expect(pos >= last - 1e-3, "oscillation: \(last) -> \(pos)")
            last = pos
        }
        #expect(pos == target)
    }

    // MARK: - Feed-forward (the chase lead while streaming)

    @Test("Feed-forward tracks a constant 2 pt/frame stream with a bounded lag")
    func feedForwardTracksConstantGrowth() {
        // ≈120 px/s — spec 07's "a typical stream".
        let growth = 2.0
        var spring = SupermuxZeronStickSpring()
        var target = 600.0
        var pos = 600.0
        var deltas: [Double] = []
        for frame in 0..<400 {
            target += growth
            let next = spring.step(position: pos, target: target, frames: 1)
            if frame >= 200 { deltas.append(next - pos) }
            pos = next
        }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        #expect(abs(mean - growth) < 0.2, "steady-state speed \(mean) vs growth \(growth)")
        for delta in deltas {
            #expect(delta > 0, "the viewport STALLED mid-stream")
            #expect(delta < growth * 3, "the viewport JUMPED \(delta) pt in one frame")
        }
        #expect(abs(spring.targetVelocity - growth) < 0.3, "the EMA has not locked on")
        // This is the behavior the inverted-list shortcut cannot represent: the
        // viewport deliberately rides ABOVE the true bottom while streaming.
        let lag = target - pos
        #expect(lag > 0, "a hard pin would sit at lag 0; the chase lead must be positive")
        #expect(
            abs(lag - 15.72) < 0.5,
            "spec 07 §3.3 fixture: steady-state lag 15.72 pt, got \(lag)"
        )
        #expect(
            lag <= SupermuxZeronMetrics.Spring.chaseMaxLead + growth,
            "the lag must stay bounded by the chase lead plus one frame of growth"
        )
    }

    @Test("The chase lead is capped at 32 pt however fast the stream runs")
    func chaseLeadIsCapped() {
        // A pathological 40 pt/frame stream would want a 360 pt lead from the
        // ×9 gain; the clamp is what stops the viewport running away from the
        // content it is supposed to be showing.
        var spring = SupermuxZeronStickSpring()
        var target = 1000.0
        var pos = 1000.0
        for _ in 0..<400 {
            target += 40
            pos = spring.step(position: pos, target: target, frames: 1)
        }
        let lag = target - pos
        #expect(
            lag <= SupermuxZeronMetrics.Spring.chaseMaxLead + 40 + 1,
            "lag \(lag) escaped the 32 pt cap plus one frame of growth"
        )
    }

    @Test("A target shrink greater than 1 pt zeroes the growth estimate")
    func feedForwardResetsWhenTargetShrinks() {
        var spring = SupermuxZeronStickSpring()
        var pos = 0.0
        for index in 1...50 {
            pos = spring.step(position: pos, target: 100 + Double(index) * 4, frames: 1)
        }
        #expect(spring.targetVelocity > 1.0, "the estimate should have built up")
        _ = spring.step(position: min(pos, 120), target: 120, frames: 1)
        #expect(spring.targetVelocity == 0, "a collapse must drop the stale estimate")
    }

    @Test("A shrink of 1 pt or less does NOT reset the estimate")
    func smallShrinkDoesNotReset() {
        // The threshold is `grew < -1.0`, so sub-pixel jitter from a re-measure
        // must not knock the feed-forward out mid-stream.
        var spring = SupermuxZeronStickSpring()
        var pos = 0.0
        for index in 1...50 {
            pos = spring.step(position: pos, target: 100 + Double(index) * 4, frames: 1)
        }
        let before = spring.targetVelocity
        _ = spring.step(position: pos, target: 299.5, frames: 1)
        #expect(spring.targetVelocity > 0, "a 0.5 pt jitter must not reset the EMA")
        #expect(spring.targetVelocity < before, "…it should still decay toward zero")
    }

    // MARK: - Catch-up

    @Test("A 5-frame hitch glides instead of teleporting")
    func catchupFramesGlide() {
        let target = 300.0
        var stepwise = SupermuxZeronStickSpring()
        var posA = 0.0
        for _ in 0..<5 {
            posA = stepwise.step(position: posA, target: target, frames: 1)
        }
        var hitched = SupermuxZeronStickSpring()
        let posB = hitched.step(position: 0, target: target, frames: 5)
        #expect(abs(posA - posB) < 1.0, "\(posA) vs \(posB)")
        #expect(posB <= target)
    }

    @Test("`frames(since:now:)` converts wall clock and clamps at the catch-up cap")
    func framesConversion() {
        let now = Date(timeIntervalSince1970: 1_000)
        // No previous tick is exactly one frame.
        #expect(SupermuxZeronStickSpring.frames(since: nil, now: now) == 1.0)
        // One 60 fps frame.
        let oneFrame = now.addingTimeInterval(-SupermuxZeronMetrics.Spring.frameMS / 1000)
        #expect(abs(SupermuxZeronStickSpring.frames(since: oneFrame, now: now) - 1) < 1e-6)
        // A 120 Hz display: half a frame, which the sub-frame loop handles by
        // running exactly once at h = 0.5.
        let halfFrame = now.addingTimeInterval(-SupermuxZeronMetrics.Spring.frameMS / 2000)
        #expect(abs(SupermuxZeronStickSpring.frames(since: halfFrame, now: now) - 0.5) < 1e-6)
        // A one-second hitch clamps at 8, not 60 — a hitch catches up, it does
        // not teleport.
        let hitch = now.addingTimeInterval(-1)
        #expect(
            SupermuxZeronStickSpring.frames(since: hitch, now: now)
                == SupermuxZeronMetrics.Spring.maxCatchupFrames
        )
    }

    // MARK: - Teleport threshold

    @Test("Travel beyond 2.5 viewports teleports; the remainder glides")
    func teleportThreshold() {
        let viewport = 800.0
        // Inside the budget: nothing teleports.
        #expect(
            SupermuxZeronStickSpring.teleportExcess(distance: 1_999, viewportHeight: viewport) == 0
        )
        #expect(
            SupermuxZeronStickSpring.teleportExcess(distance: 2_000, viewportHeight: viewport) == 0
        )
        // Past it: exactly the excess, so the glide always covers 2.5 viewports.
        #expect(
            SupermuxZeronStickSpring.teleportExcess(distance: 5_000, viewportHeight: viewport)
                == 3_000
        )
        // An unmeasured viewport must not produce a bogus jump.
        #expect(
            SupermuxZeronStickSpring.teleportExcess(distance: 5_000, viewportHeight: 0) == 0
        )
    }

    @Test("After the teleport, the spring still lands exactly")
    func teleportThenGlideLands() {
        let viewport = 800.0
        var distance = 5_000.0
        let excess = SupermuxZeronStickSpring.teleportExcess(
            distance: distance,
            viewportHeight: viewport
        )
        distance -= excess
        #expect(distance == 2_000)

        var spring = SupermuxZeronStickSpring()
        let target = 10_000.0
        var pos = target - distance
        var frames = 0
        while pos < target, frames < 1_000 {
            pos = spring.step(position: pos, target: target, frames: 1)
            frames += 1
        }
        #expect(pos == target)
        #expect(frames < 300, "2.5 viewports should glide in well under 5 s, took \(frames)")
    }

    // MARK: - Pin policy

    @Test("Restick is direction-aware")
    func restickIsDirectionAware() {
        // Moving AWAY never resticks, even inside the band — a 20 pt wheel notch
        // from the pinned bottom must break the pin, or the pin is unbreakable.
        #expect(!SupermuxZeronStickSpring.shouldRestick(distance: 20, previousDistance: 0))
        #expect(!SupermuxZeronStickSpring.shouldRestick(distance: 69, previousDistance: 30))
        // Returning, inside the 70 pt band.
        #expect(SupermuxZeronStickSpring.shouldRestick(distance: 69, previousDistance: 120))
        #expect(SupermuxZeronStickSpring.shouldRestick(distance: 0, previousDistance: 30))
        // Returning but still outside it.
        #expect(!SupermuxZeronStickSpring.shouldRestick(distance: 200, previousDistance: 300))
        // No movement — leave the pin alone.
        #expect(!SupermuxZeronStickSpring.shouldRestick(distance: 50, previousDistance: 50))
    }

    @Test("The pin breaks only past the hysteresis AND past the at-bottom band")
    func pinBreakHysteresis() {
        // A 0.5 pt jitter must not break the pin.
        #expect(!SupermuxZeronStickSpring.shouldBreakPin(distance: 10.5, previousDistance: 10))
        // A real 20 pt notch does.
        #expect(SupermuxZeronStickSpring.shouldBreakPin(distance: 20, previousDistance: 0))
        // Movement WITHIN the 2 pt at-bottom band never breaks it: rubber-band
        // settle after a fling would otherwise unpin at the bottom.
        #expect(!SupermuxZeronStickSpring.shouldBreakPin(distance: 1.9, previousDistance: 0))
        // Moving toward the bottom never breaks it.
        #expect(!SupermuxZeronStickSpring.shouldBreakPin(distance: 40, previousDistance: 300))
    }

    @Test("The jump pill shows past 320 pt and only while unpinned")
    func jumpPillThreshold() {
        #expect(!SupermuxZeronStickSpring.showsJumpPill(distance: 320, pinned: false))
        #expect(SupermuxZeronStickSpring.showsJumpPill(distance: 321, pinned: false))
        #expect(!SupermuxZeronStickSpring.showsJumpPill(distance: 5_000, pinned: true))
    }

    @Test("`distanceFromBottom` is the spring's own sign convention")
    func distanceConvention() {
        #expect(SupermuxZeronStickSpring.distanceFromBottom(position: 100, maxOffset: 500) == 400)
        #expect(SupermuxZeronStickSpring.distanceFromBottom(position: 500, maxOffset: 500) == 0)
        // Rubber-band overscroll past the end clamps at zero rather than going
        // negative, which would read as "above the bottom" to every caller.
        #expect(SupermuxZeronStickSpring.distanceFromBottom(position: 540, maxOffset: 500) == 0)
    }

    // MARK: - Idle / reset

    @Test("A fresh spring is idle, and reset returns it to that state")
    func resetParksTheSpring() {
        var spring = SupermuxZeronStickSpring()
        #expect(spring.isIdle)
        #expect(spring.lastTarget == nil)
        var pos = 0.0
        for _ in 0..<10 { pos = spring.step(position: pos, target: 400, frames: 1) }
        #expect(!spring.isIdle)
        #expect(spring.lastTarget == 400)
        spring.reset()
        #expect(spring.isIdle)
        #expect(spring.lastTarget == nil)
        #expect(spring.velocity == 0)
        #expect(spring.targetVelocity == 0)
    }

    @Test("The first step after a reset carries no stale growth")
    func firstStepAfterResetHasNoGrowth() {
        // `lastTarget == nil` means `grew == 0`, so a session switch to a much
        // longer transcript cannot inject a huge phantom growth estimate.
        var spring = SupermuxZeronStickSpring()
        _ = spring.step(position: 0, target: 50_000, frames: 1)
        #expect(spring.targetVelocity == 0)
    }
}

// MARK: - Own-send runway

struct SupermuxZeronOwnTurnGlideTests {

    @Test("The reservation is a min-height for the turn")
    func reservationFixtures() {
        // zeron's `own_turn_reservation_is_a_min_height_for_the_turn`.
        let usable = 700.0
        #expect(SupermuxZeronOwnTurnGlide.reservation(usable: usable, turnHeight: 100) == 600)
        // Growth consumes it 1:1, so the total held height is stable.
        #expect(SupermuxZeronOwnTurnGlide.reservation(usable: usable, turnHeight: 450) == 250)
        // At or past the fill line nothing is reserved, and dropping the pad is
        // height-neutral — the bottom spring takes over with no jump.
        #expect(SupermuxZeronOwnTurnGlide.reservation(usable: usable, turnHeight: 700) == 0)
        #expect(SupermuxZeronOwnTurnGlide.reservation(usable: usable, turnHeight: 1_200) == 0)
    }

    @Test("Row 0 takes NO top inset")
    func rowZeroHasNoInset() {
        // Row 0 already carries the titlebar chrome inside its 62 pt top gap;
        // adding the inset parked a new chat's first prompt ~66 pt low.
        #expect(SupermuxZeronOwnTurnGlide.topInset(anchorIndex: 0) == 0)
        #expect(
            SupermuxZeronOwnTurnGlide.topInset(anchorIndex: 1)
                == Double(SupermuxZeronMetrics.OwnSend.topInset)
        )
    }

    @Test("Usable height subtracts the inset and the base pad, plus the 2 pt slack")
    func usableHeightArithmetic() {
        // viewport 800, inset 48, clearance 120 ⇒ 800 − 48 − (120 + 24 + 8) + 2.
        let usable = SupermuxZeronOwnTurnGlide.usableHeight(
            viewportHeight: 800,
            inset: 48,
            bottomClearance: 120
        )
        #expect(usable == 800 - 48 - 152 + 2)
    }

    @Test("The runway never shrinks faster than the viewport allows")
    func refinedRunwayIsFloored() {
        // Snapping straight to the raw target pulls the end UP THROUGH the
        // viewport — the reported "stutter push back". The floor is what makes
        // the shrink track the available travel instead.
        let refined = SupermuxZeronOwnTurnGlide.refinedRunway(
            current: 600,
            usable: 700,
            turnHeight: 690,      // raw target would be 10
            distanceFromBottom: 12
        )
        // floor = 600 − max(12 − 2, 0) = 590, so the step takes 590, not 10.
        #expect(refined == 590)
    }

    @Test("Once the view can travel, the runway reaches its raw target")
    func refinedRunwayReachesTarget() {
        let refined = SupermuxZeronOwnTurnGlide.refinedRunway(
            current: 600,
            usable: 700,
            turnHeight: 100,      // raw target 600
            distanceFromBottom: 900
        )
        #expect(refined == 600)
    }

    @Test("The glide ease is 1 − 0.85^frames, ~90 % covered in ~14 frames")
    func glideEase() {
        #expect(abs(SupermuxZeronOwnTurnGlide.glideEase(frames: 1) - 0.15) < 1e-9)
        // ln(0.1)/ln(0.85) ≈ 14.2 frames ≈ 237 ms, matching zeron's "~90 %
        // covered in ~230 ms".
        #expect(SupermuxZeronOwnTurnGlide.glideEase(frames: 14) > 0.89)
        #expect(SupermuxZeronOwnTurnGlide.glideEase(frames: 15) > 0.91)
        #expect(SupermuxZeronOwnTurnGlide.glideEase(frames: 0) == 0)
    }

    @Test("The hold correction is ONE-SIDED")
    func holdCorrectionIsOneSided() {
        // Upward drift is corrected…
        #expect(SupermuxZeronOwnTurnGlide.holdNeedsCorrection(error: 0.6))
        #expect(SupermuxZeronOwnTurnGlide.holdNeedsCorrection(error: 40))
        // …but sinking into the slack is legal rest space. Snapping back up from
        // there made the bottom bounce on every scroll event.
        #expect(!SupermuxZeronOwnTurnGlide.holdNeedsCorrection(error: -1))
        #expect(!SupermuxZeronOwnTurnGlide.holdNeedsCorrection(error: -4))
        // Past slack + tolerance it is a real displacement, not rest.
        #expect(SupermuxZeronOwnTurnGlide.holdNeedsCorrection(error: -5))
    }
}
