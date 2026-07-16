import SwiftUI

/// The create-phase sections of ``SupermuxProjectEditorSheet``, split out of
/// the main file (same precedent as the detail screen's `+RunSections.swift`
/// split): the absolute-path text field plus the Mac folder picker.
///
/// The picker upgrades the M2 text field WITHOUT replacing it: the `files.*`
/// wire confines browsing to an existing `workspace_id`/`project_id` root,
/// so the picker can only reach folders inside projects already registered
/// on the Mac — any other location still goes through the text field. The
/// Browse affordance hides when the host lacks `supermux.files.v1` or no
/// project roots exist yet.
extension SupermuxProjectEditorSheet {
    /// The create-phase form: root-path entry + optional Browse picker.
    @ViewBuilder
    var createSections: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.projectEditor.rootPath",
                    defaultValue: "Folder path on your Mac",
                    bundle: .module
                ),
                text: $rootPathInput,
                prompt: Text(verbatim: "/Users/…/project")
            )
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(isSaving)
        } footer: {
            Text(String(
                localized: "supermux.projectEditor.rootPath.help",
                defaultValue: "Absolute path to an existing folder on your Mac. A repo-shipped config.json (run, setup, teardown, actions) is imported automatically.",
                bundle: .module
            ))
        }
        if let picking = editing.rootPathPicker, !picking.rootOptions().isEmpty {
            Section {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.projectEditor.rootPath.browse",
                            defaultValue: "Browse Project Folders…",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("SupermuxProjectEditorBrowseButton")
                .sheet(isPresented: $showingFolderPicker) {
                    SupermuxFolderPickerSheet(picking: picking) { pickedPath in
                        rootPathInput = pickedPath
                    }
                }
            } footer: {
                Text(String(
                    localized: "supermux.projectEditor.rootPath.browse.help",
                    defaultValue: "Browsing is limited to folders inside projects already registered on your Mac. For any other location, type the absolute path above.",
                    bundle: .module
                ))
            }
        }
    }
}
