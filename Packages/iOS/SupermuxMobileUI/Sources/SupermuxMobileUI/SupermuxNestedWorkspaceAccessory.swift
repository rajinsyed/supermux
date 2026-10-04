public import SwiftUI

/// What a workspace row nested under a project shows in place of the shell
/// row's description and preview, as the Mac sidebar's nested row shows it:
/// one line right under the title with the branch — the small cloud-Mac icon
/// first when the workspace lives on another Mac than the list's home Mac —
/// and, at its trailing end, the PR badge and the run indicator.
public struct SupermuxNestedWorkspaceAccessory: Equatable, Sendable {
    /// The workspace's row id.
    public let workspaceID: String
    /// The Mac the workspace lives on, unless it is the list's home Mac.
    public let remoteMac: SupermuxRemoteMac?
    /// The workspace's branch, if the Mac reported one.
    public let branch: String?
    /// The branch's PR badge, if any.
    public let pullRequest: SupermuxPullRequestBadgeSnapshot?
    /// Whether the project's run command runs in this workspace.
    public let isRunning: Bool

    /// The accessory of one nested row. Every nested row gets one, even when
    /// it has nothing to show, because it is also what drops the row's
    /// preview.
    init(
        workspaceID: String,
        remoteMac: SupermuxRemoteMac?,
        branch: String?,
        pullRequest: SupermuxPullRequestBadgeSnapshot?,
        isRunning: Bool
    ) {
        self.workspaceID = workspaceID
        self.remoteMac = remoteMac
        self.branch = branch
        self.pullRequest = pullRequest
        self.isRunning = isRunning
    }

    /// Whether the row draws the line under its title.
    public var hasBranchLine: Bool { showsBranch || hasStatus }

    /// Whether the line shows the branch (or the cloud-Mac icon).
    var showsBranch: Bool { remoteMac != nil || branch != nil }

    /// Whether the line shows the PR badge or run indicator.
    var hasStatus: Bool { pullRequest != nil || isRunning }
}

extension EnvironmentValues {
    /// The accessory of the nested workspace row being drawn, so the shell
    /// row draws its branch line (``SupermuxNestedBranchSlot``) instead of its
    /// preview. `nil` for every other row.
    @Entry public var supermuxNestedRowAccessory: SupermuxNestedWorkspaceAccessory? = nil
}

/// The bounds of the room the shell row leaves for a nested row's branch.
private struct SupermuxNestedBranchSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The bounds of the room the shell row leaves for a nested row's status.
private struct SupermuxNestedStatusSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// How far from the row's trailing edge the line stays, clear of the
/// activity dot drawn there.
private let supermuxNestedAccessoryDotClearance: CGFloat = 20

/// The room the shell row leaves right under its title for a nested row's
/// line: the branch and the status, laid out but not drawn. The visible
/// parts are drawn over it by ``View/supermuxNestedWorkspaceAccessory(_:)``,
/// outside the row's combined accessibility element, so VoiceOver reads
/// each as its own element ("On <Mac>, <branch>").
public struct SupermuxNestedBranchSlot: View {
    let accessory: SupermuxNestedWorkspaceAccessory

    /// Creates the slot.
    /// - Parameter accessory: The nested row's accessory.
    public init(accessory: SupermuxNestedWorkspaceAccessory) {
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 6) {
            SupermuxNestedBranchLine(accessory: accessory)
                .hidden()
                .anchorPreference(key: SupermuxNestedBranchSlotKey.self, value: .bounds) { $0 }
            Spacer(minLength: 0)
            if accessory.hasStatus {
                SupermuxNestedWorkspaceStatusView(accessory: accessory)
                    .hidden()
                    .anchorPreference(key: SupermuxNestedStatusSlotKey.self, value: .bounds) { $0 }
            }
        }
        .padding(.trailing, supermuxNestedAccessoryDotClearance)
    }
}

extension View {
    /// Hands a nested workspace row its accessory and draws it in the room
    /// the row left under its title (``SupermuxNestedBranchSlot``): the
    /// branch at the leading edge, the PR badge and run indicator at the
    /// trailing end, clear of the activity dot. Overlays, each its own
    /// accessibility element.
    /// - Parameter accessory: The row's accessory; `nil` draws nothing.
    public func supermuxNestedWorkspaceAccessory(_ accessory: SupermuxNestedWorkspaceAccessory?) -> some View {
        environment(\.supermuxNestedRowAccessory, accessory)
            .overlayPreferenceValue(SupermuxNestedBranchSlotKey.self) { slot in
                if let accessory, accessory.showsBranch, let slot {
                    GeometryReader { proxy in
                        let frame = proxy[slot]
                        // Padding, not an offset, so the accessibility frame
                        // follows the drawn one.
                        SupermuxNestedBranchLine(accessory: accessory)
                            .frame(width: frame.width, height: frame.height, alignment: .leading)
                            .padding(.leading, frame.minX)
                            .padding(.top, frame.minY)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("SupermuxNestedWorkspaceAccessory-\(accessory.workspaceID)")
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlayPreferenceValue(SupermuxNestedStatusSlotKey.self) { slot in
                if let accessory, accessory.hasStatus, let slot {
                    GeometryReader { proxy in
                        let frame = proxy[slot]
                        SupermuxNestedWorkspaceStatusView(accessory: accessory)
                            .frame(width: frame.width, height: frame.height)
                            .padding(.leading, frame.minX)
                            .padding(.top, frame.minY)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("SupermuxNestedWorkspaceStatus-\(accessory.workspaceID)")
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// A nested row's branch, as the Mac sidebar draws it under a nested
/// workspace's title: the cloud-Mac icon when the workspace lives on another
/// Mac than the list's home Mac, then the branch in a monospaced caption.
private struct SupermuxNestedBranchLine: View {
    let accessory: SupermuxNestedWorkspaceAccessory

    var body: some View {
        HStack(spacing: 3) {
            // The Mac it lives on, right before its branch, as on the Mac
            // (the name is only the icon's VoiceOver label).
            if let remoteMac = accessory.remoteMac {
                SupermuxMobileRemoteMacIcon(mac: remoteMac, pointSize: 10, relativeTo: .caption)
            }
            // A line without a branch (a Mac that reported none) keeps the
            // caption's height, so every branch line measures the same.
            Text(accessory.branch ?? " ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(accessory.branch == nil)
        }
    }
}

/// A nested row's PR badge and run indicator, after its branch as on the Mac.
private struct SupermuxNestedWorkspaceStatusView: View {
    let accessory: SupermuxNestedWorkspaceAccessory

    var body: some View {
        HStack(spacing: 6) {
            if let pullRequest = accessory.pullRequest {
                SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
            }
            if accessory.isRunning {
                SupermuxMobileRunIndicator()
            }
        }
        .fixedSize()
    }
}
