//
//  SupermuxZeronComposerFlip.swift
//  SupermuxZeronUI
//
//  The composer's PURE decision layer: the compact↔expanded flip rule, the
//  auto-grow height math, the attachment-strip wrap model, the flip morph, and
//  the send-button mode. Transcribed from `crates/ui/src/composer.rs:44-390`
//  (spec 04 §1). Plan §1.4 owns the constants; this file owns the behavior.
//
//  ── Why this is a value type with no view in sight ──
//
//  zeron re-evaluates the flip inside `Render for Composer`, mutating five
//  fields of the composer entity as it goes. That is a reducer, not a view: it
//  reads measurements, decides a mode, and commits. Keeping it here — pure,
//  `Sendable`, wall-clock injected — is what lets the 04 fixtures
//  (1 line → 124, 4 lines → 159, 100 lines → 308) be asserted before any
//  `NSTextView` exists, and it keeps the SwiftUI mount free of the oscillation
//  the hysteresis exists to prevent.
//
//  ── The one rule that must not be broken ──
//
//  `capacity` is the **compact-mode** input capacity — a layout-stable width.
//  It is measured directly while compact, and while expanded it is the LEARNED
//  compact value shifted by the container's own resize delta. Deriving it fresh
//  from the expanded layout feeds the post-flip width back into the decision
//  that produced it, and the composer oscillates at the boundary.
//

public import CoreGraphics

internal import Foundation

// MARK: - Send button mode

/// What the send button is right now (`SendButtonMode`, `composer.rs:363`).
///
/// Send and Steer are **visually identical** — nothing in the rendered element
/// distinguishes them (spec 04 §5.1). The difference is only which command is
/// queued, plus the turn-boundary hint above the pill.
public enum SupermuxZeronSendMode: Sendable, Equatable, Hashable, CaseIterable {
    /// No live run: a plain send.
    case send
    /// A live run with text typed — steers (supermux: queues at the turn
    /// boundary, which is zeron's `SteeringMode::TurnBoundary` branch).
    case steer
    /// A live run with nothing typed: the stop square.
    case stop

    /// `send_button_mode(run_live, has_text)` (`composer.rs:379`).
    ///
    /// `hasText` is the trimmed input being non-empty **or** at least one
    /// staged attachment — an image-only send is legal.
    public static func mode(runLive: Bool, hasText: Bool) -> SupermuxZeronSendMode {
        switch (runLive, hasText) {
        case (false, _): .send
        case (true, true): .steer
        case (true, false): .stop
        }
    }

    /// True for the two arms that submit; false for the arm that interrupts.
    public var submits: Bool { self != .stop }
}

// MARK: - Flip reducer

/// The composer's compact↔expanded state machine and auto-grow math.
///
/// Construct one per composer and feed it a ``Measurement`` per layout pass.
/// Every field mirrors a `Composer` entity field in `composer.rs`.
public struct SupermuxZeronComposerFlip: Sendable, Equatable, Hashable {
    /// lint:allow namespace-type — this is a real value type; the statics below are the pure formulas its own instance methods call.

    public typealias Metrics = SupermuxZeronMetrics.Composer

    // MARK: State (one field per `composer.rs` entity field)

    /// The committed mode. Starts compact: `capacity` is `.infinity` before the
    /// first measure, so nothing can trip the expand threshold.
    public private(set) var expanded: Bool
    /// The learned compact-mode input capacity (`compact_capacity`).
    public private(set) var compactCapacity: CGFloat
    /// The input width first measured after expanding (`expanded_anchor`).
    /// Never the post-flip measured width.
    public private(set) var expandedAnchor: CGFloat
    /// The last width seen in the CURRENT mode (`last_seen_width`), used only
    /// to detect an interactive resize.
    public private(set) var lastSeenWidth: CGFloat
    /// Wall-clock ms of the last same-mode width change (`width_changed_at`).
    public private(set) var widthChangedAtMS: Double?
    /// The layout epoch of the last committed flip (`flip_epoch`). At most one
    /// flip per layout pass — a flip invalidates the widths that drove it.
    public private(set) var flipEpoch: UInt64

    public init(expanded: Bool = false) {
        self.expanded = expanded
        compactCapacity = 0
        expandedAnchor = 0
        lastSeenWidth = 0
        widthChangedAtMS = nil
        flipEpoch = 0
    }

