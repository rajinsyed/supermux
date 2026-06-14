public import SwiftUI
import AppKit

/// A sheet for editing a registered project's settings: name, accent color,
/// icon, default base branch, worktrees folder, run commands, and custom
/// actions.
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
    @State private var setupCommandsInput: String
    @State private var teardownCommandsInput: String
    /// Logo auto-detected from the project files, previewed in the icon row.
    @State private var detectedIcon: NSImage?
    /// Project-relative path of the detected logo, shown next to its preview.
    @State private var detectedIconRelativePath: String?
    /// Relative path of the project's `config.json` when one manages it, e.g.
    /// `.superset/config.json`; `nil` when the project has no config file. When
    /// set, the run/setup/teardown/actions fields are config-owned and read-only.
    @State private var configRelativePath: String?

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
    /// fields. They are then read-only — editing the file is the way to change them.
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
                    iconRow
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
                .disabled(isConfigManaged)
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
                .disabled(isConfigManaged)
                Section {
                    actionsRow
                } header: {
                    Text(String(localized: "supermux.projectEditor.actions", defaultValue: "Actions"))
                }
                .disabled(isConfigManaged)
                Section {
                    locationRow
                }
            }
            .formStyle(.grouped)
            Divider()
            buttonBar
        }
        .frame(width: 420, height: 720)
        .task { await detectIcon() }
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

    private var iconRow: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if let detectedIcon, let relativePath = detectedIconRelativePath {
                HStack(spacing: 6) {
                    Image(nsImage: detectedIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(String(
                        localized: "supermux.projectEditor.icon.detected",
                        defaultValue: "Using detected logo \(relativePath)"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            } else {
                Text(String(
                    localized: "supermux.projectEditor.icon.help",
                    defaultValue: "Shown when no logo file is found in the project"
                ))
                .font(.caption)
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

    /// A note shown when a repo-shipped `config.json` owns the run/setup/
    /// teardown/actions fields, naming the file the user should edit instead.
    private var configManagedSection: some View {
        Section {
            Label {
                Text(String(
                    localized: "supermux.projectEditor.configManaged",
                    defaultValue: "Run, setup, teardown, and actions are managed by \(configRelativePath ?? "config.json"). Edit that file to change them."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundStyle(.secondary)
            }
        }
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
            ForEach(edited.actions.indices, id: \.self) { i in
                SupermuxProjectActionEditorRow(
                    action: $edited.actions[i],
                    onDelete: { edited.actions.remove(at: i) }
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

    /// Probes the project files for a logo and updates the preview. Detection
    /// runs off the main actor; the `NSImage` is built on it.
    private func detectIcon() async {
        let rootPath = edited.rootPath
        let resolver = SupermuxProjectIconResolver()
        let url = await Task.detached { resolver.resolve(rootPath: rootPath) }.value
        guard let url else {
            detectedIcon = nil
            detectedIconRelativePath = nil
            return
        }
        detectedIcon = NSImage(contentsOf: url)
        let root = (rootPath as NSString).expandingTildeInPath
        detectedIconRelativePath = url.path.hasPrefix(root + "/")
            ? String(url.path.dropFirst(root.count + 1))
            : url.lastPathComponent
    }

    /// Detects whether a repo-shipped `config.json` manages this project and, if
    /// so, mirrors its live values into the (read-only) script/run/action fields
    /// so the editor always reflects the file's current contents. File I/O runs
    /// off the main actor.
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
            return
        }
        configRelativePath = resolved.path
        setupCommandsInput = config.setup.joined(separator: "\n")
        teardownCommandsInput = config.teardown.joined(separator: "\n")
        runCommandsInput = config.run.joined(separator: "\n")
        edited.actions = edited.applying(config).actions
    }

    private func save() {
        var project = edited
        project.name = trimmedName
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
        // Run/setup/teardown/actions are owned by config.json when one is
        // present; leave the config-derived values (already on `edited`) intact.
        if !isConfigManaged {
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
        model.updateProject(project)
        dismiss()
    }

    /// Stores a setup/teardown editor's text as a single multi-line script entry
    /// (internal newlines preserved), unlike run commands which split per line.
    private static func scriptEntries(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
