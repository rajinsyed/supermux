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
                    projectCount: section.hasLoaded ? section.rows.count : nil,
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
                    openWorkspace: actions.openProjectWorkspace,
                    openDetail: actions.openProjectDetail,
                    newWorktree: section.showsWorktreeCreation
                        ? actions.requestNewWorktree
                        : nil
                )
                .listRowInsets(SupermuxProjectsMobileSection.rowInsets)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Details on the outside, New Worktree revealed first —
                    // the same order as the table path's custom tray.
                    Button {
                        actions.openProjectDetail(row.id)
                    } label: {
                        Label {
                            Text(String(
                                localized: "supermux.projects.row.details",
                                defaultValue: "Project Details",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                    }
                    if section.showsWorktreeCreation {
                        Button {
                            actions.requestNewWorktree(row.id)
                        } label: {
                            Label {
                                Text(String(
                                    localized: "supermux.worktrees.new",
                                    defaultValue: "New Worktree",
                                    bundle: .module
                                ))
                            } icon: {
                                Image(systemName: "arrow.triangle.branch")
                            }
                        }
                        .tint(.accentColor)
                    }
                }
                // Mac-sidebar shape: open workspaces are ALWAYS nested under
                // their project; only the unopened-worktree slice (inside
                // SupermuxProjectNestedRows) waits for the disclosure.
                SupermuxProjectNestedRows(
                    row: row,
                    actions: actions,
                    showsNewWorktree: section.showsWorktreeCreation
                )
            }
        }
    }

    /// Matches the shell's workspace-row insets so the sections align.
    static let rowInsets = EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
}

/// The tappable section header: an uppercase caption title with a collapse
/// chevron and a project count, plus — when the editing seam is live — a
/// trailing "+" that opens the create-project editor.
///
/// Styled as a sidebar section label rather than a content heading, matching
/// the Mac's uppercase secondary "PROJECTS": the header is a divider between
/// groups of rows, so it should recede, and the previous `.subheadline`
/// primary-colored title competed with the project names underneath it.
struct SupermuxProjectsSectionHeader: View {
    let isCollapsed: Bool
    /// Number of projects, shown while collapsed so the fold still reports
    /// what it is hiding; `nil` before the first fetch lands.
    var projectCount: Int?
    let toggleCollapsed: @MainActor () -> Void
    var editing: SupermuxProjectEditingActions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingCreateEditor = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                SupermuxHaptics.selection()
                toggleCollapsed()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .animation(
                            reduceMotion ? nil : SupermuxProjectMotion.disclosure,
                            value: isCollapsed
                        )
                    Text(String(
                        localized: "supermux.projects.sectionTitle",
                        defaultValue: "Projects",
                        bundle: .module
                    ))
                    .font(.system(.caption2, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    // The count only earns its place when the rows are hidden.
                    if isCollapsed, let projectCount, projectCount > 0 {
                        Text(projectCount.formatted())
                            .font(.system(.caption2, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, SupermuxProjectRowMetrics.rowHorizontalPadding)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "supermux.projects.sectionTitle",
                defaultValue: "Projects",
                bundle: .module
            ))
            .accessibilityHint(isCollapsed
                ? String(localized: "supermux.projects.section.expand", defaultValue: "Expand", bundle: .module)
                : String(localized: "supermux.projects.section.collapse", defaultValue: "Collapse", bundle: .module))
            .accessibilityIdentifier("SupermuxProjectsSectionHeader")
            if let editing {
                Button {
                    showingCreateEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
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
