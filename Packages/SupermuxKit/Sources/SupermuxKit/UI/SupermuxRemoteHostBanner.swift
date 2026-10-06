import SupermuxMobileCore
public import SwiftUI

/// A one-line "On <Mac>" strip above a panel whose content lives on another
/// Mac (a device mirror's Changes panel), so it is never mistaken for this
/// Mac's repository. While that Mac is connected it also says which path the
/// link uses ("Relay · Tokyo · 241 ms", amber while relayed), looked up by
/// `machineID` in ``EnvironmentValues/supermuxLinkRoutes``: at the strip's
/// trailing end when both fit, else on a second line (the right sidebar is
/// often narrower than a Mac's name and its route together).
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
        Group {
            if let route {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        icon
                        titleText.fixedSize()
                        Spacer(minLength: 8)
                        routeText(route).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            icon
                            titleText
                            Spacer(minLength: 0)
                        }
                        routeText(route)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    icon
                    titleText
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(.secondary)
        .opacity(isConnected ? 1 : 0.6)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: isConnected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
            .font(.system(size: 11, weight: .medium))
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func routeText(_ route: SupermuxLinkRoute) -> some View {
        Text(SupermuxLinkRouteText.text(for: route))
            .font(.system(size: 10))
            .foregroundStyle(SupermuxLinkRouteText.isWarning(route) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
    }
}
