import SwiftUI

/// A single editable row for a project's custom action / terminal preset.
///
/// Binds a ``SupermuxProjectAction`` value in place and exposes a delete
/// callback so the parent editor (``SupermuxProjectEditorSheet``) can remove it
/// from the project's list.
struct SupermuxProjectActionEditorRow: View {
    @Binding var action: SupermuxProjectAction
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: action.resolvedIconSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField(
                String(localized: "supermux.projectEditor.action.namePrompt", defaultValue: "Name"),
                text: $action.name,
                prompt: Text(String(
                    localized: "supermux.projectEditor.action.namePrompt",
                    defaultValue: "Name"
                ))
            )
            .frame(width: 96)
            TextField(
                String(localized: "supermux.projectEditor.action.commandPrompt", defaultValue: "Command"),
                text: $action.command,
                prompt: Text(String(
                    localized: "supermux.projectEditor.action.commandPrompt",
                    defaultValue: "Command"
                ))
            )
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            TextField(
                String(localized: "supermux.projectEditor.action.iconPrompt", defaultValue: "Icon"),
                text: iconBinding,
                prompt: Text(String(
                    localized: "supermux.projectEditor.action.iconPrompt",
                    defaultValue: "Icon"
                ))
            )
            .frame(width: 64)
            .autocorrectionDisabled()
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.projectEditor.action.delete", defaultValue: "Remove Action"))
        }
    }

    private var iconBinding: Binding<String> {
        Binding(
            get: { action.iconSymbol ?? "" },
            set: { action.iconSymbol = $0.isEmpty ? nil : $0 }
        )
    }
}
