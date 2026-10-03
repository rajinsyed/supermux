import SupermuxMobileKit
import SwiftUI

/// The label over one Mac's projects when several Macs have projects: the
/// Mac's color, its name, and — only when its link is not healthy — a short
/// status. Styled like a grouped-list section header (a quiet caption that
/// labels the rows below it), a notch below the section's own "PROJECTS".
struct SupermuxProjectsMacHeaderRow: View {
    let header: SupermuxProjectsMacHeader

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(SupermuxMacAccent.color(colorIndex: header.colorIndex, customColor: header.customColor))
                .accessibilityHidden(true)
            Text(header.displayName)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = statusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SupermuxProjectRowMetrics.rowHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("SupermuxProjectsMacHeader")
    }

    /// Shown only for an unhealthy link; a connected Mac needs no status.
    private var statusText: String? {
        switch header.status {
        case .connected:
            nil
        case .reconnecting:
            String(localized: "supermux.projects.mac.reconnecting", defaultValue: "Reconnecting…", bundle: .module)
        case .unavailable:
            String(localized: "supermux.projects.mac.offline", defaultValue: "Offline", bundle: .module)
        }
    }
}
