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
            // Skeleton rows in the real row's shape, not a spinner: the list
            // keeps its geometry, so rows land in place instead of the section
            // snapping from one line to full height when the fetch returns.
            ForEach(0..<3, id: \.self) { index in
                SupermuxProjectSkeletonRow(index: index)
                    .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                    .listRowSeparator(.hidden)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(
                localized: "supermux.projects.loading",
                defaultValue: "Loading projects…",
                bundle: .module
            ))
        } else if section.rows.isEmpty {
            SupermuxProjectsEmptyState(editing: actions.editing)
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

/// The project avatar now lives in `SupermuxProjectAvatar.swift`
/// (``SupermuxProjectAvatar``), which draws the accent-gradient chip.
