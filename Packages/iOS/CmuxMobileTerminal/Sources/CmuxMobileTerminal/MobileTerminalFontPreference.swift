#if canImport(UIKit)
import Foundation

/// Terminal font sizing constants for the iOS app, in points.
///
/// The mobile terminal renders through libghostty at a point size; the Retina
/// pixel multiplier is applied separately via content scale (see the iOS DPI
/// handling in `ghostty/src/font/face.zig`). Every terminal launches at
/// ``defaultSize``, a comfortable reading size for the phone's narrow screen.
/// The *live* size after the user pinches / taps the zoom buttons is
/// owned by the surface (`GhosttySurfaceView.liveFontSize`) and is intentionally
/// NOT persisted across launches: a persisted zoom is what made a fresh launch
/// open with an oversized font. ``minimumSize``/``maximumSize`` bound the zoom.
public struct MobileTerminalFontPreference {
    private init() {}

    // SUPERMUX:begin ios-terminal-default-zoom
    /// Built-in point size used until the user explicitly saves another default.
    /// iOS and macOS use the same 12-point baseline; Retina scaling is applied
    /// separately through the surface content scale.
    public static let defaultSize: Float32 = 12
    // SUPERMUX:end ios-terminal-default-zoom
    /// Smallest size the zoom controls (and `cmux mobile set-font`) will reach.
    static let minimumSize: Float32 = 8
    /// Largest size the zoom controls will reach.
    static let maximumSize: Float32 = 28
}
#endif