    // MARK: Inputs / outputs

    /// One layout pass's measurements, read off the text view.
    public struct Measurement: Sendable, Equatable, Hashable {
        /// `max` over shaped lines of the line's **unwrapped** width.
        /// **0 while the placeholder is showing** (`composer.rs:2540`), so the
        /// placeholder can never trigger the expand flip.
        public var textWidth: CGFloat
        /// A newline ALWAYS expands, regardless of width.
        public var hasNewline: Bool
        /// `max(sum of line heights, 22.75)` — the wrapped content height.
        public var contentHeight: CGFloat
        /// The input element's measured width this pass. `0` before the first
        /// measure.
        public var lastWidth: CGFloat
        /// Bumped by the text view on every layout. A flip is only
        /// re-evaluated when this exceeds ``SupermuxZeronComposerFlip/flipEpoch``.
        public var layoutEpoch: UInt64

        public init(
            textWidth: CGFloat,
            hasNewline: Bool,
            contentHeight: CGFloat,
            lastWidth: CGFloat,
            layoutEpoch: UInt64
        ) {
            self.textWidth = textWidth
            self.hasNewline = hasNewline
            self.contentHeight = contentHeight
            self.lastWidth = lastWidth
            self.layoutEpoch = layoutEpoch
        }
    }

    /// What one ``evaluate(_:nowMS:)`` decided.
    public struct Outcome: Sendable, Equatable, Hashable {
        /// The committed mode after this pass.
        public var expanded: Bool
        /// True on the pass where the mode actually changed — the only moment
        /// a morph may be armed.
        public var committedFlip: Bool
        /// The mode is frozen: an interactive resize is still settling.
        public var resizing: Bool
        /// The layout-stable compact capacity this pass measured against.
        public var capacity: CGFloat

        public init(expanded: Bool, committedFlip: Bool, resizing: Bool, capacity: CGFloat) {
            self.expanded = expanded
            self.committedFlip = committedFlip
            self.resizing = resizing
            self.capacity = capacity
        }
    }

    // MARK: The reducer (`Render for Composer`, composer.rs:5215-5290)

    /// Folds one layout pass's measurements into the committed mode.
    ///
    /// `nowMS` is any monotonic millisecond clock; only differences are read.
    @discardableResult
    public mutating func evaluate(_ measurement: Measurement, nowMS: Double) -> Outcome {
        // Only measurements taken AFTER the last flip may drive the next one.
        let measuredSinceFlip = measurement.layoutEpoch > flipEpoch && measurement.lastWidth > 0
        if measuredSinceFlip {
            // A same-mode width change is an interactive window/pane resize.
            if lastSeenWidth > 0, abs(measurement.lastWidth - lastSeenWidth) > 0.5 {
                widthChangedAtMS = nowMS
            }
            lastSeenWidth = measurement.lastWidth
            if expanded {
                if expandedAnchor <= 0 { expandedAnchor = measurement.lastWidth }
            } else {
                // The compact pill's content box IS the layout-stable capacity.
                compactCapacity = measurement.lastWidth - 8
            }
        }

        let resizing = Self.isResizing(widthChangedAtMS: widthChangedAtMS, nowMS: nowMS)
        let capacity = capacity(lastWidth: measurement.lastWidth)
        let next = Metrics.shouldExpand(
            expanded: expanded,
            textWidth: measurement.textWidth,
            capacity: capacity,
            hasNewline: measurement.hasNewline,
            resizing: resizing
        )
        let committedFlip = next != expanded && measuredSinceFlip
        if committedFlip {
            expanded = next
            flipEpoch = measurement.layoutEpoch
            expandedAnchor = 0
            // The mode change moves the input width; don't read that jump as
            // an interactive resize.
            lastSeenWidth = 0
        }
        return Outcome(
            expanded: expanded,
            committedFlip: committedFlip,
            resizing: resizing,
            capacity: capacity
        )
    }

    /// The layout-stable compact capacity for a measured input width.
    ///
    /// Compact measures it directly; expanded carries the learned value shifted
    /// by the container's resize delta (the expanded input width tracks the
    /// container 1:1). Before any measurement it is `.infinity`, which is what
    /// makes a fresh composer start compact.
    public func capacity(lastWidth: CGFloat) -> CGFloat {
        if !expanded {
            return lastWidth > 0 ? lastWidth - 8 : .infinity
        }
        guard compactCapacity > 0 else { return .infinity }
        if expandedAnchor > 0, lastWidth > 0 {
            return compactCapacity + (lastWidth - expandedAnchor)
        }
        return compactCapacity
    }

