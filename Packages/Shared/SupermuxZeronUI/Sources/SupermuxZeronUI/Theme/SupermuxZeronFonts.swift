//
//  SupermuxZeronFonts.swift
//  SupermuxZeronUI
//
//  Geist / Geist Mono registration and access. Plan §6.1 and risk R10.
//
//  ── Why registration is manual ──
//
//  SPM resource bundles are NOT covered by `UIAppFonts` (iOS) or
//  `ATSApplicationFontsPath` (macOS): those keys are read from the *app*
//  bundle's Info.plist, and `Bundle.module` is a nested resource bundle the
//  loader never scans. The faces must be handed to CoreText explicitly with
//  `CTFontManagerRegisterFontsForURL(.process)`. That happens once, lazily, on
//  first access to any accessor here.
//
//  ── Why a silent fallback is the worst outcome (R10) ──
//
//  Geist is noticeably NARROWER than SF Pro at the same size, so if
//  registration fails every measured width in the specs shifts, text rewraps,
//  and the analytic heights in `SupermuxZeronMetrics` stop matching the
//  content. `Font.custom` falls back silently and cheerfully. So
//  ``diagnostic`` is published, ``assertRegistered()` traps in debug, and the
//  fallback chain is zeron's own (`Helvetica`/`Menlo` on macOS, the system
//  faces on iOS) — deliberately NOT SF Pro/SF Mono.
//
//  ── Why weights go through named instances, not `.weight()` ──
//
//  Both faces are variable (`wght` 100–900, default 400). Building a descriptor
//  with `kCTFontWeightTrait` — which is what SwiftUI's `Font.weight(_:)` does
//  for a custom font — was measured on this toolchain to return `Geist-Regular`
//  with an EMPTY variation dictionary: the axis is not applied and the glyphs
//  stay at 400. Resolving the face's own named instance by PostScript name
//  DOES apply it (verified: `Geist-SemiBold` reports `wght: 600` and a wider
//  'H' advance, 10.060 vs 9.982 at 14 pt). Both fonts ship all nine named
//  instances, so every weight in the design system is reachable this way.
//  Geist Mono's advances are weight-invariant by construction (8.3999 at every
//  weight), which is exactly what a monospace face must do.
//

public import CoreText
public import SwiftUI

internal import Foundation

#if canImport(AppKit)
public import AppKit
/// The platform font type whose metrics the fixed-line-box math reads.
public typealias SupermuxZeronPlatformFont = NSFont
#elseif canImport(UIKit)
public import UIKit
/// The platform font type whose metrics the fixed-line-box math reads.
public typealias SupermuxZeronPlatformFont = UIFont
#endif

// MARK: - Weights

/// The weights the zeron design system uses, as the faces' own named instances.
///
/// gpui's four in-use tokens are NORMAL 400 (5×), MEDIUM 500 (39×),
/// SEMIBOLD 600 (13×) and BOLD 700 (4×); the rest of the axis is exposed
/// because the faces ship it and a future surface may want it.
public enum SupermuxZeronFontWeight: Int, Sendable, Equatable, Hashable, CaseIterable {
    case thin = 100
    case extraLight = 200
    case light = 300
    case regular = 400
    case medium = 500
    case semibold = 600
    case bold = 700
    case extraBold = 800
    case black = 900

    /// The named-instance suffix appended to a family's PostScript base.
    fileprivate var postScriptSuffix: String {
        switch self {
        case .thin: "Thin"
        case .extraLight: "ExtraLight"
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold: "Bold"
        case .extraBold: "ExtraBold"
        case .black: "Black"
        }
    }

    /// The nearest system weight, for the fallback chain only.
    fileprivate var systemWeight: Font.Weight {
        switch self {
        case .thin: .thin
        case .extraLight: .ultraLight
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .extraBold: .heavy
        case .black: .black
        }
    }

    fileprivate var platformWeight: SupermuxZeronPlatformFont.Weight {
        switch self {
        case .thin: .thin
        case .extraLight: .ultraLight
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .extraBold: .heavy
        case .black: .black
        }
    }
}

// MARK: - Fonts

/// Registration and access for the vendored Geist faces.
///
/// lint:allow namespace-type — font table + registration, no instance state.
/// (lint:allow)
public enum SupermuxZeronFonts {
    // MARK: Family identity

    /// PostScript base of the sans family. Named instances are
    /// `"Geist-\(suffix)"`.
    public static let sansPostScriptBase = "Geist"
    /// PostScript base of the mono family.
    public static let monoPostScriptBase = "GeistMono"
    /// The regular faces the launch diagnostic checks for.
    public static let sansRegularPostScriptName = "Geist-Regular"
    public static let monoRegularPostScriptName = "GeistMono-Regular"

    // MARK: Metrics (verified against the vendored binaries)

