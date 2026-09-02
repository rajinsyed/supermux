import SwiftUI

/// The Worktrees section of the project detail screen: loading/empty states,
/// one row per worktree, and a New Worktree button in the header.
///
/// Renders exclusively from immutable ``SupermuxWorktreeRowSnapshot`` values
/// plus closures — no store reference crosses the `List` boundary, per the
/// repo's snapshot-boundary rule.
struct SupermuxWorktreesSection: View {
    let hasLoaded: Bool
    let rows: [SupermuxWorktreeRowSnapshot]
    let isPreparingNewWorktree: Bool
    let newWorktree: @MainActor () -> Void
    /// Whether the agent-launch header button shows a spinner.
    var isPreparingAgentWorktree = false
    /// Opens the prompt-first "Start Claude" sheet; `nil` hides the button.
    var newAgentWorktree: (@MainActor () -> Void)?
    let openWorktree: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void
    let requestRemoval: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Section {
            if !hasLoaded {
                // Placeholder rows in the loaded row's shape (system redaction
                // shimmer), not a lone mini spinner: the section keeps its
                // geometry and the wait reads as content arriving.
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                        Text(verbatim: "placeholder-branch")
                            .font(.body)
                        Spacer(minLength: 4)
                    }
                    .redacted(reason: .placeholder)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(
                    localized: "supermux.worktrees.loading",
                    defaultValue: "Loading worktrees…",
                    bundle: .module
                ))
            } else if rows.isEmpty {
                Text(String(
                    localized: "supermux.worktrees.empty",
                    defaultValue: "No worktrees yet",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    SupermuxWorktreeMobileRow(
                        row: row,
                        openWorktree: openWorktree,
                        requestRemoval: requestRemoval
                    )
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(String(
                    localized: "supermux.projects.detail.worktreesTitle",
                    defaultValue: "Worktrees",
                    bundle: .module
                ))
                Spacer(minLength: 0)
                if let newAgentWorktree {
                    Button(action: newAgentWorktree) {
                        if isPreparingAgentWorktree {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isPreparingAgentWorktree)
                    .accessibilityLabel(String(
                        localized: "supermux.agent.row.start",
                        defaultValue: "Start Claude in New Worktree",
                        bundle: .module
                    ))
                    .accessibilityIdentifier("SupermuxStartClaudeButton")
                }
                Button(action: newWorktree) {
                    if isPreparingNewWorktree {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isPreparingNewWorktree)
                .accessibilityLabel(String(
                    localized: "supermux.worktrees.new",
                    defaultValue: "New Worktree",
                    bundle: .module
                ))
                .accessibilityIdentifier("SupermuxNewWorktreeButton")
            }
        }
    }
}

/// One worktree row: branch name, dirty indicator, PR badge, and either a
/// workspace link (open worktrees) or an open action (unopened ones).
/// Swipe-to-delete starts the removal flow (destructive confirm upstream).
struct SupermuxWorktreeMobileRow: View {
    let row: SupermuxWorktreeRowSnapshot
    let openWorktree: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void
    let requestRemoval: @MainActor (_ row: SupermuxWorktreeRowSnapshot) -> Void

    var body: some View {
        Button {
            openWorktree(row)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(row.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(String(
                            localized: "supermux.worktrees.row.dirty",
                            defaultValue: "Uncommitted changes",
                            bundle: .module
                        ))
                }
                Spacer(minLength: 4)
                if let pullRequest = row.pullRequest {
                    SupermuxMobilePullRequestBadge(pullRequest: pullRequest)
                }
                if row.isOpen {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestRemoval(row)
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.worktrees.remove.title",
                        defaultValue: "Remove Worktree",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .accessibilityLabel(row.displayName)
        .accessibilityValue(row.isOpen
            ? String(
                localized: "supermux.worktrees.row.openWorkspace",
                defaultValue: "Open workspace",
                bundle: .module
            )
            : "")
        .accessibilityIdentifier("SupermuxWorktreeRow-\(row.id)")
    }
}

/// The compact, tappable PR badge: a round tinted chip carrying the
/// pull-request glyph, colored by the PR's lifecycle state — the same
/// green/purple/red the desktop `SupermuxPullRequestBadge` uses. Tapping opens
/// the PR's URL locally on the phone.
///
/// Icon only, no `#123`. On the phone the number rode along at the far right of
/// a row that already truncates its workspace name and its branch, so a
/// four-digit PR stole width from the two labels that identify the row, for a
/// number nothing on this screen acts on. The state — which is what the row is
/// actually reporting — is carried by the glyph's shape and its tint, exactly
/// as the Mac badge carries its state. The number stays in the accessibility
/// label (VoiceOver has no width problem and no glyph to read) and in the URL
/// the chip opens.
struct SupermuxMobilePullRequestBadge: View {
    let pullRequest: SupermuxPullRequestBadgeSnapshot

    @Environment(\.openURL) private var openURL

    /// The glyph's footprint. Slightly up from the 12 it drew beside the
    /// number: with nothing next to it, the glyph is the whole badge and has to
    /// carry the state on its own.
    private static let glyphSize: CGFloat = 13
    /// The chip's diameter — the glyph plus the same 4pt breathing room the
    /// capsule gave it, now equal on all four sides so the badge is a circle
    /// rather than a stub of a capsule.
    private static let chipSize: CGFloat = 21
    /// How far the tap target reaches past the drawn chip. Losing the number
    /// took ~30pt of width off the old capsule, and that width was tap target
    /// too — so it comes back as an invisible margin rather than as layout, and
    /// the row keeps the width the change was made to give it. 6pt is the gap
    /// the status cluster already leaves between siblings, so the target
    /// reaches its neighbors without covering them; those neighbors (run glyph,
    /// activity spinner, unread capsule) are labels, not controls, so there is
    /// no tap to steal in the first place.
    private static let hitOutset: CGFloat = 6

    var body: some View {
        Button {
            if let url = pullRequest.url {
                openURL(url)
            }
        } label: {
            stateIcon
                .foregroundStyle(tint)
                // Stale badges (kept after repeated mac probe failures) dim to
                // 50% — the mac badge's exact treatment.
                .opacity(pullRequest.isStale ? 0.5 : 1)
                .frame(width: Self.chipSize, height: Self.chipSize)
                .background(Circle().fill(tint.opacity(0.16)))
                // Tap target only: the chip is padded out to something a thumb
                // can find, and the same padding is subtracted outside the
                // button below — so the row lays out around the 21pt chip while
                // taps land on a 33pt circle.
                .padding(Self.hitOutset)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .padding(-Self.hitOutset)
        .disabled(pullRequest.url == nil)
        .accessibilityLabel(Self.accessibilityLabel(for: pullRequest))
    }

    /// State tint mirroring the desktop badge: green open, purple merged,
    /// red closed; neutral for unknown future states.
    private var tint: Color {
        switch pullRequest.state {
        case .open: Color(red: 0.247, green: 0.722, blue: 0.314)
        case .merged: Color(red: 0.639, green: 0.443, blue: 0.969)
        case .closed: Color(red: 0.973, green: 0.318, blue: 0.286)
        case .unknown: Color.secondary
        }
    }

    /// The state icon: the Mac's real git-pull-request glyph for open/merged
    /// (`SupermuxMobilePullRequestGlyph`, same path geometry as the sidebar
    /// badge) and the same SF-symbol fallbacks for closed/unknown. Inherits
    /// the surrounding `foregroundStyle`, so the state tint colors it.
    ///
    /// The SF-symbol cases are drawn into the glyph's own footprint so all four
    /// states center identically inside the chip.
    @ViewBuilder
    private var stateIcon: some View {
        switch pullRequest.state {
        case .open:
            SupermuxMobilePullRequestGlyph(kind: .open, size: Self.glyphSize)
        case .merged:
            SupermuxMobilePullRequestGlyph(kind: .merged, size: Self.glyphSize)
        case .closed:
            Image(systemName: "xmark")
                .font(.system(size: Self.glyphSize * 0.78, weight: .semibold))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        case .unknown:
            Image(systemName: "questionmark")
                .font(.system(size: Self.glyphSize * 0.78, weight: .semibold))
                .frame(width: Self.glyphSize, height: Self.glyphSize)
        }
    }

    static func stateWord(_ state: SupermuxPullRequestBadgeState) -> String {
        switch state {
        case .open:
            String(localized: "supermux.pullRequest.status.open", defaultValue: "open", bundle: .module)
        case .merged:
            String(localized: "supermux.pullRequest.status.merged", defaultValue: "merged", bundle: .module)
        case .closed:
            String(localized: "supermux.pullRequest.status.closed", defaultValue: "closed", bundle: .module)
        case .unknown:
            String(localized: "supermux.pullRequest.status.unknown", defaultValue: "unknown", bundle: .module)
        }
    }

    /// What VoiceOver reads for the badge — and the ONLY place the PR number
    /// survives now that the chip draws the glyph alone. Not `private`, so a
    /// test can hold that line: a future tightening of the visual badge must
    /// not quietly take the number away from VoiceOver too, which has no glyph
    /// to read and no width to save.
    static func accessibilityLabel(
        for pullRequest: SupermuxPullRequestBadgeSnapshot
    ) -> String {
        String(
            localized: "supermux.pullRequest.accessibility",
            defaultValue: "Pull request #\(pullRequest.number), \(stateWord(pullRequest.state))",
            bundle: .module
        )
    }
}