    /// `resizing` — true for ``SupermuxZeronMetrics/Composer/resizeSettleMS``
    /// after the last same-mode width change. Re-evaluate at
    /// ``SupermuxZeronMetrics/Composer/resizeReevaluateMS`` (settle + 20).
    public static func isResizing(widthChangedAtMS: Double?, nowMS: Double) -> Bool {
        guard let widthChangedAtMS else { return false }
        return nowMS - widthChangedAtMS < Double(Metrics.resizeSettleMS)
    }

    /// Forces the expanded layout without disturbing the learned capacity.
    ///
    /// zeron's `let expanded = expanded || new_chat`: a new-chat canvas always
    /// renders expanded because the repo/branch pickers need the full-width
    /// actions row, and a mode flip in that state never morphs.
    public static func forcedExpanded(_ expanded: Bool, newChat: Bool) -> Bool {
        expanded || newChat
    }

    // MARK: Auto-grow (composer.rs:129-146)

    /// `max(1, wrappedLineCount) × 22.75`.
    public static func contentHeight(wrappedLineCount: Int) -> CGFloat {
        Metrics.contentHeight(lineCount: wrappedLineCount)
    }

    /// `clamp(contentHeight + 20, 76, 260) + 46 + 2`. Range **124 … 308**.
    public static func expandedTotalHeight(contentHeight: CGFloat) -> CGFloat {
        Metrics.totalHeight(contentHeight: contentHeight)
    }

    /// The mode's base pill height before staged attachments are added.
    public static func baseHeight(expanded: Bool, contentHeight: CGFloat) -> CGFloat {
        expanded ? expandedTotalHeight(contentHeight: contentHeight) : Metrics.compactTotal
    }

    /// The text element's own viewport: `TEXTAREA_MAX − TEXTAREA_PAD_V` = 240.
    /// Past this the input scrolls INTERNALLY rather than growing.
    public static let maxContentHeight: CGFloat = Metrics.textareaMax - Metrics.textareaPadV

    /// The expanded text box's height: the clamped 76…260 box.
    /// Laid out at the TARGET size so the committed layout never reflows
    /// mid-tween and the caret cannot jump.
    public static func textBoxHeight(expandedBaseHeight: CGFloat) -> CGFloat {
        max(expandedBaseHeight - Metrics.pillBorderV - Metrics.actionsRowHeight, 0)
    }

    /// The compact pill's inner row: `49 − 2` = **47**, bottom-justified so the
    /// pill's bottom edge is stationary on screen.
    public static let compactRowHeight: CGFloat = Metrics.compactTotal - Metrics.pillBorderV

    /// The control cluster's resting right inset in COMPACT mode (`pr-2`).
    /// Expanded rests at this plus ``SupermuxZeronMetrics/Composer/clusterXDelta``
    /// (`px-3` = 12); the morph glides between the two.
    public static let compactClusterInset: CGFloat = 8
    /// The compact input's leading inset (`pl-4`).
    public static let compactTextPadLeading: CGFloat = Metrics.textBoxPadX
    /// The compact input's trailing inset (`pr-2`).
    public static let compactTextPadTrailing: CGFloat = 8
    /// The expanded actions row's leading inset (`pl-3`).
    public static let actionsPadLeading: CGFloat = 12
    /// The COMPACT cluster's own leading inset (`pl-1`) — the air between the
    /// input's trailing edge and the first chip.
    public static let compactClusterPadLeading: CGFloat = 4
    /// The expanded actions row's top / bottom padding (`pt-1` / `pb-2.5`),
    /// which is where the 46 pt row height comes from: 4 + 32 + 10.
    public static let actionsPadTop: CGFloat = 4
    public static let actionsPadBottom: CGFloat = 10
    /// The gap between the cluster's own children (`gap-1`) — identical in both
    /// modes, which is the whole point of ``clusterInset(morph:)``.
    public static let clusterGap: CGFloat = 4
    /// The attach button's `ml-1`: chips→attach reads 8 pt total (4 gap + 4
    /// margin) in BOTH modes.
    public static let attachLeadingMargin: CGFloat = 4

