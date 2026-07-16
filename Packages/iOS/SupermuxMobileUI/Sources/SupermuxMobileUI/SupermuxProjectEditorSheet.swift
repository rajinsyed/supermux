public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The mobile project editor — the phone counterpart of the desktop's
/// `SupermuxProjectEditorSheet`, driving `project.create` / `project.update`
/// / `project.delete` through the section's editing seam.
///
/// Create mode starts as a folder-path entry (`project.create` takes only
/// `root_path`; the Mac imports a repo-shipped `config.json` exactly like
/// the desktop add path) and flows into the full edit form on success, so a
/// fresh project can be customized immediately. Edit mode is the full form:
/// name, color palette, SF-symbol picker, default branch, worktrees folder,
/// run/setup/teardown editors, custom actions, and delete-with-confirm.
/// Config-managed fields (``SupermuxProjectDTO/configPath`` non-nil) render
/// disabled with the desktop's "managed by config.json" note, and the draft's
/// diff never patches them. Save sends ONLY changed keys; errors show inline
/// and the form stays editable.
public struct SupermuxProjectEditorSheet: View {
    /// Which flow the sheet starts in.
    public enum Mode {
        /// Register a new folder, then customize it.
        case create
        /// Edit an existing project (seeded from the freshest fetched DTO).
        case edit(SupermuxProjectDTO)
    }

    // Members used by the create-phase split in `+RootPicker.swift` are
    // internal, not private (same precedent as the detail screen's
    // `+RunSections.swift` split).
    let editing: SupermuxProjectEditingActions
    private let onDeleted: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The record being edited; `nil` while still in the create phase.
    @State private var original: SupermuxProjectDTO?
    @State private var draft: SupermuxProjectEditorDraft
    @State var rootPathInput = ""
    @State var isSaving = false
    @State var showingFolderPicker = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false

    /// Creates the sheet.
    /// - Parameters:
    ///   - mode: Create (folder entry first) or edit (full form).
    ///   - editing: The section's editor seam onto the live session.
    ///   - onDeleted: Called after a confirmed delete succeeds (e.g. so the
    ///     presenting detail screen can pop itself).
    public init(
        mode: Mode,
        editing: SupermuxProjectEditingActions,
        onDeleted: @escaping @MainActor () -> Void = {}
    ) {
        self.editing = editing
        self.onDeleted = onDeleted
        switch mode {
        case .create:
            _original = State(initialValue: nil)
            // Placeholder until the create round-trip seeds the real record.
            _draft = State(initialValue: SupermuxProjectEditorDraft(
                project: SupermuxProjectDTO(id: "", name: "", rootPath: "")
            ))
        case let .edit(project):
            _original = State(initialValue: project)
            _draft = State(initialValue: SupermuxProjectEditorDraft(project: project))
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                if original == nil {
                    createSections
                } else {
                    editSections
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(original == nil
                ? String(localized: "supermux.projectEditor.title.create", defaultValue: "Add Project", bundle: .module)
                : String(localized: "supermux.projectEditor.title.edit", defaultValue: "Edit Project", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(String(localized: "supermux.common.cancel", defaultValue: "Cancel", bundle: .module))
                    }
                    .disabled(isSaving || isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else if original == nil {
                            Text(String(
                                localized: "supermux.projectEditor.create",
                                defaultValue: "Add",
                                bundle: .module
                            ))
                        } else {
                            Text(String(localized: "supermux.common.save", defaultValue: "Save", bundle: .module))
                        }
                    }
                    .disabled(!canSave || isSaving || isDeleting)
                    .accessibilityIdentifier("SupermuxProjectEditorSaveButton")
                }
            }
        }
        .interactiveDismissDisabled(isSaving || isDeleting)
        .accessibilityIdentifier("SupermuxProjectEditorSheet")
    }

    // The create-phase sections (root-path field + Mac folder picker) live
    // in `SupermuxProjectEditorSheet+RootPicker.swift`.

    // MARK: - Edit phase

