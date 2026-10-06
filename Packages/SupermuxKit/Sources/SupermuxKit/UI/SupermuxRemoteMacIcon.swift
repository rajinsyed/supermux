public import SupermuxMobileCore
public import SwiftUI

/// The small "Mac + cloud" glyph that marks a row living on another Mac
/// (device mirrors, remote worktrees, remote-only projects): a laptop with a
/// cloud badge on its top-trailing corner. The Mac's name is only in the
/// tooltip and the VoiceOver label ("On <Mac>"), so the row keeps its width for
/// the title and branch. Dimmed while that Mac is offline or connecting.
///
/// While that Mac is connected the tooltip also says which path its link
/// uses ("On <Mac> — Relay · Tokyo · 241 ms", ``SupermuxLinkRouteText``), and
/// a small amber dot sits on the glyph's bottom-trailing corner only while
/// the link goes through a relay, so a slow path shows without hovering and a
/// direct one stays quiet. The route is passed in, or looked up by the
/// device's machine id in ``EnvironmentValues/supermuxLinkRoutes``; reading
/// it here keeps route updates on this small view, never the row.
///
/// No system symbol combines a Mac and a cloud, and a plain cloud would read
/// as upstream's Cloud VM badge, so the badge is composed here: a slightly
/// larger cloud punches the laptop out around it (`destinationOut` inside the
/// glyph's own compositing group), which keeps it legible on any row
/// background, selected or not. The relay dot is cut out the same way.
///
/// ```swift
/// SupermuxRemoteMacIcon(device: device, pointSize: 9 * fontScale)
/// ```
public struct SupermuxRemoteMacIcon: View {
    /// The Mac glyph.
    public static let symbol = "laptopcomputer"
    /// The badge on its top-trailing corner.
    public static let badgeSymbol = "cloud.fill"

    private let name: String
    private let state: SupermuxDeviceChipState
    private let route: SupermuxLinkRoute?
    /// Set for a project device: its route comes from the environment.
    private let machineID: String?
    private let pointSize: CGFloat
    private let tint: Color

    @Environment(\.supermuxLinkRoutes) private var routes

    /// Creates the icon for a Mac known by name.
    /// - Parameters:
    ///   - name: The Mac's name, for the tooltip.
    ///   - state: Its link state (dimmed unless ``SupermuxDeviceChipState/online``).
    ///   - route: Its link's route while connected, for the tooltip and the relay dot.
    ///   - pointSize: The laptop glyph's point size; match the neighboring text.
    ///   - tint: The row's secondary color, so the icon follows a selected row.
    public init(
        name: String,
        state: SupermuxDeviceChipState,
        route: SupermuxLinkRoute? = nil,
        pointSize: CGFloat,
        tint: Color = .secondary
    ) {
        self.init(name: name, state: state, route: route, machineID: nil, pointSize: pointSize, tint: tint)
    }

    /// Creates the icon for a project device; its route comes from
    /// ``EnvironmentValues/supermuxLinkRoutes``.
    public init(device: SupermuxProjectDevice, pointSize: CGFloat, tint: Color = .secondary) {
        self.init(
            name: device.name, state: Self.state(of: device), route: nil,
            machineID: device.machineID, pointSize: pointSize, tint: tint
        )
    }

    private init(
        name: String,
        state: SupermuxDeviceChipState,
        route: SupermuxLinkRoute?,
        machineID: String?,
        pointSize: CGFloat,
        tint: Color
    ) {
        self.name = name
        self.state = state
        self.route = route
        self.machineID = machineID
        self.pointSize = pointSize
        self.tint = tint
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
    /// ``helpText(name:state:)`` (an unreachable Mac shows its status, never
    /// its last route).
    public static func helpText(name: String, state: SupermuxDeviceChipState, route: SupermuxLinkRoute?) -> String {
        guard state == .online, let route else { return helpText(name: name, state: state) }
        let text = SupermuxLinkRouteText.text(for: route)
        return String(localized: "supermux.devices.chip.route", defaultValue: "On \(name) — \(text)")
    }

    /// Whether the icon carries the amber dot: only while a connected Mac's
    /// link goes through a relay.
    public static func showsRelayDot(state: SupermuxDeviceChipState, route: SupermuxLinkRoute?) -> Bool {
        state == .online && route.map(SupermuxLinkRouteText.isWarning) == true
    }

    /// The link state a project device's icon shows.
    public static func state(of device: SupermuxProjectDevice) -> SupermuxDeviceChipState {
        device.isOnline ? .online : .offline
    }

    public var body: some View {
        let route = route ?? machineID.flatMap { routes.route(forMachineID: $0) }
        let help = Self.helpText(name: name, state: state, route: route)
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
        .overlay(alignment: .bottomTrailing) {
            if Self.showsRelayDot(state: state, route: route) {
                SupermuxRelayDot(diameter: pointSize * 0.42)
            }
        }
        .compositingGroup()
        .opacity(state.isDimmed ? 0.45 : 1)
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

/// The amber dot that marks a relayed link on a Mac glyph, with a cutout
/// ring of background around it (inside the glyph's compositing group) so it
/// reads on any row, selected or not.
struct SupermuxRelayDot: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .frame(width: diameter * 1.6, height: diameter * 1.6)
                .blendMode(.destinationOut)
            Circle()
                .fill(Color.orange)
                .frame(width: diameter, height: diameter)
        }
        .accessibilityHidden(true)
    }
}
