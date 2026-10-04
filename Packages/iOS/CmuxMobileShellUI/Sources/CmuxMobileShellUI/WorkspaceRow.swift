import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
// SUPERMUX:begin supermux-mobile-nested-accessory (the nested row's accessory slot — see SUPERMUX-TOUCHPOINTS.md)
import SupermuxMobileUI
// SUPERMUX:end supermux-mobile-nested-accessory
import SwiftUI

/// Everything a workspace row draws, and nothing else.
///
/// ``WorkspaceRow`` reads only this value, so two equal contents render the
/// same pixels. The workspace table compares contents to decide whether a
/// relay update touches a row: fields the row never draws (surfaces,
/// simulators, directories) and sub-minute activity restamps cannot wake it.
struct WorkspaceRowContent: Equatable {
    let rpcWorkspaceID: String
    let name: String
    let isPinned: Bool
    let unreadState: MobileWorkspaceUnreadState
    let accentColorHex: String?
    /// The trailing label: a connection problem, or the activity time at the
    /// minute precision the row shows.
    let timestampText: String
    let description: String?
    let previewLine: String
    let changesChip: MobileWorkspaceChangesChip?
    /// Whether the changes chip is a button rather than a passive label.
    let opensChanges: Bool
    let isSelected: Bool
    let wrapWorkspaceTitles: Bool
    let previewLineLimit: Int
    let unreadIndicatorLeftShift: Double
    let unreadBadgeDiameter: Double

    init(
        workspace: MobileWorkspacePreview,
        connectionStatus: MobileMacConnectionStatus,
        isSelected: Bool,
        changesChip: MobileWorkspaceChangesChip?,
        opensChanges: Bool,
        wrapWorkspaceTitles: Bool,
        previewLineLimit: Int,
        unreadIndicatorLeftShift: Double,
        unreadBadgeDiameter: Double
    ) {
        let visibleChip = (changesChip?.filesChanged ?? 0) > 0 ? changesChip : nil
        rpcWorkspaceID = workspace.rpcWorkspaceID.rawValue
        name = workspace.name
        isPinned = workspace.isPinned
        unreadState = workspace.unreadState
        accentColorHex = workspace.customColorHex
        timestampText = workspace.timestampOrStatus(connectionStatus: connectionStatus)
        description = workspace.displayDescription
        previewLine = workspace.previewLine
        self.changesChip = visibleChip
        self.opensChanges = opensChanges && visibleChip != nil
        self.isSelected = isSelected
        self.wrapWorkspaceTitles = wrapWorkspaceTitles
        self.previewLineLimit = previewLineLimit
        self.unreadIndicatorLeftShift = unreadIndicatorLeftShift
        self.unreadBadgeDiameter = unreadBadgeDiameter
    }
}

struct WorkspaceRow: View {
    /// Daylight between the unread badge's trailing edge and the color rail.
    /// Internal (not private) so layout tests can assert the reservation math
    /// against the shipped constant.
    static let unreadDotRailVisualGap: CGFloat = 8
    private static let railTextVisualGap: CGFloat = 10
    private static let railVerticalInset: CGFloat = 5

    let content: WorkspaceRowContent
    /// Opens this workspace's changes without selecting the row. Ignored unless
    /// ``WorkspaceRowContent/opensChanges`` is set.
    let onOpenChanges: (@MainActor () -> Void)?
    // SUPERMUX:begin supermux-mobile-nested-branch-line (a nested row's accessory, set by the table's #701 modifier)
    @Environment(\.supermuxNestedRowAccessory) private var supermuxNestedRowAccessory
    // SUPERMUX:end supermux-mobile-nested-branch-line

    init(content: WorkspaceRowContent, onOpenChanges: (@MainActor () -> Void)? = nil) {
        self.content = content
        self.onOpenChanges = onOpenChanges
    }

