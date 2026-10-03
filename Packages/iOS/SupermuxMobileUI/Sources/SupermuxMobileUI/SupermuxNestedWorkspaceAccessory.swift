public import SwiftUI

/// What a workspace row nested under a project adds to the shell's own row,
/// as the Mac sidebar's nested row shows it: the branch line right under the
/// title — the small cloud-Mac icon first when the workspace lives on
/// another Mac than the list's home Mac — and, at the end of the preview
/// line, the PR badge and the run indicator.
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

    /// The accessory, or `nil` when it would draw nothing.
    init?(
        workspaceID: String,
        remoteMac: SupermuxRemoteMac?,
        branch: String?,
        pullRequest: SupermuxPullRequestBadgeSnapshot?,
        isRunning: Bool
    ) {
        guard remoteMac != nil || branch != nil || pullRequest != nil || isRunning else { return nil }
        self.workspaceID = workspaceID
        self.remoteMac = remoteMac
        self.branch = branch
        self.pullRequest = pullRequest
        self.isRunning = isRunning
    }

    /// Whether the row draws the branch line under its title.
    public var hasBranchLine: Bool { remoteMac != nil || branch != nil }

    /// Whether the row draws the PR badge or run indicator.
    var hasStatus: Bool { pullRequest != nil || isRunning }

    /// How many lines the shell row's preview text keeps under a branch
    /// line: one fewer than the "Preview Lines" setting, never none, so the
    /// row stays about as tall as its neighbors.
    /// - Parameter previewLineLimit: The setting (1 or 2).
    public func previewLineLimit(_ previewLineLimit: Int) -> Int {
        hasBranchLine ? max(1, previewLineLimit - 1) : previewLineLimit
    }
}

extension EnvironmentValues {
    /// The accessory of the nested workspace row being drawn, so the shell
    /// row can leave room for its branch line (``SupermuxNestedBranchSlot``).
    /// `nil` for every other row.
    @Entry public var supermuxNestedRowAccessory: SupermuxNestedWorkspaceAccessory? = nil
}

/// The bounds of the shell row's preview-line text: where a nested row's
/// status (PR badge, run indicator) ends, so it never covers what follows
/// the text on that line.
private struct SupermuxNestedAccessorySlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The bounds of the room the shell row leaves under its title for a
/// nested row's branch line.
private struct SupermuxNestedBranchSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// How far from the row's trailing edge the accessory stays, clear of the
/// activity dot drawn there.
private let supermuxNestedAccessoryDotClearance: CGFloat = 20

/// The widest the status gets, so it never covers most of the preview line.
private let supermuxNestedAccessoryMaxWidth: CGFloat = 200

/// The room the shell row leaves right under its title for a nested row's
/// branch line: the line itself, laid out but not drawn. The visible line is
/// drawn over it by ``View/supermuxNestedWorkspaceAccessory(_:)``, outside
/// the row's combined accessibility element, so VoiceOver reads it as its
/// own element ("On <Mac>, <branch>").
public struct SupermuxNestedBranchSlot: View {
    let accessory: SupermuxNestedWorkspaceAccessory

    /// Creates the slot.
    /// - Parameter accessory: The nested row's accessory.
    public init(accessory: SupermuxNestedWorkspaceAccessory) {
        self.accessory = accessory
    }

    public var body: some View {
        SupermuxNestedBranchLine(accessory: accessory)
            .hidden()
            .padding(.trailing, supermuxNestedAccessoryDotClearance)
            .anchorPreference(key: SupermuxNestedBranchSlotKey.self, value: .bounds) { $0 }
    }
}

extension View {
    /// Marks the shell row's preview-line text as the status slot. The text
    /// fills the space before the changes chip (the chip's own spacer keeps
    /// its 8pt gap), so the slot ends right where the chip begins, or at the
    /// row's end without one. Layout-neutral: the text stays leading.
    public func supermuxNestedAccessorySlot() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .anchorPreference(key: SupermuxNestedAccessorySlotKey.self, value: .bounds) { $0 }
    }

    /// Hands a nested workspace row its accessory and draws it: the branch
    /// line in the room the row left under its title
    /// (``SupermuxNestedBranchSlot``), and the PR badge and run indicator at
    /// the trailing end of the preview line's slot
    /// (``supermuxNestedAccessorySlot()``), before the changes chip and clear
    /// of the activity dot. Overlays, each its own accessibility element.
    /// - Parameter accessory: The row's accessory; `nil` draws nothing.
    public func supermuxNestedWorkspaceAccessory(_ accessory: SupermuxNestedWorkspaceAccessory?) -> some View {
        environment(\.supermuxNestedRowAccessory, accessory)
            .overlayPreferenceValue(SupermuxNestedBranchSlotKey.self) { slot in
                if let accessory, accessory.hasBranchLine, let slot {
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
            .overlayPreferenceValue(SupermuxNestedAccessorySlotKey.self) { slot in
                if let accessory, accessory.hasStatus, let slot {
                    GeometryReader { proxy in
                        let frame = proxy[slot]
                        // A slot that runs to the row's end (no changes chip)
                        // keeps the status clear of the activity dot there.
                        let dotClearance = max(0, supermuxNestedAccessoryDotClearance - (proxy.size.width - frame.maxX))
                        SupermuxNestedWorkspaceStatusView(accessory: accessory)
                            .frame(maxWidth: supermuxNestedAccessoryMaxWidth, alignment: .trailing)
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

/// A nested row's branch line, as the Mac sidebar draws it under a nested
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

/// A nested row's PR badge and run indicator, on a capsule of the row's
/// background so they read over the preview text they sit on.
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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.background, in: Capsule(style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SupermuxNestedWorkspaceStatus-\(accessory.workspaceID)")
    }
}
