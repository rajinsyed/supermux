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

extension View {
    /// Overlays a nested workspace row with its accessory, bottom-trailing on
    /// the preview line and clear of the activity dot. An overlay, so it is
    /// height-neutral: the row measures exactly like any other workspace row.
    /// - Parameter accessory: The row's accessory; `nil` overlays nothing.
    public func supermuxNestedWorkspaceAccessory(_ accessory: SupermuxNestedWorkspaceAccessory?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let accessory {
                SupermuxNestedWorkspaceAccessoryView(accessory: accessory)
                    .padding(.trailing, 20)
                    .padding(.bottom, 10)
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
