import SwiftUI
import Testing
@testable import SupermuxZeronUI

/// The curve solver's reference fixtures.
///
/// Values come from spec 07 §1 (zeron's own `bezier_known_values`, computed
/// independently with 80-step bisection). Tolerance 1e-3, as the spec states.
struct SupermuxZeronCubicBezierTests {
    private static let tolerance = 1e-3
    private static let sampleXs: [Double] = [0.10, 0.25, 0.50, 0.75, 0.90]

    private static let catalog: [SupermuxZeronCubicBezier] = [
        .easeOutExpo, .easeOut, .ease, .easeResort, .easeInOut, .easeTailwind,
    ]

    @Test("EASE_OUT_EXPO matches the five reference values")
    func easeOutExpoFixtures() {
        let expected: [Double] = [0.494391, 0.825622, 0.971779, 0.997677, 0.999878]
        for (x, want) in zip(Self.sampleXs, expected) {
            let got = SupermuxZeronCubicBezier.easeOutExpo.eval(x)
            #expect(abs(got - want) <= Self.tolerance, "eval(\(x)) = \(got), want \(want)")
        }
    }

    @Test("EASE_OUT matches the five reference values")
    func easeOutFixtures() {
        let expected: [Double] = [0.160572, 0.378138, 0.684643, 0.906535, 0.982973]
        for (x, want) in zip(Self.sampleXs, expected) {
            let got = SupermuxZeronCubicBezier.easeOut.eval(x)
            #expect(abs(got - want) <= Self.tolerance, "eval(\(x)) = \(got), want \(want)")
        }
    }

    @Test("EASE matches the five reference values")
    func easeFixtures() {
        let expected: [Double] = [0.094796, 0.408511, 0.802403, 0.960459, 0.994316]
        for (x, want) in zip(Self.sampleXs, expected) {
            let got = SupermuxZeronCubicBezier.ease.eval(x)
            #expect(abs(got - want) <= Self.tolerance, "eval(\(x)) = \(got), want \(want)")
        }
    }

    @Test("the named curves carry their exact CSS control points")
    func controlPoints() {
        #expect(SupermuxZeronCubicBezier.easeOutExpo == .init(0.16, 1, 0.3, 1))
        #expect(SupermuxZeronCubicBezier.easeOut == .init(0, 0, 0.58, 1))
        #expect(SupermuxZeronCubicBezier.ease == .init(0.25, 0.1, 0.25, 1))
        #expect(SupermuxZeronCubicBezier.easeResort == .init(0.22, 1, 0.36, 1))
        #expect(SupermuxZeronCubicBezier.easeInOut == .init(0.42, 0, 0.58, 1))
        #expect(SupermuxZeronCubicBezier.easeTailwind == .init(0.4, 0, 0.2, 1))
    }

    @Test("a linear curve is the identity")
    func linearIsIdentity() {
        let linear = SupermuxZeronCubicBezier(0, 0, 1, 1)
        for x in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            #expect(abs(linear.eval(x) - x) <= 1e-4)
        }
    }

    @Test("endpoints are exact and out-of-range input clamps")
    func endpointsAndClamping() {
        for curve in Self.catalog {
            #expect(curve.eval(0) == 0)
            #expect(curve.eval(1) == 1)
            #expect(curve.eval(-0.5) == 0)
            #expect(curve.eval(1.5) == 1)
        }
    }

    /// The regression the hard `clamp(0,1)` exists for: f32 rounding pushed
    /// `EASE_OUT_EXPO` to 1.000000119 near its tail, which SIGABRTed gpui. Swift
    /// will not abort, but an opacity > 1 still flashes.
    @Test("eval never escapes the unit interval over a dense sweep")
    func evalNeverEscapesUnitInterval() {
        for curve in Self.catalog {
            for i in 0 ... 20000 {
                let x = Double(i) / 20000
                let y = curve.eval(x)
                #expect((0.0 ... 1.0).contains(y), "eval(\(x)) = \(y) escaped [0,1]")
            }
            for x in [0.999999, 0.9999999, 1 - .ulpOfOne] {
                #expect((0.0 ... 1.0).contains(curve.eval(x)))
            }
        }
    }

    @Test("the catalog curves are monotonic")
    func monotonic() {
        for curve in Self.catalog {
            var last = 0.0
            for i in 0 ... 200 {
                let y = curve.eval(Double(i) / 200)
                #expect(y >= last - 1e-4)
                last = y
            }
        }
    }

    @Test("MotionSpec folds its delay and carries the catalog durations")
    func motionSpecs() {
        typealias Motion = SupermuxZeronMetrics.Motion
        #expect(Motion.fadeIn.durationMS == 500)
        #expect(Motion.fadeQuick.durationMS == 150)
        #expect(Motion.menuIn.durationMS == 140)
        #expect(Motion.menuOut.durationMS == 100)
        #expect(Motion.dialogIn.durationMS == 180)
        #expect(Motion.resize.durationMS == 200)
        #expect(Motion.collapse.durationMS == 180)
        #expect(Motion.hoverFade.durationMS == 150)
        #expect(Motion.scrollGlide.durationMS == 500)
        #expect(Motion.zeronPulse.durationMS == 2400)
        #expect(Motion.gradientSpin.durationMS == 750)

        // No-delay specs pass straight through their curve.
        #expect(abs(Motion.fadeIn.progress(0.5) - SupermuxZeronCubicBezier.easeOutExpo.eval(0.5)) < 1e-9)

        // A delayed spec holds 0 through the delay: 150 ms + 500 ms = 650 ms.
        let splashOut = SupermuxZeronMetrics.MotionSpec(500, .ease, delayMS: 150)
        #expect(splashOut.totalDuration == 0.650)
        #expect(splashOut.progress(0) == 0)
        #expect(splashOut.progress(0.2) == 0) // 130 ms < 150 ms
        #expect(splashOut.progress(1) == 1)
        #expect(splashOut.progress(2) == 1)
        let mid = splashOut.progress(0.65)
        #expect(mid > 0 && mid < 1)
    }
}
