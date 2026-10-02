public import SupermuxMobileKit
public import SwiftUI

/// The Mac a list row lives on, when that is not the list's home Mac: what
/// ``SupermuxMobileRemoteMacIcon`` draws and says.
public struct SupermuxRemoteMac: Equatable, Sendable {
    /// The Mac's user-facing name. Only VoiceOver says it; it is never drawn.
    public let name: String
    /// Its link's health: the icon dims unless the Mac is connected.
    public let status: SupermuxMacSeam.Status

    /// The Mac a project location lives on.
    init(mac: SupermuxProjectsMacHeader) {
        self.name = mac.displayName
        self.status = mac.status
    }

    /// The VoiceOver label, in the Mac sidebar's words: "On <Mac>", plus the
    /// link state while that Mac is not reachable.
    public var accessibilityLabel: String {
        switch status {
        case .connected:
            String(localized: "supermux.devices.chip.online", defaultValue: "On \(name)", bundle: .module)
        case .reconnecting:
            String(localized: "supermux.devices.chip.connecting", defaultValue: "On \(name) — Connecting…", bundle: .module)
        case .unavailable:
            String(localized: "supermux.devices.chip.offline", defaultValue: "On \(name) — Offline", bundle: .module)
        }
    }
}

/// The small "Mac + cloud" glyph before the branch of a row that lives on
/// another Mac than the list's home Mac — the phone twin of the Mac
/// sidebar's `SupermuxRemoteMacIcon`, composed the same way: a laptop with a
/// cloud badge on its top-trailing corner, a slightly larger cloud punching
/// the laptop out around it (`destinationOut` inside the glyph's own
/// compositing group). The Mac's name is only the VoiceOver label, so the
/// row keeps its width for the branch. Dimmed while that Mac is reconnecting
/// or offline.
///
/// The composed glyph is used as a mask over the secondary style rather than
/// tinted part by part: a translucent tint would only half-erase the laptop
/// under the badge.
struct SupermuxMobileRemoteMacIcon: View {
    private let mac: SupermuxRemoteMac
    @ScaledMetric private var pointSize: CGFloat

    /// Creates the icon.
    /// - Parameters:
    ///   - mac: The Mac the row lives on.
    ///   - pointSize: The laptop glyph's size at the default text size.
    ///   - textStyle: The neighboring text's style, which the size follows
    ///     under Dynamic Type.
    init(mac: SupermuxRemoteMac, pointSize: CGFloat, relativeTo textStyle: Font.TextStyle) {
        self.mac = mac
        _pointSize = ScaledMetric(wrappedValue: pointSize, relativeTo: textStyle)
    }

    var body: some View {
        glyph
            .hidden()
            .overlay {
                Rectangle()
                    .fill(.secondary)
                    .mask { glyph }
            }
            .opacity(mac.status == .connected ? 1 : 0.45)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mac.accessibilityLabel)
    }

    private var glyph: some View {
        let badgeSize = pointSize * 0.55
        return ZStack(alignment: .topTrailing) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: pointSize))
                // Room for the badge over the screen's corner, so it never
                // overlaps the next view.
                .padding(.top, badgeSize * 0.3)
                .padding(.trailing, badgeSize * 0.45)
            ZStack {
                // The cutout: a gap of background around the badge.
                Image(systemName: "cloud.fill")
                    .font(.system(size: badgeSize * 1.4))
                    .blendMode(.destinationOut)
                Image(systemName: "cloud.fill")
                    .font(.system(size: badgeSize))
            }
        }
        .compositingGroup()
    }
}
