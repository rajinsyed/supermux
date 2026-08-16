//
//  SupermuxZeronFoldTween.swift
//  SupermuxZeronUI
//
//  The tool-group / chip-detail fold: a `(from, to, startedAt)` height tween
//  plus the 400 ms ARMING WINDOW. Spec 03 §6, spec 07 §2.5, plan R5.
//
//  ── Why an arming window exists at all ──
//
//  gpui replays an element's `with_animation` from t=0 on every remount, and a
//  virtualized transcript remounts a row every time it scrolls back into view.
//  An always-armed fold therefore made "every once-collapsed group flash
//  open→closed on each reappearance" (zeron user report). SwiftUI has the exact
//  same failure: `.animation(_:value:)` re-fires when a view's identity churns,
//  and scrolling a `LazyVStack` row out and back IS identity churn.
//
//  The fix is zeron's: a fold animates ONLY while `now - toggledAt < 400 ms`
//  ("the RESIZE spec's 200 ms plus margin"). Past that it renders at its static
//  height and a remount produces no motion at all.
//
//  ── Why the state lives ABOVE the lazy boundary ──
//
//  Two reasons, and they are the same reason. (1) A fold kept in the row's own
//  `@State` is destroyed by recycling, so a group would forget it was open.
//  (2) This repo's SwiftUI list-boundary rule (cmux #2586, a 100 % CPU spin)
//  forbids any view below a `LazyVStack`/`List`/`ForEach` from holding an
//  observable store reference. So ``SupermuxZeronFoldStore`` is owned by the
//  transcript host, and rows receive a plain ``SupermuxZeronFold`` VALUE plus a
//  ``SupermuxZeronFoldActions`` closure bundle — never the store.
//
//  ``SupermuxZeronFold/height(target:now:)`` is a PURE read of wall-clock: it
//  computes the tween's current height from `(from, target, toggledAt)` with no
//  state write, so a row can evaluate it inside `body` without violating the
//  second half of that rule.
//

public import Foundation
public import SwiftUI

public import SupermuxClaudeHarness

// MARK: - One fold

/// One fold's state: the user's pin plus the armed height tween.
///
/// Ported from zeron's `FoldState` (`transcript.rs:1308`). Group folds are
/// keyed by the row id, detail folds by `"{rowID}#d{index}"`; neither is ever
/// part of a row's fingerprint, so toggling a fold never rebuilds a row.
public struct SupermuxZeronFold: Sendable, Equatable, Hashable {
    /// `nil` follows the group's auto-open rule; a `.some` value is a user pin
    /// that overrides auto-open forever after.
    public var open: Bool?
    /// Bumped on every toggle. A SECOND tap inside the arming window must
    /// restart a fresh tween rather than resume the stale one, which is what
    /// this counter keys.
    public var epoch: Int
    /// The height at the instant of the toggle — the tween's start value.
    public var from: CGFloat
    /// When the toggle happened. `nil` means the fold has never been touched.
    public var toggledAt: Date?

    public init(
        open: Bool? = nil,
        epoch: Int = 0,
        from: CGFloat = 0,
        toggledAt: Date? = nil
    ) {
        self.open = open
        self.epoch = epoch
        self.from = from
        self.toggledAt = toggledAt
    }

    /// An untouched fold: no pin, no armed tween.
    public static let settled = SupermuxZeronFold()

    /// The resolved open state. A user pin wins; otherwise the group's
    /// auto-open rule (streaming AND trailing) decides.
    public func isOpen(autoOpen: Bool) -> Bool { open ?? autoOpen }

    /// Whether the tween is still armed at `now`.
    ///
    /// This is the whole remount guard: it is a function of wall-clock only, so
    /// a row that scrolls back into view 30 s later reads `false` and renders
    /// statically no matter how many times SwiftUI rebuilds it.
    public func isArmed(now: Date) -> Bool {
        guard epoch > 0, let toggledAt else { return false }
        let elapsedMS = now.timeIntervalSince(toggledAt) * 1000
        return elapsedMS >= 0 && elapsedMS < SupermuxZeronMetrics.Fold.tweenWindowMS
    }