    // Two `trigger_chip` values the shared metrics table does not carry yet
    // (`SupermuxZeronMetrics.Composer` has the height/radius/padding/gap/icon
    // but not these). Declared here so the composer does not have to reach into
    // another workstream's file; fold them into §1.4 when that file next moves.

    /// `trigger_chip` label size — 12 pt MEDIUM (`pickers.rs:2017`).
    public static let chipTextSize: CGFloat = 12
    /// `trigger_chip` max width — 208 pt, with `min_w_0` so it shrinks and
    /// truncates under row pressure (`pickers.rs:1987`).
    public static let chipMaxWidth: CGFloat = 208

    // MARK: Attachment strip (composer.rs:203)

    /// The height `count` staged thumbs add to the pill at an `innerWidth`
    /// content width — an exact flex-wrap model, added in **both** modes.
    ///
    /// `innerWidth` is the last measured input width, falling back to 720
    /// before the first measure.
    public static func attachmentStripHeight(count: Int, innerWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = attachmentRowCount(count: count, innerWidth: innerWidth)
        return Metrics.stripPadTop
            + CGFloat(rows) * Metrics.stripThumb
            + CGFloat(rows - 1) * Metrics.stripGap
    }

    /// Thumbs that fit on one row at this content width (at least 1).
    public static func attachmentsPerRow(innerWidth: CGFloat) -> Int {
        let usable = max(innerWidth - 2 * Metrics.stripPadX, Metrics.stripThumb)
        let fit = ((usable + Metrics.stripGap) / (Metrics.stripThumb + Metrics.stripGap))
            .rounded(.down)
        return max(Int(fit), 1)
    }

    /// Wrapped row count for `count` thumbs — the same model the height uses,
    /// so the rendered rows and the analytic height cannot disagree.
    public static func attachmentRowCount(count: Int, innerWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let perRow = attachmentsPerRow(innerWidth: innerWidth)
        return (count + perRow - 1) / perRow
    }

    /// The pill's full target height: the mode's base plus the strip.
    public static func targetHeight(
        expanded: Bool,
        contentHeight: CGFloat,
        attachmentCount: Int = 0,
        innerWidth: CGFloat = 720
    ) -> CGFloat {
        baseHeight(expanded: expanded, contentHeight: contentHeight)
            + attachmentStripHeight(count: attachmentCount, innerWidth: innerWidth)
    }

    // MARK: The flip morph (composer.rs:229-360)

    /// One committed flip's 180 ms `COLLAPSE` morph.
    ///
    /// Animates the pill's **committed height only** — the layout below is
    /// already the new mode's, so the caret never jumps and the input entity
    /// never remounts. It tracks a LIVE target (auto-grow can move it
    /// mid-flight) and `from` is the height actually rendered last frame, so a
    /// reversal mid-flight hands off seamlessly instead of popping.
    public struct Morph: Sendable, Equatable, Hashable {
        /// The rendered height when the flip committed.
        public var from: CGFloat
        /// Commit time on the caller's monotonic ms clock.
        public var startMS: Double

        public init(from: CGFloat, startMS: Double) {
            self.from = from
            self.startMS = startMS
        }

        /// Raw timeline position 0…1 across `COLLAPSE`'s 180 ms.
        public func raw(nowMS: Double) -> Double {
            let total = Double(SupermuxZeronMetrics.Motion.collapse.durationMS)
            guard total > 0 else { return 1 }
            return min(max((nowMS - startMS) / total, 0), 1)
        }

        /// Eased progress 0…1.
        public func progress(nowMS: Double) -> Double {
            SupermuxZeronMetrics.Motion.collapse.curve.eval(raw(nowMS: nowMS))
        }

        public func isDone(nowMS: Double) -> Bool { raw(nowMS: nowMS) >= 1 }

        /// Eased lerp from the flip-time height to the LIVE target.
        public func height(target: CGFloat, nowMS: Double) -> CGFloat {
            let t = CGFloat(progress(nowMS: nowMS))
            return from + (target - from) * t
        }
    }