    /// Face metrics, identical for both families.
    ///
    /// `unitsPerEm 1000, hhea ascender 1005, descender −295, lineGap 0` ⇒ a
    /// natural line height of **1.300 em**. The markdown pipeline needs this
    /// to set a FIXED line box (plan R7): `.lineSpacing` adds space *between*
    /// lines without setting the box, so the first line's ascent comes out
    /// wrong and every block gap drifts by a fraction.
    /// lint:allow namespace-enum, namespace-type — face metrics read off the vendored binaries — constants, not behavior.
    public enum Metrics {
        public static let unitsPerEm: CGFloat = 1000
        public static let hheaAscender: CGFloat = 1005
        public static let hheaDescender: CGFloat = -295
        public static let hheaLineGap: CGFloat = 0
        /// `(1005 + 295 + 0) / 1000`.
        public static let naturalLineHeightMultiple: CGFloat = 1.300

        /// The face's natural line height at a point size — what a paragraph
        /// style would use if it did not pin `minimum/maximumLineHeight`.
        public static func naturalLineHeight(forSize size: CGFloat) -> CGFloat {
            size * naturalLineHeightMultiple
        }

        /// The face's ascender at a point size.
        public static func ascender(forSize size: CGFloat) -> CGFloat {
            size * hheaAscender / unitsPerEm
        }

        /// The face's descender (negative) at a point size.
        public static func descender(forSize size: CGFloat) -> CGFloat {
            size * hheaDescender / unitsPerEm
        }

        /// The leading a fixed line box of `boxHeight` must distribute above
        /// the baseline for text of `size` to sit optically centred in it.
        ///
        /// Used by the markdown renderer: body text is 14 pt in a fixed 22 pt
        /// box, so the box is 1.7 pt taller than the face's natural 18.2.
        public static func boxLeading(forSize size: CGFloat, boxHeight: CGFloat) -> CGFloat {
            max(0, boxHeight - naturalLineHeight(forSize: size))
        }
    }

    // MARK: Registration

    /// The outcome of the one-time font registration.
    public struct Diagnostic: Sendable, Equatable, Hashable {
        /// Whether `Geist-Regular` resolves to the vendored face.
        public let sansResolved: Bool
        /// Whether `GeistMono-Regular` resolves to the vendored face.
        public let monoResolved: Bool
        /// Human-readable failures, in registration order. Empty on success.
        public let failures: [String]

        /// True only when BOTH PostScript names resolved. Anything else means
        /// every measured width in the specs has shifted.
        public var isFullyRegistered: Bool { sansResolved && monoResolved }
    }

    /// The registration outcome. Triggers registration on first access.
    public static var diagnostic: Diagnostic { registration }

    /// Whether both faces are available. Call sites fall back automatically;
    /// this is for the launch diagnostic and for tests.
    public static var isRegistered: Bool { registration.isFullyRegistered }

