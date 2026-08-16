//
//  SupermuxZeronSpringDriver.swift
//  SupermuxKit
//
//  The display-link pump that steps the stick spring post-layout and PARKS when
//  it settles. Spec 07 §3.4, plan risk R1.
//
//  ── Why a display link and not `TimelineView` ──
//
//  The spring needs three things `TimelineView` cannot give it:
//    (i)   POST-LAYOUT measurements — zeron runs from `window.on_next_frame`,
//          "i.e. after layout — measurements are fresh";
//    (ii)  a wall-clock delta converted to 60 fps-frame units;
//    (iii) the ability to **park**, scheduling nothing at all.
//
//  `CADisplayLink` (macOS 14+ via `NSView.displayLink(target:selector:)`),
//  invalidated on park, is the direct analogue of `on_next_frame` +
//  `spring_should_run()`. The spring is already frame-rate independent through
//  the `frames` conversion and the ≤1.0 sub-frame loop, so a 120 Hz display just
//  means `frames ≈ 0.5` and the sub-frame loop runs once — no change needed.
//
//  ── The park gate (`spring_should_run`, transcript.rs:3944-3959) ──
//
//      pinned && !reducedMotion && (
//             springKick               // a doc commit landed before layout saw it
//          || distanceFromBottom > 0.5
//          || !spring.isIdle           // residual motion
//          || settledAt != nil         // inside the 500 ms warm hold
//      )
//
//  `springKick` exists because a document commit can land BEFORE layout measures
//  it, so the pre-layout distance still reads 0 — without the kick the spring
//  would never start for that commit.
//
//  ── The warm hold ──
//
//  After landing, the loop stays warm for `SPRING_SETTLE_GRACE_MS = 500` so a
//  streaming pause resumes at cruise instead of re-accelerating from zero. Only
//  then does it reset and invalidate.
//

public import AppKit
internal import SupermuxZeronUI
internal import SwiftUI

/// Drives the stick spring against a ``SupermuxZeronScrollController``.
///
/// Owned ABOVE the `LazyVStack` boundary — by the transcript's host view, never
/// by a row — so it survives row recycling.
@MainActor
public final class SupermuxZeronSpringDriver {
    private let controller: SupermuxZeronScrollController

    /// The pure integrator.
    private var spring = SupermuxZeronStickSpring()
    /// Whether the transcript is following the tail.
    public private(set) var isPinned = true
    /// A commit landed that layout has not measured yet.
    private var kick = false
    /// The previous tick's wall clock, for the frames conversion.
    private var lastTick: Date?
    /// When the spring first landed, for the 500 ms warm hold.
    private var settledAt: Date?
    /// The last distance the USER-INPUT callback observed, for the direction-
    /// aware restick and the pin-break hysteresis.
    private var lastUserDistance: CGFloat = 0

    private var displayLink: CADisplayLink?
    /// The view the display link is vended from. `CADisplayLink` on macOS must
    /// come from an `NSView`/`NSWindow`/`NSScreen`, not from thin air.
    private weak var linkSource: NSView?

    /// Reduced motion. When set, the spring is NEVER scheduled and every
    /// position change snaps (spec 07 §6).
    ///
    /// Turning it ON mid-glide must park the live display link immediately —
    /// otherwise the user toggles the accessibility setting and a 60 Hz tick
    /// keeps running (and keeps gliding) until the spring happens to settle.
    public var reduceMotion = false {
        didSet {
            guard reduceMotion, reduceMotion != oldValue else { return }
            spring.reset()
            lastTick = nil
            settledAt = nil
            kick = false
            parkIfIdle()
            if isPinned { controller.scrollToEnd() }
        }
    }

    /// Called whenever the jump pill's visibility should change.
    public var onJumpPillVisibilityChange: ((Bool) -> Void)?
    /// Whether the jump pill is currently shown.
    public private(set) var showsJumpPill = false

    public init(controller: SupermuxZeronScrollController) {
        self.controller = controller
        controller.onUserScroll = { [weak self] metrics in
            self?.handleUserScroll(metrics)
        }
        controller.onGeometryChange = { [weak self] _ in
            // A target move is exactly the case `springKick` exists for: the
            // document grew, and this fires before the spring's own tick can
            // observe a non-zero distance.
            self?.wake()
        }
    }

