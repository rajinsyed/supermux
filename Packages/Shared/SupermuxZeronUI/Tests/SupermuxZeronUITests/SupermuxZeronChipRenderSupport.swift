//
//  SupermuxZeronChipRenderSupport.swift
//  SupermuxZeronUITests
//
//  Measures a real laid-out SwiftUI view, so the analytic heights in
//  `SupermuxZeronMetrics` can be checked against what actually paints rather
//  than against themselves.
//
//  ── Why this matters more than a formula test ──
//
//  Plan R4: zeron's fold model is analytic, and SwiftUI measures. If a chip's
//  content ever renders taller than the box the fold reserved, the row clips —
//  silently, and only for the users whose fonts or content triggered it. A test
//  that only re-derives `2 + 38n` from the same constant proves nothing about
//  that failure. This one lays the view out and reads the frame back.
//
//  `NSHostingView` lays out without a window server, which is what lets this run
//  under a plain `swift test`. On any platform where it does not, the measuring
//  helper returns `nil` and the callers skip rather than fail — a measurement we
//  could not take is not evidence of a defect.
//

import CoreGraphics
import SwiftUI
import Testing

@testable import SupermuxZeronUI

#if canImport(AppKit)
import AppKit
#endif

/// Lays a view out at a fixed width and reports the height it actually takes.
@MainActor
enum SupermuxZeronRenderProbe {
    /// The transcript's content column less its rail inset — the width a chip
    /// row is handed in the real layout.
    static let columnWidth: CGFloat = SupermuxZeronMetrics.Transcript.maxContentWidth

    /// The laid-out height of `view` at `width`, or `nil` when this platform
    /// cannot host a view headlessly.
    static func height(of view: some View, width: CGFloat = columnWidth) -> CGFloat? {
        #if canImport(AppKit)
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize.height
        // A zero height means the host never laid out (no graphics context);
        // report "could not measure" rather than a bogus 0.
        return fitting > 0 ? fitting : nil
        #else
        return nil
        #endif
    }

    /// The width `view` ASKS for when nothing constrains it.
    ///
    /// A row that sizes itself to its content honours this, so a body whose
    /// ideal width grows with its content length would widen the whole
    /// transcript column.
    static func idealWidth(of view: some View) -> CGFloat? {
        #if canImport(AppKit)
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize.width
        return fitting > 0 ? fitting : nil
        #else
        return nil
        #endif
    }

    /// How far a measured height may sit from its analytic value.
    ///
    /// SwiftUI sums each child's height in binary floating point, so a stack of
    /// twelve rows lands a fraction of an ulp off the same sum computed in one
    /// expression (measured: 249.0 vs 249 on the notice + hunk + 9-line body).
    /// That is float addition, not a layout defect — the analytic contract is
    /// "the box never overflows by a POINT", so the tolerance is a small
    /// fraction of one.
    static let tolerance: CGFloat = 0.01
}

extension Optional where Wrapped == CGFloat {
    /// True when a measurement is absent (unmeasurable platform) or lands on
    /// `expected` within ``SupermuxZeronRenderProbe/tolerance``.
    ///
    /// Absent counts as satisfied deliberately: a measurement we could not take
    /// is not evidence of a defect, and the analytic assertions beside it still
    /// run everywhere.
    @MainActor
    func matchesAnalytic(_ expected: CGFloat) -> Bool {
        guard let self else { return true }
        return abs(self - expected) <= SupermuxZeronRenderProbe.tolerance
    }
}
