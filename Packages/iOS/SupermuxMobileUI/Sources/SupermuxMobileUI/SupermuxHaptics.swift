import CMUXMobileCore
#if canImport(UIKit)
import UIKit
#endif

/// The fork's haptic vocabulary for the Projects surface.
///
/// Thin wrapper over ``MobileHapticFeedback`` so every supermux haptic obeys
/// the app-wide Settings toggle ("Every cmux haptic must go through this
/// type"). Kept as one small vocabulary rather than scattered generator
/// construction, so the feel stays consistent across the section, the nested
/// rows, and the detail screen.
/// lint:allow namespace-enum — haptic-vocabulary facade over the app-wide gated feedback type; stateless, nothing to instantiate.
enum SupermuxHaptics {
    /// Moving between things: expanding a project, opening a nested row.
    @MainActor
    static func selection() {
        #if canImport(UIKit)
        MobileHapticFeedback().impact(style: .light)
        #endif
    }

    /// A committed, consequential action succeeded (run started/stopped).
    @MainActor
    static func success() {
        #if canImport(UIKit)
        MobileHapticFeedback().notification(.success)
        #endif
    }
}
