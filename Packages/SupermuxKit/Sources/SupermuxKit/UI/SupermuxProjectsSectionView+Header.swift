import SwiftUI
import AppKit

/// The section header, empty hint, storage-problem notice, and add-project
/// picker for ``SupermuxProjectsSectionView``.
///
/// Split out of `SupermuxProjectsSectionView.swift` to keep the section file
/// inside the fork's Swift file-length budget.
extension SupermuxProjectsSectionView {
    var header: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.isSectionCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.isSectionCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8 * fontScale, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "supermux.projects.header", defaultValue: "Projects"))
                        .font(.system(size: 10.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                pickAndAddProject()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10 * fontScale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.projects.add.help", defaultValue: "Add a project folder"))
            .accessibilityLabel(String(localized: "supermux.projects.add.help", defaultValue: "Add a project folder"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    var emptyHint: some View {
        Text(String(
            localized: "supermux.projects.empty",
            defaultValue: "Add a repo to pin it here"
        ))
        .font(.system(size: 10.5 * fontScale))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Compact warning caption for projects-file load/save problems.
    func storageNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 9.5 * fontScale))
            .foregroundStyle(.orange)
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    func pickAndAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "supermux.projects.add.prompt", defaultValue: "Add Project")
        panel.message = String(
            localized: "supermux.projects.add.message",
            defaultValue: "Choose a repository or folder to pin as a project"
        )
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task {
            for path in paths {
                await model.addProject(rootPath: path)
            }
        }
    }
}
