import SwiftUI

/// One unpushed-commit row: the subject on its own full-width line above an
/// author · relative-date caption, with the short hash trailing the caption.
///
/// The subject is the only field worth reading at a glance, so it gets the
/// panel's whole width (the sidebar is narrow; a leading hash column used to
/// truncate it after a few words). The hash stays available but de-emphasized
/// on the caption line, right-aligned so hashes form a column.
///
/// Takes an immutable ``SupermuxGitCommit`` value only, keeping it below the
/// panel's `LazyVStack` snapshot boundary.
struct SupermuxCommitRowView: View {
    let commit: SupermuxGitCommit

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subjectText)
                .font(.system(size: 11.5))
                .lineLimit(2)
                .truncationMode(.tail)
                // Let a wrapped second line grow the row instead of clipping.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(metaText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // Keeps its full width; the meta caption truncates first.
                Text(commit.shortHash)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(isHovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var subjectText: String {
        commit.subject.isEmpty
            ? String(localized: "supermux.changes.unpushed.noSubject", defaultValue: "(no message)")
            : commit.subject
    }

    private var metaText: String {
        String(
            localized: "supermux.changes.unpushed.meta",
            defaultValue: "\(commit.author) · \(commit.relativeDate)"
        )
    }

    /// Hover help: the full subject plus the caption, so a truncated row is
    /// still readable in place.
    private var helpText: String {
        String(
            localized: "supermux.changes.unpushed.rowHelp",
            defaultValue: "\(subjectText)\n\(commit.shortHash) · \(metaText)"
        )
    }
}
