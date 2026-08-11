import Foundation

/// Geometry and glow values for the mobile unread-pane ring.
public struct SupermuxMobileUnreadPaneRingStyle: Equatable, Sendable {
    /// The ring style matching the existing macOS pane notification ring.
    public static let macOSParity = Self(
        inset: 2,
        cornerRadius: 6,
        lineWidth: 2.5,
        glowOpacity: 0.35,
        glowRadius: 3
    )

    /// Distance between the pane edge and the ring.
    public let inset: Double
    /// Radius of the ring's rounded corners.
    public let cornerRadius: Double
    /// Width of the ring stroke.
    public let lineWidth: Double
    /// Opacity of the blue glow behind the stroke.
    public let glowOpacity: Double
    /// Blur radius of the glow behind the stroke.
    public let glowRadius: Double

    private init(
        inset: Double,
        cornerRadius: Double,
        lineWidth: Double,
        glowOpacity: Double,
        glowRadius: Double
    ) {
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        self.glowOpacity = glowOpacity
        self.glowRadius = glowRadius
    }
}