    /// The tween's height at `now` — a PURE read, safe to evaluate in `body`.
    ///
    /// Returns `target` outright when the fold is settled, which is exactly
    /// what makes a remount static. `target` is always the CURRENT analytic
    /// height, never a value captured at the click, so content growth after a
    /// toggle snaps to the new destination instead of replaying a stale tween.
    public func height(target: CGFloat, now: Date) -> CGFloat {
        guard isArmed(now: now), let toggledAt else { return target }
        let spec = SupermuxZeronMetrics.Motion.resize
        let duration = Double(spec.durationMS)
        guard duration > 0 else { return target }
        let raw = now.timeIntervalSince(toggledAt) * 1000 / duration
        let t = spec.curve.eval(min(max(raw, 0), 1))
        return from + (target - from) * CGFloat(t)
    }

    /// The animation to hand `.animation(_:value:)`, or `nil` when the fold is
    /// settled.
    ///
    /// Returning `nil` is the SwiftUI half of the arming window: an unarmed
    /// fold attaches no animation, so a `LazyVStack` remount cannot replay one.
    public func animation(now: Date) -> Animation? {
        isArmed(now: now) ? SupermuxZeronMetrics.Motion.resize.animation : nil
    }

    /// Arms the tween from a known height WITHOUT changing the open state.
    ///
    /// This is the group half of the coupled tween (spec 03 §6.3): expanding a
    /// chip changes the group body's analytic height, and without arming it the
    /// row would snap to the new height while the card was still mid-tween —
    /// content below teleported on expand and the shrinking card clipped on
    /// collapse.
    public mutating func arm(from: CGFloat, at now: Date) {
        self.from = from
        epoch += 1
        toggledAt = now
    }

    /// Flips the pin and arms the tween from the pre-click height.
    public mutating func toggle(from: CGFloat, autoOpen: Bool, at now: Date) {
        let wasOpen = isOpen(autoOpen: autoOpen)
        open = !wasOpen
        arm(from: from, at: now)
    }
}

// MARK: - Toggle intent

/// One fold toggle: which fold, the height it starts from, and the auto-open
/// rule the pin has to overrule.
///
/// The view computes `from` because only the view knows the analytic geometry;
/// this mirrors zeron's `toggle_fold(row_id, open_height, auto_open)`.
public struct SupermuxZeronFoldToggle: Sendable, Equatable, Hashable {
    /// The fold's key: a row id for a group, `"{rowID}#d{index}"` for a detail.
    public let key: String
    /// The fold's height at the instant of the tap — the tween's start.
    public let from: CGFloat
    /// The auto-open rule this key follows while unpinned.
    public let autoOpen: Bool

    public init(key: String, from: CGFloat, autoOpen: Bool = false) {
        self.key = key
        self.from = from
        self.autoOpen = autoOpen
    }
}

/// The closure bundle a transcript row receives INSTEAD of the fold store.
///
/// Same shape and same reason as `IndexSectionActions` in `SessionIndexView`:
/// every capability a row needs is a closure, so a future
/// `let store: SupermuxZeronFoldStore` on a chip becomes a type error rather
/// than a silent 100 % CPU regression (cmux #2586).
public struct SupermuxZeronFoldActions: Sendable {
    /// Toggle a tool group's fold.
    public var toggleGroup: @MainActor @Sendable (SupermuxZeronFoldToggle) -> Void
    /// Toggle one chip's detail fold AND arm the group's height tween.
    ///
    /// Two arguments because it is genuinely two effects: the chip's pin flips,
    /// the group's open state does NOT — it is only armed, so both heights
    /// animate from the same instant on the same curve and the row tracks the
    /// card's bottom edge frame-for-frame (spec 03 §6.3).
    public var toggleDetail: @MainActor @Sendable (
        _ detail: SupermuxZeronFoldToggle,
        _ armGroup: SupermuxZeronFoldToggle
    ) -> Void
    /// Fetch a chip's full output/diff sidecar. No-op when nothing is offered.
    public var fetchBlob: @MainActor @Sendable (SupermuxZeronBlobAffordance) -> Void

    public init(
        toggleGroup: @escaping @MainActor @Sendable (SupermuxZeronFoldToggle) -> Void,
        toggleDetail: @escaping @MainActor @Sendable (
            SupermuxZeronFoldToggle, SupermuxZeronFoldToggle
        ) -> Void,
        fetchBlob: @escaping @MainActor @Sendable (SupermuxZeronBlobAffordance) -> Void = { _ in }
    ) {
        self.toggleGroup = toggleGroup
        self.toggleDetail = toggleDetail
        self.fetchBlob = fetchBlob
    }