    /// Launch-time guard. Traps in debug builds and logs in release, because a
    /// SILENT fallback to a wider system face is the worst outcome (R10) — the
    /// UI still renders, so nobody notices until every measured width is wrong.
    ///
    /// Call once from the platform shell's startup path.
    @discardableResult
    public static func assertRegistered(
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Diagnostic {
        let result = registration
        if !result.isFullyRegistered {
            let detail = result.failures.isEmpty
                ? "sansResolved=\(result.sansResolved) monoResolved=\(result.monoResolved)"
                : result.failures.joined(separator: "; ")
            assertionFailure(
                """
                SupermuxZeronUI: Geist font registration FAILED (\(detail)). \
                Every measured width in the zeron specs assumes Geist, which is \
                narrower than the system fallback — text will rewrap and the \
                analytic row heights will disagree with the content.
                """,
                file: file,
                line: line
            )
            print("[SupermuxZeronUI] Geist font registration failed: \(detail)")
        }
        return result
    }

    /// Registers both faces exactly once. Swift's lazy global initialization
    /// makes this thread-safe and run-once without a token.
    private static let registration: Diagnostic = {
        var failures: [String] = []
        for file in [sansRegularPostScriptName, monoRegularPostScriptName] {
            // "Geist-Regular" -> "Geist.ttf", "GeistMono-Regular" -> "GeistMono.ttf".
            let base = String(file.prefix(while: { $0 != "-" }))
            guard let url = Bundle.module.url(
                forResource: base,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                failures.append("\(base).ttf missing from Bundle.module/Fonts")
                continue
            }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !ok, let error {
                let cfError = error.takeRetainedValue()
                // Already-registered is success: the app may register the same
                // face from another target, and a second attempt is harmless.
                let alreadyRegistered = CFErrorGetCode(cfError)
                    == CTFontManagerError.alreadyRegistered.rawValue
                if !alreadyRegistered {
                    failures.append("\(base).ttf: \(cfError)")
                }
            }
        }
        return Diagnostic(
            sansResolved: resolvesToVendoredFace(sansRegularPostScriptName),
            monoResolved: resolvesToVendoredFace(monoRegularPostScriptName),
            failures: failures
        )
    }()

    /// CoreText substitutes silently: asking for an unknown PostScript name
    /// returns Helvetica rather than nil. Compare the resolved name back
    /// against the requested one, which is the only reliable check.
    private static func resolvesToVendoredFace(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 14, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName
    }

    // MARK: SwiftUI fonts

    /// Geist at a fixed point size.
    ///
    /// Deliberately `fixedSize` — the zeron layout is analytic (every row
    /// height in `SupermuxZeronMetrics` is computed, never measured), so a
    /// Dynamic Type-scaled body would desynchronize the fold tweens and clip
    /// rows. Surfaces that want Dynamic Type scale the *point size* they pass
    /// in and recompute their metrics from it.
    public static func sans(size: CGFloat, weight: SupermuxZeronFontWeight = .regular) -> Font {
        custom(base: sansPostScriptBase, size: size, weight: weight, monospaced: false)
    }

    /// Geist Mono at a fixed point size.
    public static func mono(size: CGFloat, weight: SupermuxZeronFontWeight = .regular) -> Font {
        custom(base: monoPostScriptBase, size: size, weight: weight, monospaced: true)
    }

    private static func custom(
        base: String,
        size: CGFloat,
        weight: SupermuxZeronFontWeight,
        monospaced: Bool
    ) -> Font {
        guard registration.isFullyRegistered else {
            return fallback(size: size, weight: weight, monospaced: monospaced)
        }
        return .custom(postScriptName(base: base, weight: weight), fixedSize: size)
    }

    /// zeron's own fallback chain (`theme.rs:769/779`) — macOS `Helvetica` /
    /// `Menlo`, iOS the system faces. **Not** SF Pro / SF Mono.
    private static func fallback(
        size: CGFloat,
        weight: SupermuxZeronFontWeight,
        monospaced: Bool
    ) -> Font {
        #if canImport(AppKit)
        return Font.custom(monospaced ? "Menlo" : "Helvetica", fixedSize: size)
            .weight(weight.systemWeight)
        #else
        return .system(
            size: size,
            weight: weight.systemWeight,
            design: monospaced ? .monospaced : .default
        )
        #endif
    }

    /// The named-instance PostScript name for a family + weight, e.g.
    /// `"Geist-SemiBold"`, `"GeistMono-Medium"`.
    public static func postScriptName(
        base: String,
        weight: SupermuxZeronFontWeight
    ) -> String {
        "\(base)-\(weight.postScriptSuffix)"
    }

    // MARK: Platform fonts (for TextKit / AppKit / UIKit line-box math)

    /// The `NSFont`/`UIFont` behind ``sans(size:weight:)``.
    public static func platformSans(
        size: CGFloat,
        weight: SupermuxZeronFontWeight = .regular
    ) -> SupermuxZeronPlatformFont {
        platformFont(base: sansPostScriptBase, size: size, weight: weight, monospaced: false)
    }

    /// The `NSFont`/`UIFont` behind ``mono(size:weight:)``.
    public static func platformMono(
        size: CGFloat,
        weight: SupermuxZeronFontWeight = .regular
    ) -> SupermuxZeronPlatformFont {
        platformFont(base: monoPostScriptBase, size: size, weight: weight, monospaced: true)
    }

    private static func platformFont(
        base: String,
        size: CGFloat,
        weight: SupermuxZeronFontWeight,
        monospaced: Bool
    ) -> SupermuxZeronPlatformFont {
        let name = postScriptName(base: base, weight: weight)
        let key = CacheKey(name: name, size: size)
        if let cached = platformFontCache.value(for: key) { return cached }

        let resolved: SupermuxZeronPlatformFont
        if registration.isFullyRegistered,
           let font = SupermuxZeronPlatformFont(name: name, size: size) {
            resolved = font
        } else {
            #if canImport(AppKit)
            resolved = NSFont(name: monospaced ? "Menlo" : "Helvetica", size: size)
                ?? .systemFont(ofSize: size, weight: weight.platformWeight)
            #else
            resolved = monospaced
                ? .monospacedSystemFont(ofSize: size, weight: weight.platformWeight)
                : .systemFont(ofSize: size, weight: weight.platformWeight)
            #endif
        }
        platformFontCache.store(resolved, for: key)
        return resolved
    }

    private struct CacheKey: Hashable, Sendable {
        let name: String
        let size: CGFloat
    }

    /// A tiny lock-guarded cache. `NSFont`/`UIFont` instances are immutable and
    /// shared freely by AppKit/UIKit themselves, but they are not `Sendable`,
    /// so the storage is `nonisolated(unsafe)` behind an `NSLock` rather than
    /// an `OSAllocatedUnfairLock<State: Sendable>`.
    private final class PlatformFontCache: @unchecked Sendable {
        // lint:allow lock — guards a pure memo of immutable NSFont/UIFont
        // values with no actor to hop to; every call site is a synchronous
        // `body` read, so an actor would make font lookup async.
        private let lock = NSLock()
        private var storage: [CacheKey: SupermuxZeronPlatformFont] = [:]

        func value(for key: CacheKey) -> SupermuxZeronPlatformFont? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func store(_ font: SupermuxZeronPlatformFont, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = font
        }
    }

    private static let platformFontCache = PlatformFontCache()
}
