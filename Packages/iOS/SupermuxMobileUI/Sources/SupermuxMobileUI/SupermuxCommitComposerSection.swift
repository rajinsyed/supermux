import SwiftUI

/// The commit composer inside the changes list: a message field plus one
/// primary button that commits the draft — or, while the draft is empty,
/// generates a Mac-side AI message and commits in one tap. Values, a text
/// binding, and closures only — no store reference below the list boundary.
struct SupermuxCommitComposerSection: View {
    @Binding var message: String
    let hasStagedFiles: Bool
    /// Whether the repo has any uncommitted change (staged, unstaged, or
    /// untracked). Generate & Commit stages everything Mac-side, so it is
    /// enabled whenever anything is uncommitted — not only when pre-staged.
    let hasChanges: Bool
    let isBusy: Bool
    let isGenerating: Bool
    let committedShortSha: String?
    let aiUnavailableNotice: String?
    let commit: @MainActor () -> Void
    let generateAndCommit: @MainActor () -> Void

    private var draftIsEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plain Commit needs staged files; Generate & Commit (empty draft) stages
    /// everything itself, so it only needs some uncommitted change to exist.
    private var canCommit: Bool {
        draftIsEmpty ? hasChanges : hasStagedFiles
    }

    var body: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.changes.commit.placeholder",
                    defaultValue: "Commit message",
                    bundle: .module
                ),
                text: $message,
                axis: .vertical
            )
            .lineLimit(2...4)
            .disabled(isGenerating)
            .accessibilityIdentifier("SupermuxCommitMessageField")

            Button {
                if draftIsEmpty {
                    generateAndCommit()
                } else {
                    commit()
                }
            } label: {
                HStack(spacing: 6) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(
                            localized: "supermux.changes.commit.generating",
                            defaultValue: "Generating message…",
                            bundle: .module
                        ))
                    } else if draftIsEmpty {
                        Label {
                            Text(String(
                                localized: "supermux.changes.commit.generateAndCommit",
                                defaultValue: "Generate & Commit",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    } else {
                        Label {
                            Text(String(
                                localized: "supermux.changes.commit.action",
                                defaultValue: "Commit",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                }
            }
            .disabled(isBusy || !canCommit)
            .accessibilityIdentifier("SupermuxCommitButton")

            if let committedShortSha {
                Label {
                    Text(String(
                        localized: "supermux.changes.commit.committed",
                        defaultValue: "Committed \(committedShortSha)",
                        bundle: .module
                    ))
                    .font(.footnote)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundStyle(.green)
                .accessibilityIdentifier("SupermuxCommitConfirmation")
            }

            if let aiUnavailableNotice {
                VStack(alignment: .leading, spacing: 2) {
                    // Friendly localized headline; the Mac's message rides
                    // below it verbatim (no-key vs failed-generation differ).
                    Text(String(
                        localized: "supermux.changes.commit.aiUnavailable",
                        defaultValue: "AI commit messages aren't available.",
                        bundle: .module
                    ))
                    .font(.footnote.weight(.semibold))
                    Text(aiUnavailableNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("SupermuxAIUnavailableNotice")
            }
        } header: {
            Text(String(
                localized: "supermux.changes.commit.section",
                defaultValue: "Commit",
                bundle: .module
            ))
        }
    }
}
