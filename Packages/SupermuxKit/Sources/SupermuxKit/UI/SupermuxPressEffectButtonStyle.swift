public import SwiftUI

/// Gentle press feedback for the usage popover's small plain-style controls:
/// a slight shrink and dim while pressed, springing back on release.
///
/// Hover-revealed styling is deliberately avoided here — NSPopover-hosted
/// SwiftUI hover regions track with a vertical offset — but press tracking
/// is reliable, so this is where the tactile feedback lives.
public struct SupermuxPressEffectButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
