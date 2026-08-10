import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceRow: View {
    private static let railTextVisualGap: CGFloat = 10
    private static let railVerticalInset: CGFloat = 5

    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    /// The workspace's compact changes summary, when the connected Mac supports
    /// workspace changes and the repository is dirty. Rendered here
    /// (not in a wrapper) so every list pipeline that shows a workspace row
    /// (SwiftUI List and the UIKit table) carries the same signifier.
    var changesChip: MobileWorkspaceChangesChip? = nil
    /// Opens this workspace's changes without selecting the row. When absent,
    /// the changes capsule remains a passive label.
    var onOpenChanges: (@MainActor () -> Void)? = nil
    /// When `true`, the workspace title wraps onto multiple lines instead of
    /// truncating to one (driven by the "Wrap Workspace Titles" setting).
    let wrapWorkspaceTitles: Bool
    /// How many lines the activity preview shows (1 or 2, driven by the
    /// "Preview Lines" setting; 2 is the default). Space is reserved so rows
    /// with short previews keep the same height as their neighbors.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    // SUPERMUX:begin supermux-mobile-unread-badge
    /// Retained but INERT. This DEBUG-only developer slider nudged the unread
    /// dot leftward inside its reserved gutter; the gutter is gone and the
    /// badge is laid out inline, so there is nothing left to shift. Kept as an
    /// accepted parameter so upstream's whole settings→table→row plumbing (ten
    /// files, none of which the fork otherwise touches) stays byte-identical
    /// and merges cleanly. Removing the setting is upstream's call, not a
    /// reason for the fork to rewrite its pipeline.
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    // SUPERMUX:end supermux-mobile-unread-badge

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // SUPERMUX:begin supermux-mobile-unread-badge (upstream reserved a
            // fixed unread gutter here — see SUPERMUX-TOUCHPOINTS.md)
            // The unread badge now sits inline with the title instead of in a
            // reserved left column. Upstream's gutter kept every row's text
            // indented past an empty slot most rows never filled, which is the
            // blank space that showed up on global workspace rows.
            Color.clear
                .frame(width: WorkspaceColorRail.width)
            // SUPERMUX:end supermux-mobile-unread-badge

            Spacer()
                .frame(width: Self.railTextVisualGap)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(wrapWorkspaceTitles ? nil : 1)

                    // SUPERMUX:begin supermux-mobile-unread-badge
                    // Trails the name, the way Mail and Messages badge a row:
                    // it reads as belonging to this workspace rather than to
                    // the column of dots it used to sit in.
                    WorkspaceUnreadDot(
                        isUnread: workspace.hasUnread,
                        unreadCount: workspace.supermuxUnreadCount
                    )
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    // SUPERMUX:end supermux-mobile-unread-badge

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(connectionStatus: connectionStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let description = workspace.displayDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(workspace.previewLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(previewLineLimit, reservesSpace: true)

                    if let changesChip, changesChip.filesChanged > 0 {
                        Spacer(minLength: 8)
                        changesChipView(changesChip)
                    }
                }
            }
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: railLeadingOffset)

                WorkspaceColorRail(color: workspace.workspaceAccentColor)
                    .padding(.vertical, Self.railVerticalInset)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func changesChipView(_ chip: MobileWorkspaceChangesChip) -> some View {
        if let onOpenChanges {
            Button(action: onOpenChanges) {
                WorkspaceChangesChipLabel(
                    chip: chip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue
                )
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        } else {
            WorkspaceChangesChipLabel(
                chip: chip,
                workspaceID: workspace.rpcWorkspaceID.rawValue
            )
        }
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
