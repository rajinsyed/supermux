public import SwiftUI

/// A one-line "On <Mac>" strip above a panel whose content lives on another
/// Mac (a device mirror's Changes panel), so it is never mistaken for this
/// Mac's repository. While that Mac is connected its trailing end says which
/// path the link uses ("Relay · Tokyo · 241 ms", amber while relayed), looked
/// up by `machineID` in ``EnvironmentValues/supermuxLinkRoutes``.
public struct SupermuxRemoteHostBanner: View {
    private let title: String
    private let isConnected: Bool
    private let machineID: String?

    @Environment(\.supermuxLinkRoutes) private var routes

    /// Creates the banner.
    /// - Parameters:
    ///   - title: The localized line, e.g. "On Studio Mac".
    ///   - isConnected: Whether that Mac is reachable (dims the strip when not).
    ///   - machineID: That Mac's catalog machine id, for its route; nil shows none.
    public init(title: String, isConnected: Bool, machineID: String? = nil) {
        self.title = title
        self.isConnected = isConnected
        self.machineID = machineID
    }

    public var body: some View {
        let route = isConnected ? machineID.flatMap { routes.route(forMachineID: $0) } : nil
        HStack(spacing: 6) {
            Image(systemName: isConnected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let route {
                Text(SupermuxLinkRouteText.text(for: route))
                    .font(.system(size: 10))
                    .foregroundStyle(SupermuxLinkRouteText.isWarning(route) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .foregroundStyle(.secondary)
        .opacity(isConnected ? 1 : 0.6)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}