    /// A bundle that does nothing — for previews and for hosts that render a
    /// transcript read-only.
    public static let inert = SupermuxZeronFoldActions(
        toggleGroup: { _ in },
        toggleDetail: { _, _ in },
        fetchBlob: { _ in }
    )
}

// MARK: - One group's folds

/// A tool group's fold state, resolved for one render pass.
///
/// A plain value: the group row holds this, never the store.
public struct SupermuxZeronToolGroupFolds: Sendable, Equatable, Hashable {
    /// The group body's fold.
    public var group: SupermuxZeronFold
    /// Per-chip detail folds, index-aligned with the group's `tools`.
    public var details: [SupermuxZeronFold]

    public init(group: SupermuxZeronFold = .settled, details: [SupermuxZeronFold] = []) {
        self.group = group
        self.details = details
    }

    /// The detail fold at `index`, or a settled one when the array is short
    /// (a group that grew a chip since the snapshot was taken).
    public func detail(_ index: Int) -> SupermuxZeronFold {
        details.indices.contains(index) ? details[index] : .settled
    }

    /// Every fold settled — the state a group starts in.
    public static func settled(count: Int) -> SupermuxZeronToolGroupFolds {
        SupermuxZeronToolGroupFolds(
            group: .settled,
            details: Array(repeating: .settled, count: max(0, count))
        )
    }
}

// MARK: - The store

/// The transcript-owned fold store. **Lives above the lazy list boundary.**
///
/// Rows read a ``SupermuxZeronToolGroupFolds`` value out of it and receive
/// ``actions``; they never see this object. Toggling mutates only this
/// dictionary, so a fold never invalidates a row's identity or fingerprint —
/// which is precisely zeron's `cx.notify()`-without-rebuild behaviour.
@MainActor
@Observable
public final class SupermuxZeronFoldStore {
    private var folds: [String: SupermuxZeronFold] = [:]

    public init() {}

    /// The detail-fold key for one chip, `"{rowID}#d{index}"` (zeron's own).
    public static func detailKey(rowID: String, index: Int) -> String {
        "\(rowID)#d\(index)"
    }

    /// The fold stored under `key`, or a settled one.
    public func fold(_ key: String) -> SupermuxZeronFold {
        folds[key] ?? .settled
    }

    /// One render pass's snapshot for a group row.
    public func folds(for group: SupermuxHarnessToolGroup) -> SupermuxZeronToolGroupFolds {
        SupermuxZeronToolGroupFolds(
            group: fold(group.id),
            details: group.tools.indices.map { fold(Self.detailKey(rowID: group.id, index: $0)) }
        )
    }

    /// Flip a group's fold and arm its tween.
    public func toggleGroup(_ toggle: SupermuxZeronFoldToggle, at now: Date = Date()) {
        var fold = fold(toggle.key)
        fold.toggle(from: toggle.from, autoOpen: toggle.autoOpen, at: now)
        folds[toggle.key] = fold
    }

    /// Flip a chip's detail fold and ARM the group's tween without changing the
    /// group's open state (spec 03 §6.3). Both tweens share this instant.
    public func toggleDetail(
        _ detail: SupermuxZeronFoldToggle,
        armGroup: SupermuxZeronFoldToggle,
        at now: Date = Date()
    ) {
        var chip = fold(detail.key)
        chip.toggle(from: detail.from, autoOpen: detail.autoOpen, at: now)
        folds[detail.key] = chip

        var group = fold(armGroup.key)
        group.arm(from: armGroup.from, at: now)
        folds[armGroup.key] = group
    }

    /// Drop every fold. For session switches, where the keys no longer exist.
    public func reset() { folds.removeAll() }

    /// The closure bundle to hand down to rows.
    ///
    /// Built fresh per render by the host, exactly like `IndexSectionActions`:
    /// the closures capture `self`, the rows capture only the closures.
    public var actions: SupermuxZeronFoldActions {
        SupermuxZeronFoldActions(
            toggleGroup: { [weak self] toggle in self?.toggleGroup(toggle) },
            toggleDetail: { [weak self] detail, group in
                self?.toggleDetail(detail, armGroup: group)
            }
        )
    }
}