    @ViewBuilder
    private var editSections: some View {
        Section {
            TextField(
                String(localized: "supermux.projectEditor.name", defaultValue: "Name", bundle: .module),
                text: $draft.name
            )
            .disabled(isSaving)
            SupermuxColorPaletteRow(colorHex: $draft.colorHex)
                .disabled(isSaving)
            SupermuxIconSymbolPickerRow(iconSymbol: $draft.iconSymbol)
                .disabled(isSaving)
        }
        Section {
            TextField(
                String(
                    localized: "supermux.projectEditor.baseBranch",
                    defaultValue: "Default Base Branch",
                    bundle: .module
                ),
                text: $draft.defaultBranch
            )
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(isSaving)
            TextField(
                String(
                    localized: "supermux.projectEditor.worktreesFolder",
                    defaultValue: "Worktrees Folder",
                    bundle: .module
                ),
                text: $draft.worktreesDirName,
                prompt: Text(verbatim: ".worktrees")
            )
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(isSaving)
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.baseBranch.help",
                defaultValue: "New worktrees branch from this; empty uses HEAD.",
                bundle: .module
            ))
        }
        if let configPath = original?.configPath {
            Section {
                Label {
                    Text(String(
                        localized: "supermux.projectEditor.configManaged",
                        defaultValue: "Run, setup, teardown, and actions are managed by \(configPath). Edit that file on your Mac to change them.",
                        bundle: .module
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section {
            commandEditor(text: $draft.runCommandsText)
        } header: {
            Text(String(
                localized: "supermux.projectEditor.runCommands",
                defaultValue: "Run Commands",
                bundle: .module
            ))
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.runCommands.help",
                defaultValue: "One command per line; started and stopped with the Run action.",
                bundle: .module
            ))
        }
        .disabled(draft.isConfigManaged || isSaving)
        Section {
            commandEditor(text: $draft.setupScriptText)
        } header: {
            Text(String(
                localized: "supermux.projectEditor.setupScript",
                defaultValue: "Setup Script",
                bundle: .module
            ))
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.setupScript.help",
                defaultValue: "Runs in a new worktree right after it is created. $SUPERSET_ROOT_PATH points at the main checkout.",
                bundle: .module
            ))
        }
        .disabled(draft.isConfigManaged || isSaving)
        Section {
            commandEditor(text: $draft.teardownScriptText)
        } header: {
            Text(String(
                localized: "supermux.projectEditor.teardownScript",
                defaultValue: "Teardown Script",
                bundle: .module
            ))
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.teardownScript.help",
                defaultValue: "Runs in a worktree right before it is removed (cleanup).",
                bundle: .module
            ))
        }
        .disabled(draft.isConfigManaged || isSaving)
        actionsSection
            .disabled(draft.isConfigManaged || isSaving)
        Section {
            LabeledContent {
                Text(original?.rootPath ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text(String(
                    localized: "supermux.projectEditor.location",
                    defaultValue: "Location",
                    bundle: .module
                ))
            }
        }
        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                if isDeleting {
                    ProgressView()
                } else {
                    Text(String(
                        localized: "supermux.projectEditor.delete",
                        defaultValue: "Delete Project…",
                        bundle: .module
                    ))
                }
            }
            .disabled(isSaving || isDeleting)
            .accessibilityIdentifier("SupermuxProjectEditorDeleteButton")
            .confirmationDialog(
                String(
                    localized: "supermux.projectEditor.delete.confirm.title",
                    defaultValue: "Delete project “\(original?.name ?? "")”?",
                    bundle: .module
                ),
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(role: .destructive, action: deleteProject) {
                    Text(String(
                        localized: "supermux.projectEditor.delete.confirm.action",
                        defaultValue: "Delete",
                        bundle: .module
                    ))
                }
            } message: {
                Text(String(
                    localized: "supermux.projectEditor.delete.confirm.message",
                    defaultValue: "The folder and its worktrees stay on your Mac; only the project registration is removed.",
                    bundle: .module
                ))
            }
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach($draft.actions, id: \.id) { $action in
                SupermuxActionEditorRow(
                    action: $action,
                    onDelete: { [id = action.id] in
                        draft.actions.removeAll { $0.id == id }
                    }
                )
            }
            Button {
                draft.actions.append(SupermuxProjectEditorDraft.newAction())
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.projectEditor.addAction",
                        defaultValue: "Add Action",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "plus")
                }
            }
        } header: {
            Text(String(
                localized: "supermux.projectEditor.actions",
                defaultValue: "Actions",
                bundle: .module
            ))
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.actions.help",
                defaultValue: "Launch a command in a new workspace terminal.",
                bundle: .module
            ))
        }
    }

    private func commandEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13, design: .monospaced))
            .frame(minHeight: 64)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    // MARK: - Derived state

    private var canSave: Bool {
        if original == nil {
            return !rootPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func save() {
        guard !isSaving else { return }
        if let original {
            saveEdits(to: original)
        } else {
            createProject()
        }
    }

    /// `project.create`, then flows into the edit form seeded from the
    /// returned record so the fresh project can be customized immediately.
    private func createProject() {
        let rootPath = rootPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let created = try await editing.createProject(rootPath)
                original = created
                draft = SupermuxProjectEditorDraft(project: created)
            } catch {
                errorMessage = SupermuxEditorErrorText.message(for: error)
            }
        }
    }

    /// `project.update` with the draft's present-key diff; an unchanged form
    /// just dismisses without a request.
    private func saveEdits(to original: SupermuxProjectDTO) {
        let patch = draft.patch(from: original)
        guard !patch.isEmpty else {
            dismiss()
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await editing.updateProject(original.id, patch)
                dismiss()
            } catch {
                errorMessage = SupermuxEditorErrorText.message(for: error)
                isSaving = false
            }
        }
    }

    /// `project.delete` after the confirm dialog; pops the presenter through
    /// `onDeleted` on success.
    private func deleteProject() {
        guard let original, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await editing.deleteProject(original.id)
                dismiss()
                onDeleted()
            } catch {
                errorMessage = SupermuxEditorErrorText.message(for: error)
                isDeleting = false
            }
        }
    }
}
