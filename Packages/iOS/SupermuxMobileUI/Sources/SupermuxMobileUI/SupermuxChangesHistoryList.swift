import SwiftUI

/// The History segment: incoming commits (when the upstream has any), the
/// paginated local commit list with unpushed styling, and a Load More row
/// while the Mac reports another page. Values + closures only.
struct SupermuxChangesHistoryList: View {
    let incoming: [SupermuxCommitRowSnapshot]
    let commits: [SupermuxCommitRowSnapshot]
    let hasLoaded: Bool
    let isLoading: Bool
    let hasMore: Bool
    let errorDescription: String?
    let loadMore: @MainActor () -> Void

    var body: some View {
        List {
            if let errorDescription {
                Section {
                    Text(errorDescription)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("SupermuxHistoryError")
                }
            }
            if !incoming.isEmpty {
                Section {
                    ForEach(incoming) { row in
                        SupermuxCommitMobileRow(row: row)
                    }
                } header: {
                    Text(String(
                        localized: "supermux.changes.history.incoming",
                        defaultValue: "Incoming",
                        bundle: .module
                    ))
                }
            }
            if commits.isEmpty {
                Section {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(
                                localized: "supermux.changes.history.loading",
                                defaultValue: "Loading history…",
                                bundle: .module
                            ))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    } else if hasLoaded {
                        Text(String(
                            localized: "supermux.changes.history.empty",
                            defaultValue: "No commits yet.",
                            bundle: .module
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(commits) { row in
                        SupermuxCommitMobileRow(row: row)
                    }
                    if hasMore {
                        Button(action: loadMore) {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(String(
                                    localized: "supermux.changes.history.loadMore",
                                    defaultValue: "Load More",
                                    bundle: .module
                                ))
                                .font(.callout)
                            }
                        }
                        .disabled(isLoading)
                        .accessibilityIdentifier("SupermuxHistoryLoadMoreButton")
                    }
                } header: {
                    Text(String(
                        localized: "supermux.changes.history.commits",
                        defaultValue: "Commits",
                        bundle: .module
                    ))
                }
            }
        }
        .accessibilityIdentifier("SupermuxChangesHistoryList")
    }
}

/// One commit row: subject over sha/author/date metadata, with an orange
/// up-arrow badge on commits not yet pushed (`is_pushed == false`).
struct SupermuxCommitMobileRow: View {
    let row: SupermuxCommitRowSnapshot

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.subject)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(row.shortSha)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let author = row.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let relativeDate = row.relativeDate {
                        Text(relativeDate)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if row.isUnpushed {
                Image(systemName: "arrow.up.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(String(
                        localized: "supermux.changes.history.unpushed",
                        defaultValue: "Not pushed",
                        bundle: .module
                    ))
            }
        }
        .accessibilityIdentifier("SupermuxCommitRow-\(row.id)")
    }
}
