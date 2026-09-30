public import SwiftUI

/// A one-line "On <Mac>" strip above a panel whose content lives on another
/// Mac (a device mirror's Changes panel), so it is never mistaken for this
/// Mac's repository.
public struct SupermuxRemoteHostBanner: View {
    private let title: String
    private let isConnected: Bool

    /// Creates the banner.
    /// - Parameters:
    ///   - title: The localized line, e.g. "On Studio Mac".
    ///   - isConnected: Whether that Mac is reachable (dims the strip when not).
    public init(title: String, isConnected: Bool) {
        self.title = title
        self.isConnected = isConnected
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isConnected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .opacity(isConnected ? 1 : 0.6)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}
