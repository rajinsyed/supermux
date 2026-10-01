public import SwiftUI

/// What a workspace row nested under a project adds to the shell's own row:
/// the PR badge, the run indicator and — only when the project spans several
/// Macs — the Mac it lives on. The Mac sidebar's nested row shows the same.
public struct SupermuxNestedWorkspaceAccessory: Equatable, Sendable {
    /// The workspace's row id.
    public let workspaceID: String
    /// The owning Mac's name, when the project spans several Macs.
    public let macName: String?
    /// The branch's PR badge, if any.
    public let pullRequest: SupermuxPullRequestBadgeSnapshot?
    /// Whether the project's run command runs in this workspace.
    public let isRunning: Bool

    /// The accessory, or `nil` when it would draw nothing.
    init?(
        workspaceID: String,
        macName: String?,
        pullRequest: SupermuxPullRequestBadgeSnapshot?,
        isRunning: Bool
    ) {
        guard macName != nil || pullRequest != nil || isRunning else { return nil }
        self.workspaceID = workspaceID
        self.macName = macName
        self.pullRequest = pullRequest
        self.isRunning = isRunning
    }
}

/// The bounds of the shell row's preview-line text: where a nested row's
/// accessory ends, so it never covers what follows the text on that line.
private struct SupermuxNestedAccessorySlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// How far from the row's trailing edge the accessory stays, clear of the
/// activity dot drawn there.
private let supermuxNestedAccessoryDotClearance: CGFloat = 20

extension View {
    /// Marks the shell row's preview-line text as the accessory's slot. The
    /// text fills the space before the changes chip (the chip's own spacer
    /// keeps its 8pt gap), so the slot ends right where the chip begins, or
    /// at the row's end without one. Layout-neutral: the text stays leading.
    public func supermuxNestedAccessorySlot() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .anchorPreference(key: SupermuxNestedAccessorySlotKey.self, value: .bounds) { $0 }
    }

    /// Overlays a nested workspace row with its accessory at the trailing end
    /// of the preview line's slot (``supermuxNestedAccessorySlot()``), so it
    /// sits before the changes chip instead of on it, and clear of the
    /// activity dot. An overlay, so it is height-neutral: the row measures
    /// exactly like any other workspace row.
    /// - Parameter accessory: The row's accessory; `nil` overlays nothing.
    public func supermuxNestedWorkspaceAccessory(_ accessory: SupermuxNestedWorkspaceAccessory?) -> some View {
        overlayPreferenceValue(SupermuxNestedAccessorySlotKey.self) { slot in
            if let accessory, let slot {
                GeometryReader { proxy in
                    let frame = proxy[slot]
                    // A slot that runs to the row's end (no changes chip)
                    // keeps the accessory clear of the activity dot there.
                    let dotClearance = max(0, supermuxNestedAccessoryDotClearance - (proxy.size.width - frame.maxX))
                    // Padding, not an offset, so the accessibility frame
                    // follows the drawn one.
                    SupermuxNestedWorkspaceAccessoryView(accessory: accessory)
                        .padding(.trailing, dotClearance)
                        .padding(.bottom, 2)
                        .frame(width: frame.width, height: frame.height, alignment: .bottomTrailing)
                        .padding(.leading, frame.minX)
                        .padding(.top, frame.minY)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct SupermuxNestedWorkspaceAccessoryView: View {
    let accessory: SupermuxNestedWorkspaceAccessory

    var body: some View {
        HStack(spacing: 6) {
            if let macName = accessory.macName {
                SupermuxNestedMacMarker(name: macName)
            }
            if let pullRequest = accessory.pullRequest {
                SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
            }
            if accessory.isRunning {
                SupermuxMobileRunIndicator()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.background, in: Capsule(style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SupermuxNestedWorkspaceAccessory-\(accessory.workspaceID)")
    }
}

/// A small "on this Mac" marker for rows of a project that spans several
/// Macs — the phone twin of the Mac sidebar's device icon on a mirror row.
struct SupermuxNestedMacMarker: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "laptopcomputer")
                .font(.system(.caption2))
                .accessibilityHidden(true)
            Text(name)
                .font(.system(.caption2))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 120, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
}
