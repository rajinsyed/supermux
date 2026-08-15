//
//  SupermuxZeronCubicBezier.swift
//  SupermuxZeronUI
//
//  CSS `cubic-bezier(x1, y1, x2, y2)` evaluation, transcribed line-for-line
//  from zeron's `crates/ui/src/motion.rs:135-208`. Plan §1.5.
//
//  Endpoints are fixed at (0,0) and (1,1). Evaluation solves x(t) = input by
//  Newton–Raphson with a bisection fallback — the standard UnitBezier approach.
//
//  ── Why this is transcribed rather than delegated to SwiftUI ──
//
//  `Animation.timingCurve` evaluates the same curve, but only for animations
//  SwiftUI drives. Half of zeron's motion is hand-driven off wall-clock — the
//  fold tween (which must survive a `LazyVStack` remount, plan R5), the hover
//  fade store, the menu-exit progress, the veil — and those need the curve as a
//  pure function. Use ``animation(duration:)`` when SwiftUI drives; use
//  ``eval(_:)`` when we do.
//

public import Foundation
public import SwiftUI

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function.
public struct SupermuxZeronCubicBezier: Sendable, Equatable, Hashable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    // MARK: - Named curves (motion.rs:210-221, 310)

    /// `cubic-bezier(0.16, 1, 0.3, 1)` — zeron's signature entrance, used by
    /// `FADE_IN` only. Violently front-loaded: 97.2 % of a 500 ms fade is done
    /// by 250 ms, which is why the 4 pt rise reads as "already there".
    public static let easeOutExpo = SupermuxZeronCubicBezier(0.16, 1, 0.3, 1)
    /// CSS `ease-out` — `RESIZE`, `TAB_SLIDE`, `COLLAPSE`.
    public static let easeOut = SupermuxZeronCubicBezier(0, 0, 0.58, 1)
    /// CSS `ease` — quick fades, menu/dialog pops.
    public static let ease = SupermuxZeronCubicBezier(0.25, 0.1, 0.25, 1)
    /// `cubic-bezier(0.22, 1, 0.36, 1)` — zeron's sidebar resort glide. Out of
    /// chat-pane scope; exposed so the catalog is complete.
    public static let easeResort = SupermuxZeronCubicBezier(0.22, 1, 0.36, 1)
    /// CSS `ease-in-out` — the transcript scroll glide.
    public static let easeInOut = SupermuxZeronCubicBezier(0.42, 0, 0.58, 1)
    /// Tailwind's default `transition-*` curve — every hover color fade.
    public static let easeTailwind = SupermuxZeronCubicBezier(0.4, 0, 0.2, 1)

    // MARK: - Evaluation

    private static func coefficients(_ a: Double, _ b: Double) -> (Double, Double, Double) {
        let c = 3 * a
        let bb = 3 * (b - a) - c
        let aa = 1 - c - bb
        return (aa, bb, c)
    }

    private func sampleX(_ t: Double) -> Double {
        let (a, b, c) = Self.coefficients(x1, x2)
        return ((a * t + b) * t + c) * t
    }

    private func sampleY(_ t: Double) -> Double {
        let (a, b, c) = Self.coefficients(y1, y2)
        return ((a * t + b) * t + c) * t
    }

    private func sampleXDerivative(_ t: Double) -> Double {
        let (a, b, c) = Self.coefficients(x1, x2)
        return (3 * a * t + 2 * b) * t + c
    }

    /// Curve parameter `t` for a given progress `x` (both 0…1).
    private func solveTForX(_ x: Double) -> Double {
        // Newton–Raphson.
        var t = x
        for _ in 0 ..< 8 {
            let err = sampleX(t) - x
            if abs(err) < 1e-6 { return t }
            let d = sampleXDerivative(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        // Bisection fallback — x(t) is monotonic for valid CSS beziers.
        var lo = 0.0
        var hi = 1.0
        for _ in 0 ..< 32 {
            let mid = (lo + hi) / 2
            if sampleX(mid) < x { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Eased output for input progress `x`, clamped into 0…1 at both ends.
    ///
    /// **The output clamp is load-bearing.** f32 rounding in zeron produced
    /// 1.000000119 near the tail of ``easeOutExpo``, tripping gpui's
    /// `delta ∈ [0,1]` assert and SIGABRTing on a user's machine. Swift will
    /// not abort, but a value > 1 fed into an opacity or a lerp still produces
    /// a visible overshoot flash — so the clamp stays.
    public func eval(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return min(max(sampleY(solveTForX(x)), 0), 1)
    }

    /// This curve as a SwiftUI `Animation`, for the cases where SwiftUI drives
    /// the tween rather than a hand-rolled wall-clock evaluation.
    public func animation(duration: TimeInterval) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}
