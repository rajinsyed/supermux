public import SwiftUI

/// A compact "which Mac" chip (`desktopcomputer` + the Mac's name) for rows
/// that live on another Mac: device mirrors, remote-only projects and remote
/// worktrees. Dimmed, with an "Offline" tooltip, while the Mac is unreachable.
public struct SupermuxDeviceChip: View {
    private let name: String
    private let isOnline: Bool
    private let fontScale: CGFloat

    /// Creates a chip.
    /// - Parameters:
    ///   - name: The Mac's name.
    ///   - isOnline: Whether its link is live.
    ///   - fontScale: Sidebar font scale (`1` at the default size).
    public init(name: String, isOnline: Bool, fontScale: CGFloat = 1) {
        self.name = name
        self.isOnline = isOnline
        self.fontScale = fontScale
    }

    /// Creates a chip for a project device.
    public init(device: SupermuxProjectDevice, fontScale: CGFloat = 1) {
        self.init(name: device.name, isOnline: device.isOnline, fontScale: fontScale)
    }

    public var body: some View {
        HStack(spacing: 3 * fontScale) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 7.5 * fontScale, weight: .semibold))
            Text(name)
                .font(.system(size: 9 * fontScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                // Compact: a long Mac name truncates instead of crowding the title.
                .frame(maxWidth: 64 * fontScale, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5 * fontScale)
        .frame(height: 15 * fontScale)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .opacity(isOnline ? 1 : 0.45)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        isOnline
            ? String(localized: "supermux.devices.chip.online", defaultValue: "On \(name)")
            : String(localized: "supermux.devices.chip.offline", defaultValue: "On \(name) — Offline")
    }
}
