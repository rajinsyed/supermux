import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
public import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The collapsible Projects section mounted above the workspace group
/// sections in the shell's workspace `List`.
///
/// Mirrors the mac sidebar's Projects section (m6-f1/m6-f2): a project's
/// open workspaces are ALWAYS nested under it (branch subtitles, trailing
/// activity/PR/run status — exactly like the mac), each project row is an
/// INLINE disclosure — tapping it expands/collapses the project's unopened
/// worktrees (PR badges) directly in the list — and the project DETAIL
/// screen stays reachable through the row's info accessory and long-press
/// menu.
///
/// Renders exclusively from an immutable ``SupermuxProjectsSectionSnapshot``
/// plus a closure ``SupermuxProjectsSectionActions`` bundle — no store
/// reference crosses the `List` boundary. Renders nothing at all while the
/// snapshot is hidden (disconnected, or the host lacks
/// `supermux.projects.v1`), so a fork phone against an upstream Mac shows
/// exactly today's UI.
public struct SupermuxProjectsMobileSection: View {
    private let section: SupermuxProjectsSectionSnapshot
    private let actions: SupermuxProjectsSectionActions

    /// Creates the section.
    /// - Parameters:
    ///   - section: The section's value snapshot (from the model).
    ///   - actions: The closure bundle rows act through.
    public init(section: SupermuxProjectsSectionSnapshot, actions: SupermuxProjectsSectionActions) {
        self.section = section
        self.actions = actions
    }

    public var body: some View {
        if section.isVisible {
            Section {
                if !section.isCollapsed {
                    sectionRows
                }
            } header: {
                SupermuxProjectsSectionHeader(
                    isCollapsed: section.isCollapsed,
                    toggleCollapsed: actions.toggleCollapsed,
                    editing: actions.editing
                )
            }
        }
    }

    @ViewBuilder
    private var sectionRows: some View {
        if !section.hasLoaded {
            HStack(spacing: 8) {
                ProgressView()
                Text(String(
                    localized: "supermux.projects.loading",
                    defaultValue: "Loading projects…",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
            .listRowSeparator(.hidden)
        } else if section.rows.isEmpty {
            Text(String(
                localized: "supermux.projects.empty",
                defaultValue: "No projects yet",
                bundle: .module
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
            .listRowSeparator(.hidden)
        } else {
            ForEach(section.rows) { row in
                SupermuxProjectMobileRow(
                    row: row,
                    iconPNGData: actions.iconPNGData,
                    toggleExpanded: actions.toggleProjectExpanded,
                    openDetail: actions.openProjectDetail
                )
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
                // Mac-sidebar shape: open workspaces are ALWAYS nested under
                // their project; only the unopened-worktree slice (inside
                // SupermuxProjectNestedRows) waits for the disclosure.
                SupermuxProjectNestedRows(row: row, actions: actions)
            }
        }
    }

    /// Matches the shell's workspace-row insets so the sections align.
    static let rowInsets = EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
}

/// The tappable section header: title plus a collapse chevron, and — when
/// the editing seam is live — a trailing "+" that opens the create-project
/// editor.
struct SupermuxProjectsSectionHeader: View {
    let isCollapsed: Bool
    let toggleCollapsed: @MainActor () -> Void
    var editing: SupermuxProjectEditingActions?

    @State private var showingCreateEditor = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 6) {
                    Text(String(
                        localized: "supermux.projects.sectionTitle",
                        defaultValue: "Projects",
                        bundle: .module
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isCollapsed
                ? String(localized: "supermux.projects.section.expand", defaultValue: "Expand", bundle: .module)
                : String(localized: "supermux.projects.section.collapse", defaultValue: "Collapse", bundle: .module))
            .accessibilityIdentifier("SupermuxProjectsSectionHeader")
            if let editing {
                Button {
                    showingCreateEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    localized: "supermux.projects.section.add",
                    defaultValue: "Add Project",
                    bundle: .module
                ))
                .accessibilityIdentifier("SupermuxProjectsSectionAddButton")
                .sheet(isPresented: $showingCreateEditor) {
                    SupermuxProjectEditorSheet(mode: .create, editing: editing)
                }
            }
        }
    }
}

/// Project avatar, in the §7 display order: fetched custom icon → SF symbol
/// → letter, the latter two tinted by the project's accent color.
struct SupermuxProjectMobileAvatar: View {
    let row: SupermuxProjectRowSnapshot
    let size: CGFloat
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?

    @State private var customIcon: Image?

    private var accent: Color {
        row.avatarRGB.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .secondary
    }

    var body: some View {
        ZStack {
            if let customIcon {
                customIcon
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(accent.opacity(0.22))
                if let symbol = row.iconSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.48, weight: .medium))
                        .foregroundStyle(accent)
                } else {
                    Text(row.avatarLetter)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .task(id: iconIdentity) {
            guard row.hasCustomIcon else {
                customIcon = nil
                return
            }
            guard let data = await iconPNGData(row.id) else { return }
            customIcon = Self.decodeImage(data)
        }
        .accessibilityHidden(true)
    }

    /// The avatar's icon-refetch identity: only the fields that actually
    /// change which bytes must be fetched/decoded. Keying `.task(id:)` on the
    /// FULL row snapshot re-issues `project.icon` and re-decodes the PNG on
    /// EVERY unrelated row change (branch subtitle, expansion, counts,
    /// run state, …); keying on just the project id + custom-icon flag +
    /// content etag re-fetches only when the project changes, its custom-icon
    /// flag flips, or the icon's CONTENT changes (a Mac-side icon replacement
    /// keeps the flag `true` but moves the etag — without the etag in the
    /// identity that change would never re-run the task and the stale icon
    /// would render forever).
    private var iconIdentity: SupermuxProjectIconIdentity {
        SupermuxProjectIconIdentity(
            projectID: row.id,
            hasCustomIcon: row.hasCustomIcon,
            iconETag: row.iconETag
        )
    }

    private static func decodeImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        nil
        #endif
    }
}

/// See ``SupermuxProjectMobileAvatar/iconIdentity``. Internal (not private)
/// so a focused unit test can pin the equality semantics without a SwiftUI
/// test harness.
struct SupermuxProjectIconIdentity: Equatable {
    let projectID: String
    let hasCustomIcon: Bool
    /// The icon's content etag (`nil` while the wire doesn't surface one) —
    /// the signal that re-keys the fetch when the icon's BYTES change while
    /// `hasCustomIcon` stays `true`.
    let iconETag: String?
}
