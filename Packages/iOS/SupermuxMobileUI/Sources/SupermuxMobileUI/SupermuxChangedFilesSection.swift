import SupermuxMobileKit
import SwiftUI

/// The branch summary header: branch name, ahead/behind counts, and the
/// store's non-blocking error surface. Values only — no store reference.
struct SupermuxChangesSummarySection: View {
    let branch: String?
    let ahead: Int
    let behind: Int
    let errorDescription: String?

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(
                        localized: "supermux.changes.branchLabel",
                        defaultValue: "Branch",
                        bundle: .module
                    ))
                Text(branch ?? String(
                    localized: "supermux.changes.detachedHead",
                    defaultValue: "Detached HEAD",
                    bundle: .module
                ))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if ahead > 0 {
                    Text(verbatim: "↑\(ahead)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            localized: "supermux.changes.ahead",
                            defaultValue: "\(ahead) commits ahead",
                            bundle: .module
                        ))
                }
                if behind > 0 {
                    Text(verbatim: "↓\(behind)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            localized: "supermux.changes.behind",
                            defaultValue: "\(behind) commits behind",
                            bundle: .module
                        ))
                }
            }
            if let errorDescription {
                Text(errorDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("SupermuxChangesError")
            }
        }
    }
}

/// A closure bundle for a section header's trailing action (Stage All /
/// Unstage All).
struct SupermuxChangesSectionHeaderAction {
    let title: String
    let identifier: String
    let perform: @MainActor () -> Void
}

/// One bucket of changed files: header (+ optional bulk action) and rows.
/// Rows receive immutable snapshots plus closures only.
struct SupermuxChangedFilesSection: View {
    let title: String
    let rows: [SupermuxChangedFileRowSnapshot]
    let actionsDisabled: Bool
    var headerAction: SupermuxChangesSectionHeaderAction?
    var stage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var unstage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var requestDiscard: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?

    var body: some View {
        Section {
            ForEach(rows) { row in
                SupermuxChangedFileMobileRow(
                    row: row,
                    actionsDisabled: actionsDisabled,
                    stage: stage,
                    unstage: unstage,
                    requestDiscard: requestDiscard
                )
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 0)
                if let headerAction {
                    Button(action: headerAction.perform) {
                        Text(headerAction.title)
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier(headerAction.identifier)
                }
            }
        }
    }
}

/// One changed-file row: status letter, emphasized filename over its
/// de-emphasized directory, swipe actions, and navigation into the diff.
struct SupermuxChangedFileMobileRow: View {
    let row: SupermuxChangedFileRowSnapshot
    let actionsDisabled: Bool
    var stage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var unstage: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?
    var requestDiscard: (@MainActor (_ row: SupermuxChangedFileRowSnapshot) -> Void)?

    var body: some View {
        NavigationLink(value: row) {
            HStack(spacing: 10) {
                Text(verbatim: row.kindBadge)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(badgeTint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let directory = row.directory {
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let requestDiscard {
                Button(role: .destructive) {
                    requestDiscard(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.discard",
                            defaultValue: "Discard",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                .disabled(actionsDisabled)
            }
            if let stage {
                Button {
                    stage(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.stage",
                            defaultValue: "Stage",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "plus.circle")
                    }
                }
                .tint(.green)
                .disabled(actionsDisabled)
            }
            if let unstage {
                Button {
                    unstage(row)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.changes.action.unstage",
                            defaultValue: "Unstage",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "minus.circle")
                    }
                }
                .tint(.orange)
                .disabled(actionsDisabled)
            }
        }
        .accessibilityLabel(row.fileName)
        .accessibilityValue(row.directory ?? "")
        .accessibilityIdentifier("SupermuxChangedFileRow-\(row.id)")
    }

    /// Status tint following the desktop's changes-list convention:
    /// additions/untracked green, deletions red, everything else neutral.
    private var badgeTint: Color {
        switch row.kind {
        case "added", "untracked": .green
        case "deleted": .red
        case "conflicted": .orange
        default: .secondary
        }
    }
}
