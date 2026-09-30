public import SwiftUI

/// A compact "which Mac" chip (`desktopcomputer` + the Mac's name) for rows
/// that live on another Mac: device mirrors, remote-only projects and remote
/// worktrees. Dimmed, with an "Offline" (or "Connecting…") tooltip, while the
/// Mac is unreachable. The tooltip always carries the full name.
///
/// The chip shows the whole name when the row has room and truncates only
/// when it does not: it competes for width at layout priority 1, so a row
/// gives its title the same priority (neither can crowd the other out, and a
/// spacer never takes width the name needs).
public struct SupermuxDeviceChip: View {
    private let name: String
    private let state: SupermuxDeviceChipState
    private let fontScale: CGFloat

    /// Creates a chip.
    /// - Parameters:
    ///   - name: The Mac's name.
    ///   - isOnline: Whether its link is live.
    ///   - fontScale: Sidebar font scale (`1` at the default size).
    public init(name: String, isOnline: Bool, fontScale: CGFloat = 1) {
        self.init(name: name, state: isOnline ? .online : .offline, fontScale: fontScale)
    }

    /// Creates a chip for a Mac whose link may be dialing.
    /// - Parameters:
    ///   - name: The Mac's name.
    ///   - state: Its link state (dimmed unless ``SupermuxDeviceChipState/online``).
    ///   - fontScale: Sidebar font scale (`1` at the default size).
    public init(name: String, state: SupermuxDeviceChipState, fontScale: CGFloat = 1) {
        self.name = name
        self.state = state
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
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5 * fontScale)
        .frame(height: 15 * fontScale)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .opacity(state.isDimmed ? 0.45 : 1)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
        .layoutPriority(1)
    }

    private var helpText: String {
        switch state {
        case .online:
            return String(localized: "supermux.devices.chip.online", defaultValue: "On \(name)")
        case .connecting:
            return String(localized: "supermux.devices.chip.connecting", defaultValue: "On \(name) — Connecting…")
        case .offline:
            return String(localized: "supermux.devices.chip.offline", defaultValue: "On \(name) — Offline")
        }
    }
}
