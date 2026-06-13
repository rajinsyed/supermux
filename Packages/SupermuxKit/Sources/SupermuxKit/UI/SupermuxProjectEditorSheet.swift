public import SwiftUI
import AppKit

/// A sheet for editing a registered project's settings: name, accent color,
/// icon, default base branch, worktrees folder, and run commands.
///
/// The project is copied into local state on init; nothing is persisted until
/// the user confirms with Save, which routes the edited record through
/// ``SupermuxProjectsModel/updateProject(_:)`` and dismisses the sheet.
public struct SupermuxProjectEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let model: SupermuxProjectsModel
    @State private var edited: SupermuxProject
    @State private var iconInput: String
    @State private var defaultBranchInput: String
    @State private var worktreesDirInput: String
    @State private var runCommandsInput: String

    /// Creates the editor.
    /// - Parameters:
    ///   - model: Shared projects model that receives the saved record.
    ///   - project: The project to edit; copied into local state.
    public init(model: SupermuxProjectsModel, project: SupermuxProject) {
        self.model = model
        _edited = State(initialValue: project)
        _iconInput = State(initialValue: project.iconSymbol ?? "")
        _defaultBranchInput = State(initialValue: project.defaultBranch ?? "")
        _worktreesDirInput = State(initialValue: project.worktreesDirName)
        _runCommandsInput = State(initialValue: project.runCommands.joined(separator: "\n"))
    }

    /// The sheet content.
    public var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "supermux.projectEditor.title", defaultValue: "Edit Project"))
                .font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 2)
            Form {
                Section {
                    TextField(
                        String(localized: "supermux.projectEditor.name", defaultValue: "Name"),
                        text: $edited.name
                    )
                    colorRow
                    iconRow
                }
                Section {
                    baseBranchRow
                    worktreesFolderRow
                }
                Section {
                    runCommandsRow
                }
                Section {
                    locationRow
                }
            }
            .formStyle(.grouped)
            Divider()
            buttonBar
        }
        .frame(width: 420, height: 540)
    }

    // MARK: - Rows

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "supermux.projectEditor.color", defaultValue: "Color"))
            HStack(spacing: 6) {
                swatch(
                    hex: nil,
                    label: String(localized: "supermux.projectEditor.noColor", defaultValue: "No Color")
                )
                ForEach(SupermuxProjectColor.palette) { entry in
                    swatch(hex: entry.hex, label: entry.name)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconRow: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "supermux.projectEditor.icon", defaultValue: "Icon"),
                text: $iconInput,
                prompt: Text(String(
                    localized: "supermux.projectEditor.iconPrompt",
                    defaultValue: "SF Symbol name"
                ))
            )
            .autocorrectionDisabled()
            if isIconPreviewable {
                Image(systemName: trimmedIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var baseBranchRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                String(localized: "supermux.projectEditor.baseBranch", defaultValue: "Default Base Branch"),
                text: $defaultBranchInput
            )
            .autocorrectionDisabled()
            Text(String(
                localized: "supermux.projectEditor.baseBranch.help",
                defaultValue: "New worktrees branch from this; empty uses HEAD"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var worktreesFolderRow: some View {
        TextField(
            String(localized: "supermux.projectEditor.worktreesFolder", defaultValue: "Worktrees Folder"),
            text: $worktreesDirInput,
            prompt: Text(verbatim: ".worktrees")
        )
        .autocorrectionDisabled()
    }

    private var runCommandsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "supermux.projectEditor.runCommands", defaultValue: "Run Commands"))
            TextEditor(text: $runCommandsInput)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }
            Text(String(
                localized: "supermux.projectEditor.runCommands.help",
                defaultValue: "Started and stopped with the Run action"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var locationRow: some View {
        LabeledContent {
            Text(edited.rootPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text(String(localized: "supermux.projectEditor.location", defaultValue: "Location"))
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "supermux.projectEditor.save", defaultValue: "Save")) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedName.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Pieces

    private func swatch(hex: String?, label: String) -> some View {
        let isSelected = edited.colorHex?.lowercased() == hex?.lowercased()
        return Button {
            edited.colorHex = hex
        } label: {
            ZStack {
                if let fill = SupermuxProjectColor.color(fromHex: hex) {
                    Circle().fill(fill)
                } else {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Derived state

    private var trimmedName: String {
        edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedIcon: String {
        iconInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isIconPreviewable: Bool {
        !trimmedIcon.isEmpty
            && NSImage(systemSymbolName: trimmedIcon, accessibilityDescription: nil) != nil
    }

    // MARK: - Actions

    private func save() {
        var project = edited
        project.name = trimmedName
        project.iconSymbol = trimmedIcon.isEmpty ? nil : trimmedIcon
        let branch = defaultBranchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        project.defaultBranch = branch.isEmpty ? nil : branch
        let folder = worktreesDirInput
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        project.worktreesDirName = folder.isEmpty ? ".worktrees" : folder
        project.runCommands = runCommandsInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        model.updateProject(project)
        dismiss()
    }
}
