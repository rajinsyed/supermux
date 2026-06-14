import SwiftUI

/// One unpushed-commit row: short hash, subject, and an author · relative-date
/// caption.
///
/// Takes an immutable ``SupermuxGitCommit`` value only, keeping it below the
/// panel's `LazyVStack` snapshot boundary.
struct SupermuxCommitRowView: View {
    let commit: SupermuxGitCommit

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(commit.shortHash)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(subjectText)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metaText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(isHovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .help(subjectText)
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
}
