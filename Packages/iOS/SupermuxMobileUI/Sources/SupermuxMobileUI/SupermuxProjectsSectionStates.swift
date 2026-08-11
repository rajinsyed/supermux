import SwiftUI

/// The Projects section's first-run state.
///
/// A bare "No projects yet" line told the user what was missing but not what to
/// do about it, and on a phone the section header's small "+" is easy to miss.
/// This states the value of a project and offers the action inline.
struct SupermuxProjectsEmptyState: View {
    /// The editor seam; `nil` (no live session) hides the action but keeps the
    /// explanatory copy, so the section never renders a dead button.
    var editing: SupermuxProjectEditingActions?

    @State private var showingCreateEditor = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(.title3, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "supermux.projects.empty",
                defaultValue: "No projects yet",
                bundle: .module
            ))
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "supermux.projects.empty.detail",
                defaultValue: "Pin a repo to keep it here — open it, branch a worktree, and run it from your phone.",
                bundle: .module
            ))
            .font(.system(.caption))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if let editing {
                Button {
                    showingCreateEditor = true
                } label: {
                    Text(String(
                        localized: "supermux.projects.section.add",
                        defaultValue: "Add Project",
                        bundle: .module
                    ))
                    .font(.system(.footnote, weight: .medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityIdentifier("SupermuxProjectsEmptyAddButton")
                .sheet(isPresented: $showingCreateEditor) {
                    SupermuxProjectEditorSheet(mode: .create, editing: editing)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("SupermuxProjectsEmptyState")
    }
}

/// A placeholder in the loaded row's exact shape, shimmering while the first
/// `projects.list` is in flight.
///
/// Deliberately mirrors ``SupermuxProjectRowMetrics`` rather than picking its
/// own sizes, so rows do not jump when real data replaces the skeleton. The
/// shimmer is a single highlight band sweeping the row (the treatment every
/// system placeholder uses) rather than the whole row pulsing — a full-row
/// opacity pulse at sidebar size read as a blinking error, not as loading.
struct SupermuxProjectSkeletonRow: View {
    /// Row position, used to vary the title width so the placeholder reads as
    /// a list of different projects rather than a repeated bar — and to
    /// stagger each row's sweep so the section ripples instead of blinking in
    /// lockstep.
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false
    // Scaled like the real row's: a skeleton that ignored Dynamic Type would
    // jump to a different height the moment data replaced it — the exact
    // thing this placeholder exists to prevent. Not `private`, or the
    // memberwise initializer this row is constructed with disappears.
    var metrics = SupermuxScaledRowMetrics()

    private var titleWidth: CGFloat {
        [132, 96, 114][index % 3]
    }

    var body: some View {
        HStack(spacing: metrics.avatarTextGap) {
            RoundedRectangle(cornerRadius: metrics.avatarSize * 0.3, style: .continuous)
                .fill(placeholderStyle)
                .frame(width: metrics.avatarSize, height: metrics.avatarSize)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(placeholderStyle)
                .frame(width: titleWidth, height: 13)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, SupermuxProjectRowMetrics.rowHorizontalPadding)
        .frame(minHeight: metrics.minimumRowHeight)
        .overlay {
            if !reduceMotion {
                sweepHighlight
            }
        }
        .clipShape(RoundedRectangle(
            cornerRadius: SupermuxProjectRowMetrics.rowCornerRadius,
            style: .continuous
        ))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 1.1)
                    .repeatForever(autoreverses: false)
                    .delay(Double(index) * 0.12)
            ) {
                sweeping = true
            }
        }
        .accessibilityHidden(true)
    }

    /// The moving highlight: a soft diagonal band that crosses the row once
    /// per cycle. Drawn over the placeholder shapes and clipped to the row.
    private var sweepHighlight: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                colors: [
                    .clear,
                    Color.primary.opacity(0.06),
                    .clear,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.55)
            .offset(x: sweeping ? width : -width * 0.55)
        }
        .allowsHitTesting(false)
    }

    private var placeholderStyle: some ShapeStyle {
        Color.primary.opacity(0.08)
    }
}

/// A skeleton line in a NESTED row's shape, for the fetch-on-expand wait.
///
/// Replaces the `.mini` `ProgressView` + caption that used to sit there: at
/// that size the spinner was nearly invisible, and it made the disclosure the
/// one place in the section that loaded with a different vocabulary than the
/// section itself. Same bar treatment as ``SupermuxProjectSkeletonRow``, one
/// step smaller.
struct SupermuxNestedSkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmering = false
    // Scaled like the worktree rows that replace it, so the disclosure does
    // not jump taller the moment the fetch lands. See
    // SupermuxProjectSkeletonRow.metrics for why this is not `private`.
    var metrics = SupermuxScaledRowMetrics()

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 108, height: 11)
            Spacer(minLength: 0)
        }
        .frame(minHeight: metrics.compactRowHeight)
        .opacity(shimmering ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                shimmering = true
            }
        }
        .accessibilityLabel(String(
            localized: "supermux.worktrees.loading",
            defaultValue: "Loading worktrees…",
            bundle: .module
        ))
    }
}