    /// Invalidates the display link and drops the scroll callbacks.
    ///
    /// Called explicitly rather than from `deinit`: under Swift 6, a `deinit` on
    /// a `@MainActor` class is nonisolated, so it cannot touch the non-`Sendable`
    /// `CADisplayLink`. Nothing is leaked by that restriction — the link holds a
    /// STRONG reference to its target, so a driver with a live link is never
    /// deallocated in the first place, and the correct fix is to stop the link
    /// when the view disappears rather than to hope `deinit` runs.
    public func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        linkSource = nil
        controller.onUserScroll = nil
        controller.onGeometryChange = nil
    }

    /// Binds the driver to the view that vends its display link. Call once the
    /// scroll host is in a window.
    public func bind(linkSource view: NSView) {
        guard linkSource !== view else { return }
        displayLink?.invalidate()
        displayLink = nil
        linkSource = view
        scheduleIfNeeded()
    }

    // MARK: - Public control

    /// `wake_spring()` — clears the settle timer and arms the kick.
    ///
    /// Call on every row-set sync while pinned, and whenever content grows.
    public func wake() {
        // Reduced motion SNAPS instead of gliding, and it must still follow the
        // tail. zeron's sync-while-pinned path is
        // `if reducedMotion || wasEmpty { list.scroll_to_end() }`
        // (`transcript.rs:2306-2312`, spec 07 §6 "Sync while pinned"), and the
        // spring is simply never scheduled.
        //
        // Without this branch the spring's own park gate (`shouldRun` returns
        // false under reduced motion) meant NOTHING moved the viewport on
        // growth: a reduced-motion user's transcript silently stopped following
        // the stream at the first token, with no way to notice except that the
        // text stopped arriving on screen.
        guard !reduceMotion else {
            settledAt = nil
            kick = false
            if isPinned { controller.scrollToEnd() }
            return
        }
        settledAt = nil
        kick = true
        scheduleIfNeeded()
    }

    /// `engage_pin()` — the jump pill's click and a restick.
    ///
    /// Reduced motion snaps to the end; otherwise anything beyond 2.5 viewports
    /// teleports first and the remainder glides.
    public func engagePin() {
        isPinned = true
        setJumpPill(false)
        guard !reduceMotion else {
            controller.scrollToEnd()
            return
        }
        let metrics = controller.metrics
        let excess = SupermuxZeronStickSpring.teleportExcess(
            distance: Double(metrics.distanceFromBottom),
            viewportHeight: Double(metrics.viewportHeight)
        )
        if excess > 0 { controller.scrollBy(CGFloat(excess)) }
        wake()
    }

    /// The transcript attached, or the session switched.
    ///
    /// The first fill lands at the bottom INSTANTLY, never with a glide
    /// (`list.scroll_to_end()`, mugen `initialScroll: 'bottom'`).
    public func attach() {
        spring.reset()
        lastTick = nil
        settledAt = nil
        kick = false
        isPinned = true
        setJumpPill(false)
        controller.scrollToEnd()
        lastUserDistance = 0
    }

    /// Breaks the pin without user input — used by the own-send path, which owns
    /// the viewport until its anchor retires.
    public func releasePin() {
        isPinned = false
        spring.reset()
        lastTick = nil
        settledAt = nil
        parkIfIdle()
    }

    // MARK: - User input

    /// The ONLY place the pin may break. Reached exclusively from
    /// ``SupermuxZeronScrollController/onUserScroll``, which never fires for a
    /// programmatic write (R1).
    private func handleUserScroll(_ metrics: SupermuxZeronScrollMetrics) {
        let distance = metrics.distanceFromBottom
        let previous = lastUserDistance
        lastUserDistance = distance

        if SupermuxZeronStickSpring.shouldBreakPin(
            distance: Double(distance),
            previousDistance: Double(previous)
        ) {
            isPinned = false
            spring.reset()
            lastTick = nil
            settledAt = nil
        } else if distance <= CGFloat(SupermuxZeronMetrics.Spring.atBottomPX)
            || SupermuxZeronStickSpring.shouldRestick(
                distance: Double(distance),
                previousDistance: Double(previous)
            ) {
            if !isPinned {
                isPinned = true
                wake()
            }
        }

        setJumpPill(
            SupermuxZeronStickSpring.showsJumpPill(
                distance: Double(distance),
                pinned: isPinned
            )
        )
        parkIfIdle()
    }

    private func setJumpPill(_ shows: Bool) {
        guard showsJumpPill != shows else { return }
        showsJumpPill = shows
        onJumpPillVisibilityChange?(shows)
    }

    // MARK: - The pump

    /// `spring_should_run()`.
    private var shouldRun: Bool {
        guard isPinned, !reduceMotion else { return false }
        if kick { return true }
        if controller.metrics.distanceFromBottom > 0.5 { return true }
        if !spring.isIdle { return true }
        return settledAt != nil
    }

    private func scheduleIfNeeded() {
        guard shouldRun else { return }
        guard displayLink == nil, let linkSource else { return }
        let link = linkSource.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func parkIfIdle() {
        guard !shouldRun else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One post-layout tick (`step_spring`).
    @objc private func step() {
        kick = false
        guard isPinned, !reduceMotion else {
            lastTick = nil
            parkIfIdle()
            return
        }

        let now = Date()
        let frames = SupermuxZeronStickSpring.frames(since: lastTick, now: now)
        lastTick = now

        var metrics = controller.metrics
        let target = Double(metrics.maxOffset)
        var distance = Double(metrics.distanceFromBottom)

        // TELEPORT: long jumps (a chat switch mid-history, a huge paste) cover
        // everything beyond 2.5 viewports instantly and glide the rest.
        let excess = SupermuxZeronStickSpring.teleportExcess(
            distance: distance,
            viewportHeight: Double(metrics.viewportHeight)
        )
        if excess > 0 {
            controller.scrollBy(CGFloat(excess))
            metrics = controller.metrics
            distance = Double(metrics.distanceFromBottom)
        }

        let position = target - distance
        let next = spring.step(position: position, target: target, frames: frames)
        // ONE-SIDED: never scroll UP. The spring can only ever chase the bottom.
        if next > position { controller.scrollBy(CGFloat(next - position)) }
        lastUserDistance = CGFloat(max(target - next, 0))

        // Warm hold, then park.
        if target - next <= SupermuxZeronMetrics.Spring.snapEpsilonPX {
            let landed = settledAt ?? now
            if settledAt == nil { settledAt = now }
            let grace = SupermuxZeronMetrics.Spring.settleGraceMS / 1000
            if now.timeIntervalSince(landed) >= grace, spring.isIdle {
                spring.reset()
                lastTick = nil
                settledAt = nil
                parkIfIdle()
                return
            }
        } else {
            settledAt = nil
        }
    }
}
