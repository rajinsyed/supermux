public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The mobile terminal-preset editor — the phone counterpart of the
/// desktop's `SupermuxPresetEditorSheet` rows, driving `preset.create` /
/// `preset.update` / `preset.delete` through the section's editing seam.
///
/// One preset per sheet: name, command, SF-symbol picker, and color palette.
/// Create mode keeps Save disabled until name AND command are non-blank (the
/// Mac refuses an unlaunchable chip — the desktop's "keep the row local until
/// launchable" semantics); edit mode saves a present-key diff patch and
/// offers delete-with-confirm. Errors show inline and the form stays
/// editable.
///
/// There is no preset READ RPC yet (m4 ships the launcher), so this sheet is
/// presented by whichever surface owns preset records — it never lists them.
public struct SupermuxPresetEditorSheet: View {
    /// Which flow the sheet runs.
    public enum Mode {
        /// Create a new preset.
        case create
        /// Edit an existing preset (seeded from its DTO).
        case edit(SupermuxTerminalPresetDTO)
    }

    private let mode: Mode
    private let editing: SupermuxProjectEditingActions
    private let onSaved: @MainActor (SupermuxTerminalPresetDTO) -> Void
    private let onDeleted: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SupermuxPresetDraft
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false

    /// Creates the sheet.
    /// - Parameters:
    ///   - mode: Create or edit.
    ///   - editing: The section's editor seam onto the live session.
    ///   - onSaved: Called with the Mac's returned record after a successful
    ///     create/update (the presenter keeps its own preset list current).
    ///   - onDeleted: Called after a confirmed delete succeeds.
    public init(
        mode: Mode,
        editing: SupermuxProjectEditingActions,
        onSaved: @escaping @MainActor (SupermuxTerminalPresetDTO) -> Void = { _ in },
        onDeleted: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.editing = editing
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        switch mode {
        case .create:
            _draft = State(initialValue: SupermuxPresetDraft())
        case let .edit(preset):
            _draft = State(initialValue: SupermuxPresetDraft(preset: preset))
        }
    }

    private var originalPreset: SupermuxTerminalPresetDTO? {
        if case let .edit(preset) = mode { return preset }
        return nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(
                            localized: "supermux.presetEditor.namePrompt",
                            defaultValue: "Name",
                            bundle: .module
                        ),
                        text: $draft.name
                    )
                    .disabled(isSaving)
                    TextField(
                        String(
                            localized: "supermux.presetEditor.commandPrompt",
                            defaultValue: "Command",
                            bundle: .module
                        ),
                        text: $draft.command
                    )
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(isSaving)
                } footer: {
                    Text(String(
                        localized: "supermux.presetEditor.command.help",
                        defaultValue: "Runs in a new terminal on your Mac when the preset is launched.",
                        bundle: .module
                    ))
                }
                Section {
                    SupermuxIconSymbolPickerRow(iconSymbol: $draft.iconSymbol)
                        .disabled(isSaving)
                    SupermuxColorPaletteRow(colorHex: $draft.colorHex)
                        .disabled(isSaving)
                }
                if originalPreset != nil {
                    deleteSection
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(originalPreset == nil
                ? String(localized: "supermux.presetEditor.title.create", defaultValue: "New Preset", bundle: .module)
                : String(localized: "supermux.presetEditor.title.edit", defaultValue: "Edit Preset", bundle: .module))
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
                        } else {
                            Text(String(localized: "supermux.common.save", defaultValue: "Save", bundle: .module))
                        }
                    }
                    .disabled(!draft.canSave || isSaving || isDeleting)
                    .accessibilityIdentifier("SupermuxPresetEditorSaveButton")
                }
            }
        }
        .interactiveDismissDisabled(isSaving || isDeleting)
        .accessibilityIdentifier("SupermuxPresetEditorSheet")
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                if isDeleting {
                    ProgressView()
                } else {
                    Text(String(
                        localized: "supermux.presetEditor.delete",
                        defaultValue: "Delete Preset…",
                        bundle: .module
                    ))
                }
            }
            .disabled(isSaving || isDeleting)
            .confirmationDialog(
                String(
                    localized: "supermux.presetEditor.delete.confirm.title",
                    defaultValue: "Delete preset “\(originalPreset?.name ?? "")”?",
                    bundle: .module
                ),
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(role: .destructive, action: deletePreset) {
                    Text(String(
                        localized: "supermux.presetEditor.delete.confirm.action",
                        defaultValue: "Delete",
                        bundle: .module
                    ))
                }
            } message: {
                Text(String(
                    localized: "supermux.presetEditor.delete.confirm.message",
                    defaultValue: "This removes the preset from the bar on your Mac.",
                    bundle: .module
                ))
            }
        }
    }

    // MARK: - Actions

    /// Create sends the flat `preset.create` params; edit sends the
    /// present-key `preset.update` patch (an unchanged form just dismisses).
    private func save() {
        guard !isSaving else { return }
        if let original = originalPreset {
            let patch = draft.patch(from: original)
            guard !patch.isEmpty else {
                dismiss()
                return
            }
            run {
                let updated = try await editing.updatePreset(original.id, patch)
                onSaved(updated)
            }
        } else {
            guard let request = draft.createRequest() else { return }
            run {
                let created = try await editing.createPreset(request)
                onSaved(created)
            }
        }
    }

    private func deletePreset() {
        guard let original = originalPreset, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await editing.deletePreset(original.id)
                dismiss()
                onDeleted()
            } catch {
                errorMessage = SupermuxEditorErrorText.message(for: error)
                isDeleting = false
            }
        }
    }

    /// Shared save plumbing: spinner on, run the RPC, dismiss on success,
    /// inline error (form stays editable) on failure.
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await operation()
                dismiss()
            } catch {
                errorMessage = SupermuxEditorErrorText.message(for: error)
                isSaving = false
            }
        }
    }
}
