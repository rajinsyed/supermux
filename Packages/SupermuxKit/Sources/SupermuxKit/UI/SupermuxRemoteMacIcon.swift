public import SupermuxMobileCore
public import SwiftUI

/// The small "Mac + cloud" glyph that marks a row living on another Mac
/// (device mirrors, remote worktrees, remote-only projects): a laptop with a
/// cloud badge on its top-trailing corner. The Mac's name is only in the
/// tooltip and the VoiceOver label ("On <Mac>"), so the row keeps its width for
/// the title and branch. Dimmed while that Mac is offline or connecting.
///
/// No system symbol combines a Mac and a cloud, and a plain cloud would read
/// as upstream's Cloud VM badge, so the badge is composed here: a slightly
/// larger cloud punches the laptop out around it (`destinationOut` inside the
/// glyph's own compositing group), which keeps it legible on any row
/// background, selected or not.
///
/// ```swift
/// SupermuxRemoteMacIcon(device: device, pointSize: 9 * fontScale)
/// ```
public struct SupermuxRemoteMacIcon: View {
    /// The Mac glyph.
    public static let symbol = "laptopcomputer"
    /// The badge on its top-trailing corner.
    public static let badgeSymbol = "cloud.fill"

    private let help: String
    private let isDimmed: Bool
    private let pointSize: CGFloat
    private let tint: Color

    /// Creates the icon for a Mac known by name.
    /// - Parameters:
    ///   - name: The Mac's name, for the tooltip.
    ///   - state: Its link state (dimmed unless ``SupermuxDeviceChipState/online``).
    ///   - pointSize: The laptop glyph's point size; match the neighboring text.
    ///   - tint: The row's secondary color, so the icon follows a selected row.
    public init(name: String, state: SupermuxDeviceChipState, pointSize: CGFloat, tint: Color = .secondary) {
        self.help = Self.helpText(name: name, state: state)
        self.isDimmed = state.isDimmed
        self.pointSize = pointSize
        self.tint = tint
    }

    /// Creates the icon for a project device.
    public init(device: SupermuxProjectDevice, pointSize: CGFloat, tint: Color = .secondary) {
        self.init(name: device.name, state: Self.state(of: device), pointSize: pointSize, tint: tint)
    }

    /// The tooltip and VoiceOver label: "On <Mac>", plus the link state when
    /// that Mac is not reachable.
    public static func helpText(name: String, state: SupermuxDeviceChipState) -> String {
        switch state {
        case .online:
            return String(localized: "supermux.devices.chip.online", defaultValue: "On \(name)")
        case .connecting:
            return String(localized: "supermux.devices.chip.connecting", defaultValue: "On \(name) — Connecting…")
        case .offline:
            return String(localized: "supermux.devices.chip.offline", defaultValue: "On \(name) — Offline")
        }
    }

    /// The tooltip and VoiceOver label with the link's route: "On <Mac> —
    /// Relay · Tokyo · 241 ms" while connected with one, else as
    /// ``helpText(name:state:)``.
    public static func helpText(name: String, state: SupermuxDeviceChipState, route: SupermuxLinkRoute?) -> String {
        helpText(name: name, state: state)
    }

    /// Whether the icon carries the amber dot: only while a connected Mac's
    /// link goes through a relay.
    public static func showsRelayDot(state: SupermuxDeviceChipState, route: SupermuxLinkRoute?) -> Bool {
        false
    }

    /// The link state a project device's icon shows.
    public static func state(of device: SupermuxProjectDevice) -> SupermuxDeviceChipState {
        device.isOnline ? .online : .offline
    }

    public var body: some View {
        let badgeSize = pointSize * 0.55
        ZStack(alignment: .topTrailing) {
            Image(systemName: Self.symbol)
                .font(.system(size: pointSize))
                // Room for the badge over the screen's corner, so it never
                // overlaps the next view.
                .padding(.top, badgeSize * 0.3)
                .padding(.trailing, badgeSize * 0.45)
            ZStack {
                // The cutout: a gap of background around the badge.
                Image(systemName: Self.badgeSymbol)
                    .font(.system(size: badgeSize * 1.4))
                    .blendMode(.destinationOut)
                Image(systemName: Self.badgeSymbol)
                    .font(.system(size: badgeSize))
            }
        }
        .foregroundStyle(tint)
        .compositingGroup()
        .opacity(isDimmed ? 0.45 : 1)
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}
