public import SwiftUI

/// A sheet for editing a registered project's settings: name, accent color,
/// icon, default base branch, worktrees folder, run commands, and custom
/// actions.
///
/// The project is copied into local state on init; nothing is persisted until
/// the user confirms with Save, which routes the edited record through
/// ``SupermuxProjectsModel/updateProject(_:)`` and dismisses the sheet. When a
/// repo-shipped `config.json` owns the run/setup/teardown/actions fields, Save
/// also writes any change to them into the project's `.supermux/config.json`.
public struct SupermuxProjectEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let model: SupermuxProjectsModel
    @State private var edited: SupermuxProject
    @State private var iconInput: String
    @State private var defaultBranchInput: String
    @State private var worktreesDirInput: String
    @State private var runCommandsInput: String
    @State private var setupCommandsInput: String
    @State private var teardownCommandsInput: String
    /// Relative path of the project's `config.json` when one manages it, e.g.
    /// `.superset/config.json`; `nil` when the project has no config file. When
    /// set, the run/setup/teardown/actions fields are config-owned: Save writes
    /// changes to them into `.supermux/config.json`.
    @State private var configRelativePath: String?
    /// The run/setup/teardown/actions as loaded from `config.json`, so Save
    /// writes the file only when one of them actually changed.
    @State private var configBaseline: ScriptFields?
    @State private var isSaving = false
    @State private var saveError: String?

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
        _setupCommandsInput = State(initialValue: project.setupCommands.joined(separator: "\n"))
        _teardownCommandsInput = State(initialValue: project.teardownCommands.joined(separator: "\n"))
    }

    /// Whether a repo-shipped `config.json` owns the run/setup/teardown/actions
    /// fields, so Save writes them to `.supermux/config.json`.
    private var isConfigManaged: Bool { configRelativePath != nil }

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
                    SupermuxProjectIconEditor(
                        rootPath: edited.rootPath,
                        iconSymbolText: $iconInput,
                        customIconPath: $edited.customIconPath
                    )
                }
                Section {
                    baseBranchRow
                    worktreesFolderRow
                }
                if isConfigManaged {
                    configManagedSection
                }
                Section {
                    runCommandsRow
                }
                Section {
                    scriptRow(
                        title: String(localized: "supermux.projectEditor.setupScript", defaultValue: "Setup Script"),
                        help: String(
                            localized: "supermux.projectEditor.setupScript.help",
                            defaultValue: "Runs in a new worktree right after it is created. $SUPERSET_ROOT_PATH points at the main checkout."
                        ),
                        text: $setupCommandsInput
                    )
                    scriptRow(
                        title: String(localized: "supermux.projectEditor.teardownScript", defaultValue: "Teardown Script"),
                        help: String(
                            localized: "supermux.projectEditor.teardownScript.help",
                            defaultValue: "Runs in a worktree right before it is removed (cleanup)."
                        ),
                        text: $teardownCommandsInput
                    )
                } header: {
                    Text(String(localized: "supermux.projectEditor.scripts", defaultValue: "Worktree Scripts"))
                }
                Section {
                    actionsRow
                } header: {
                    Text(String(localized: "supermux.projectEditor.actions", defaultValue: "Actions"))
                }
                Section {
                    locationRow
                }
            }
            .formStyle(.grouped)
            Divider()
            buttonBar
        }
        .frame(width: 420, height: 720)
        .task { await loadConfigState() }
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

    /// A note shown when a repo-shipped `config.json` owns the run/setup/
    /// teardown/actions fields, naming the file Save writes them to.
    private var configManagedSection: some View {
        Section {
            Label {
                Text(configManagedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configManagedNote: String {
        if configRelativePath == SupermuxProjectConfigWriter.relativePath {
            return String(
                localized: "supermux.projectEditor.configSavedToSupermux",
                defaultValue: "Run, setup, teardown, and actions are saved to .supermux/config.json in this project."
            )
        }
        return String(
            localized: "supermux.projectEditor.configImported",
            defaultValue: "Run, setup, teardown, and actions come from \(configRelativePath ?? "config.json"). Changes to them are saved to .supermux/config.json, which Supermux reads first."
        )
    }

    /// A labeled multi-line script editor used for the setup and teardown
    /// fields. Each preserves newlines as a single multi-line script.
    private func scriptRow(title: String, help: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keyed by the action's stable id (never the array index): index
            // identity dangles bindings past a removal — a focused TextField
            // committing through a stale `$edited.actions[i]` after a delete
            // traps out of range — and shifts row focus onto the wrong action.
            ForEach($edited.actions) { $action in
                SupermuxProjectActionEditorRow(
                    action: $action,
                    onDelete: { [id = action.id] in
                        edited.actions.removeAll { $0.id == id }
                    }
                )
            }
            Button {
                edited.actions.append(SupermuxProjectAction(name: "", command: ""))
            } label: {
                Label(
                    String(localized: "supermux.projectEditor.addAction", defaultValue: "Add Action"),
                    systemImage: "plus"
                )
            }
            Text(String(
                localized: "supermux.projectEditor.actions.help",
                defaultValue: "Launch a command in a new workspace terminal"
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
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "supermux.projectEditor.save", defaultValue: "Save")) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedName.isEmpty || isSaving)
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

    /// The editor's current run/setup/teardown/actions, compared against
    /// ``configBaseline`` to tell whether Save must rewrite `config.json`.
    private struct ScriptFields: Equatable {
        var run: String
        var setup: String
        var teardown: String
        var actions: [SupermuxProjectAction]
    }

    private var scriptFields: ScriptFields {
        ScriptFields(
            run: runCommandsInput,
            setup: setupCommandsInput,
            teardown: teardownCommandsInput,
            actions: edited.actions
        )
    }

    // MARK: - Actions

    /// Detects whether a repo-shipped `config.json` manages this project and, if
    /// so, mirrors its live values into the script/run/action fields so the
    /// editor always starts from the file's current contents. File I/O runs off
    /// the main actor.
    private func loadConfigState() async {
        let rootPath = edited.rootPath
        let loader = SupermuxProjectConfigLoader()
        let resolved = await Task.detached { () -> (path: String, config: SupermuxProjectConfig?)? in
            guard let path = loader.resolvedRelativePath(projectRoot: rootPath) else { return nil }
            return (path, loader.load(projectRoot: rootPath))
        }.value
        // Only a config that actually parses manages the project: a malformed
        // file is treated as no config (fields stay editable), matching the
        // model — which also ignores an unparsable config — so the editor and
        // model never disagree about whether the project is config-managed.
        guard let resolved, let config = resolved.config else {
            configRelativePath = nil
            configBaseline = nil
            return
        }
        configRelativePath = resolved.path
        setupCommandsInput = config.setup.joined(separator: "\n")
        teardownCommandsInput = config.teardown.joined(separator: "\n")
        runCommandsInput = config.run.joined(separator: "\n")
        edited.actions = edited.applying(config).actions
        configBaseline = scriptFields
    }

    private func save() async {
        var project = edited
        project.name = trimmedName
        let trimmedIcon = iconInput.trimmingCharacters(in: .whitespacesAndNewlines)
        project.iconSymbol = trimmedIcon.isEmpty ? nil : trimmedIcon
        let branch = defaultBranchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        project.defaultBranch = branch.isEmpty ? nil : branch
        // Keep the worktrees folder a single safe path component: strip path
        // separators and reject "."/".." so it can never resolve outside the
        // project root (the service also enforces this defensively).
        let folder = worktreesDirInput
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        project.worktreesDirName = (folder.isEmpty || folder == "." || folder == "..") ? ".worktrees" : folder
        // When config.json owns run/setup/teardown/actions and none of them
        // changed, keep the config-derived values (already on `edited`) so the
        // record matches the next re-import and nothing is written.
        let writesConfig = isConfigManaged && scriptFields != configBaseline
        if !isConfigManaged || writesConfig {
            project.runCommands = runCommandsInput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            project.setupCommands = Self.scriptEntries(setupCommandsInput)
            project.teardownCommands = Self.scriptEntries(teardownCommandsInput)
            project.actions = edited.actions.map { a in
                var t = a
                t.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
                t.command = a.command.trimmingCharacters(in: .whitespacesAndNewlines)
                return t
            }.filter { $0.isLaunchable }
        }
        if writesConfig {
            saveError = nil
            isSaving = true
            defer { isSaving = false }
            let config = SupermuxProjectConfig(project: project)
            let rootPath = project.rootPath
            do {
                try await Task.detached {
                    try SupermuxProjectConfigWriter().write(config, projectRoot: rootPath)
                }.value
            } catch {
                saveError = Self.configSaveMessage(for: error)
                return
            }
        }
        model.updateProject(project)
        dismiss()
    }

    private static func configSaveMessage(for error: any Error) -> String {
        switch error as? SupermuxProjectConfigWriter.WriteError {
        case .existingFileUnreadable:
            return String(
                localized: "supermux.projectEditor.configSaveFailed.invalidJSON",
                defaultValue: ".supermux/config.json isn't valid JSON. Fix or delete it, then save again."
            )
        case .projectRootMissing:
            return String(
                localized: "supermux.projectEditor.configSaveFailed.rootMissing",
                defaultValue: "The project folder no longer exists."
            )
        case nil:
            return String(
                localized: "supermux.projectEditor.configSaveFailed",
                defaultValue: "Couldn't save .supermux/config.json: \(error.localizedDescription)"
            )
        }
    }

    /// Stores a setup/teardown editor's text as a single multi-line script entry
    /// (internal newlines preserved), unlike run commands which split per line.
    private static func scriptEntries(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