    /// `previewLineLimit` is the "Preview Lines" setting (1 or 2). Space is
    /// reserved so rows with short previews keep their neighbors' height.
    init(
        workspace: MobileWorkspacePreview,
        connectionStatus: MobileMacConnectionStatus,
        isSelected: Bool,
        changesChip: MobileWorkspaceChangesChip? = nil,
        onOpenChanges: (@MainActor () -> Void)? = nil,
        wrapWorkspaceTitles: Bool,
        previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount,
        unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        unreadBadgeDiameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.init(
            content: WorkspaceRowContent(
                workspace: workspace,
                connectionStatus: connectionStatus,
                isSelected: isSelected,
                changesChip: changesChip,
                opensChanges: onOpenChanges != nil,
                wrapWorkspaceTitles: wrapWorkspaceTitles,
                previewLineLimit: previewLineLimit,
                unreadIndicatorLeftShift: unreadIndicatorLeftShift,
                unreadBadgeDiameter: unreadBadgeDiameter
            ),
            onOpenChanges: onOpenChanges
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // SUPERMUX:begin supermux-mobile-unread-badge (upstream reserved a
            // fixed unread gutter here — see SUPERMUX-TOUCHPOINTS.md)
            // The unread badge now sits inline with the title instead of in a
            // reserved left column. Upstream's gutter kept every row's text
            // indented past an empty slot most rows never filled, which is the
            // blank space that showed up on global workspace rows.
            // SUPERMUX:end supermux-mobile-unread-badge

            Color.clear
                .frame(width: WorkspaceColorRail.width)

            Spacer()
                .frame(width: Self.railTextVisualGap)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if content.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(content.name)
                        .font(.headline)
                        .foregroundStyle(content.isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(content.wrapWorkspaceTitles ? nil : 1)

                    // SUPERMUX:begin supermux-mobile-unread-badge
                    // Trails the name, the way Mail and Messages badge a row:
                    // it reads as belonging to this workspace rather than to
                    // the column of dots it used to sit in.
                    WorkspaceUnreadDot(unread: content.unreadState)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    // SUPERMUX:end supermux-mobile-unread-badge

                    Spacer(minLength: 8)

                    // SUPERMUX:begin supermux-mobile-nested-branch-line (a nested row shows no time, as on the Mac sidebar)
                    if supermuxNestedRowAccessory == nil {
                    // SUPERMUX:end supermux-mobile-nested-branch-line
                    Text(content.timestampText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // SUPERMUX:begin supermux-mobile-nested-branch-line
                    }
                    // SUPERMUX:end supermux-mobile-nested-branch-line
                }

                // SUPERMUX:begin supermux-mobile-nested-branch-line (a nested row ends at its branch line, as on the Mac sidebar: no description or preview under it)
                if let supermuxNestedRowAccessory {
                    if supermuxNestedRowAccessory.hasBranchLine {
                        SupermuxNestedBranchSlot(accessory: supermuxNestedRowAccessory)
                    }
                } else {
                // SUPERMUX:end supermux-mobile-nested-branch-line

                if let description = content.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(content.previewLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(content.previewLineLimit, reservesSpace: true)

                    if let changesChip = content.changesChip {
                        Spacer(minLength: 8)
                        changesChipView(changesChip)
                    }
                }
                // SUPERMUX:begin supermux-mobile-nested-branch-line
                }
                // SUPERMUX:end supermux-mobile-nested-branch-line
            }

            // SUPERMUX:begin supermux-mobile-nested-branch-line (a nested row's status and changes chip, centered on its trailing edge as on the Mac sidebar)
            if let supermuxNestedRowAccessory {
                supermuxNestedTrailing(supermuxNestedRowAccessory)
            }
            // SUPERMUX:end supermux-mobile-nested-branch-line
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: railLeadingOffset)

                WorkspaceColorRail(color: content.accentColorHex.flatMap { Color(hexString: $0) })
                    .padding(.vertical, Self.railVerticalInset)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, content.isSelected ? 10 : 0)
        .background {
            if content.isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }

    // SUPERMUX:begin supermux-mobile-nested-branch-line
    /// A nested row's trailing edge, beside both its lines: the PR badge and
    /// run indicator, then the changes chip, clear of the activity dot.
    private func supermuxNestedTrailing(_ accessory: SupermuxNestedWorkspaceAccessory) -> some View {
        HStack(spacing: 8) {
            SupermuxNestedStatusSlot(accessory: accessory)
            if let changesChip = content.changesChip {
                changesChipView(changesChip)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, SupermuxNestedStatusSlot.dotClearance)
    }
    // SUPERMUX:end supermux-mobile-nested-branch-line

    @ViewBuilder
    private func changesChipView(_ chip: MobileWorkspaceChangesChip) -> some View {
        if content.opensChanges, let onOpenChanges {
            Button(action: onOpenChanges) {
                WorkspaceChangesChipLabel(
                    chip: chip,
                    workspaceID: content.rpcWorkspaceID
                )
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        } else {
            WorkspaceChangesChipLabel(
                chip: chip,
                workspaceID: content.rpcWorkspaceID
            )
        }
    }

    private var unreadDotRailLayoutGap: CGFloat {
        // Reserving the badge's gutter overflow keeps the visual gap promise
        // for badge rows and one uniform rail column for every row.
        WorkspaceUnreadDot.layoutGap(
            afterGutterForDiameter: content.unreadBadgeDiameter,
            leftShift: content.unreadIndicatorLeftShift,
            visualGap: Self.unreadDotRailVisualGap
        )
    }

    // SUPERMUX:begin supermux-mobile-unread-badge
    /// The color rail now starts at the row's own leading edge: with the unread
    /// gutter gone there is nothing to offset past. (upstream: gutter width
    /// plus a dot-derived gap.)
    private var railLeadingOffset: CGFloat { 0 }
    // SUPERMUX:end supermux-mobile-unread-badge
}

struct WorkspaceColorRail: View {
    static let width: CGFloat = 3
    private static let cornerRadius: CGFloat = 1.5

    let color: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(color ?? Color.clear)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .opacity(color == nil ? 0 : 0.95)
            .accessibilityHidden(true)
    }
}