    /// Advances the morph across one render pass.
    ///
    /// A same-mode render can NEVER restart the animation. Reduced motion, a
    /// first paint with no measured height, and a session/route change within
    /// `ROUTE_SNAP_MS` all snap — `routeSnap` additionally kills anything in
    /// flight, because navigation never animates the pill.
    public static func stepMorph(
        _ morph: Morph?,
        modeChanged: Bool,
        lastHeight: CGFloat,
        nowMS: Double,
        reduceMotion: Bool,
        routeSnap: Bool
    ) -> Morph? {
        if routeSnap { return nil }
        if !modeChanged { return morph.flatMap { $0.isDone(nowMS: nowMS) ? nil : $0 } }
        if reduceMotion || lastHeight <= 0 { return nil }
        return Morph(from: lastHeight, startMS: nowMS)
    }

    // MARK: Morph anchoring (composer.rs:263-320)

    /// The cluster's right inset for an in-flight morph: compact 8 ↔ expanded
    /// 12. Pairwise button distances never change; the cluster glides as one.
    ///
    /// **Direction is keyed on the COMMITTED mode, not on progress alone.**
    /// Expanding eases 8 → 12; collapsing eases 12 → 8. Both land on the
    /// committed mode's resting inset at t = 1, which is the invariant that
    /// makes a reversal mid-flight land correctly.
    public static func clusterInset(expanded: Bool, morph progress: Double) -> CGFloat {
        let t = CGFloat(min(max(progress, 0), 1))
        let compact = compactClusterInset
        let wide = compact + Metrics.clusterXDelta
        return expanded ? compact + (wide - compact) * t : wide + (compact - wide) * t
    }

    /// The expanded text box's top pad across the morph: 12 (the compact `py-3`
    /// centering inset) → 16 (`pt-4`), so the first line glides with the rising
    /// top edge instead of jumping at the commit.
    public static func textTopPad(morph progress: Double) -> CGFloat {
        let t = CGFloat(min(max(progress, 0), 1))
        return Metrics.textBoxPadTopCompact
            + (Metrics.textBoxPadTop - Metrics.textBoxPadTopCompact) * t
    }

    /// The decaying 2.5 pt centering delta for the whole control cluster.
    ///
    /// Send/attach centre 27 pt above the pill's outer bottom expanded
    /// (`pb-2.5` 10 + half the 32 pt content zone + 1 pt hairline) but 24.5 pt
    /// compact (centred in the 47 pt row) — an inherent 2.5 pt delta between
    /// the two SOURCE geometries, which the morph glides instead of snapping.
    ///
    /// **The magnitude is mode-independent; the SIGN is not.** gpui applies it
    /// as `bottom(-dy)` expanded (the row rides 2.5 pt DOWN) and `top(-dy)`
    /// compact (the cluster rides 2.5 pt UP), so a caller must negate it in the
    /// compact branch. See ``clusterOffsetY(expanded:morph:)``.
    ///
    /// The cluster rides the stationary bottom anchor at FULL alpha throughout:
    /// any fade on the picker chips read as flicker, and their screen position
    /// is near-stationary across the flip, so nothing needs hiding.
    public static func clusterDY(morph progress: Double) -> CGFloat {
        Metrics.clusterYDelta * CGFloat(1 - min(max(progress, 0), 1))
    }

    /// ``clusterDY(morph:)`` with the mode's sign already applied, as a SwiftUI
    /// `.offset(y:)` (positive = down).
    public static func clusterOffsetY(expanded: Bool, morph progress: Double) -> CGFloat {
        let dy = clusterDY(morph: progress)
        return expanded ? dy : -dy
    }

    /// Collapse-morph text glide, in points ABOVE the compact resting place.
    ///
    /// The committed compact row is bottom-anchored (text rests 36 pt above the
    /// pill's outer bottom); at the commit instant the text sat 17 pt below the
    /// expanded pill's top, i.e. `from − 17` above the bottom — so it starts
    /// `from − 53` too high. The offset DECAYS to zero, walking the text down.
    public static func collapseTextGlide(from: CGFloat, morph progress: Double) -> CGFloat {
        max(from - 53, 0) * CGFloat(1 - min(max(progress, 0), 1))
    }

    // MARK: Caret (composer.rs:118-127)

    /// `(ms / 500) % 2 == 0` — a hard 500 ms square wave with no fade. The
    /// phase resets on every keystroke and caret move, so a typing burst is
    /// always solid.
    public static func caretVisible(msSinceActivity: Double) -> Bool {
        guard msSinceActivity >= 0 else { return true }
        return Int(msSinceActivity / Double(Metrics.caretBlinkMS)) % 2 == 0
    }
}
