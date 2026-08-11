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
/// own sizes, so rows do not jump when real data replaces the skeleton.
struct SupermuxProjectSkeletonRow: View {
    /// Row position, used to vary the title width so the placeholder reads as
    /// a list of different projects rather than a repeated bar.
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmering = false
    // Scaled like the real row's: a skeleton that ignored Dynamic Type would
    // jump to a different height the moment data replaced it — the exact
    // thing this placeholder exists to prevent. Not `private`, or the
    // memberwise initializer this row is constructed with disappears.
    var metrics = SupermuxScaledRowMetrics()

    private var titleWidth: CGFloat {
        [124, 88, 106][index % 3]
    }

    var body: some View {
        HStack(spacing: metrics.avatarTextGap) {
            RoundedRectangle(cornerRadius: metrics.avatarSize * 0.3, style: .continuous)
                .fill(placeholderStyle)
                .frame(width: metrics.avatarSize, height: metrics.avatarSize)
            Capsule().fill(placeholderStyle).frame(width: titleWidth, height: 10)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, SupermuxProjectRowMetrics.rowHorizontalPadding)
        .frame(minHeight: metrics.minimumRowHeight)
        .opacity(shimmering ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmering = true
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholderStyle: some ShapeStyle {
        Color.primary.opacity(0.09)
    }
}
