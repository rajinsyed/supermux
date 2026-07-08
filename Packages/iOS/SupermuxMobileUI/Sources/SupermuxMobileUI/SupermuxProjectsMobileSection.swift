public import Foundation
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
                    toggleCollapsed: actions.toggleCollapsed
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
                    selectWorkspace: actions.selectWorkspace,
                    makeWorktreesStore: actions.makeWorktreesStore
                )
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Matches the shell's workspace-row insets so the sections align.
    private static let rowInsets = EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
}

/// The tappable section header: title plus a collapse chevron.
struct SupermuxProjectsSectionHeader: View {
    let isCollapsed: Bool
    let toggleCollapsed: @MainActor () -> Void

    var body: some View {
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
    }
}

/// One project row: avatar, name, root path, and count badges. Pushes the
/// read-only detail screen via the stack's standard link.
struct SupermuxProjectMobileRow: View {
    let row: SupermuxProjectRowSnapshot
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    var selectWorkspace: @MainActor (_ workspaceID: String) -> Void = { _ in }
    var makeWorktreesStore: @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore? = { _ in nil }

    var body: some View {
        NavigationLink {
            SupermuxProjectDetailScreen(
                row: row,
                iconPNGData: iconPNGData,
                selectWorkspace: selectWorkspace,
                makeWorktreesStore: makeWorktreesStore
            )
        } label: {
            HStack(spacing: 10) {
                SupermuxProjectMobileAvatar(row: row, size: 32, iconPNGData: iconPNGData)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(row.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                countBadges
            }
        }
        .accessibilityIdentifier("SupermuxProjectRow-\(row.id)")
    }

    /// Count badges render only when real data exists (`nil` = hidden, never
    /// a made-up zero badge): the worktree count arrives once a worktrees
    /// fetch has run for the project, the workspace count from the §6 join.
    @ViewBuilder
    private var countBadges: some View {
        if let count = row.worktreeCount {
            countBadge(systemImage: "arrow.triangle.branch", count: count)
        }
        if let count = row.openWorkspaceCount {
            countBadge(systemImage: "square.on.square", count: count)
        }
    }

    private func countBadge(systemImage: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(verbatim: "\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
        .task(id: row) {
            guard row.hasCustomIcon else {
                customIcon = nil
                return
            }
            guard let data = await iconPNGData(row.id) else { return }
            customIcon = Self.decodeImage(data)
        }
        .accessibilityHidden(true)
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
