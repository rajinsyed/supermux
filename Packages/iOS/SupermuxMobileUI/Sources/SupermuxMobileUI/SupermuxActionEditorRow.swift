public import SupermuxMobileCore
import SupermuxMobileKit
public import SwiftUI

/// Maps editor-save errors onto user-facing text: the Kit's
/// `SupermuxMacUnavailableError` gets a localized message (it carries none of
/// its own), everything else surfaces the Mac's reported message verbatim
/// (e.g. `invalid_params` details like "root_path is not an existing folder").
enum SupermuxEditorErrorText {
    static func message(for error: any Error) -> String {
        if error is SupermuxMacUnavailableError {
            return String(
                localized: "supermux.editor.error.unavailable",
                defaultValue: "Not connected to a Mac.",
                bundle: .module
            )
        }
        return error.localizedDescription
    }
}

/// One editable custom-action row: name, command, and optional SF Symbol,
/// with a trailing remove button. Binds a plain DTO value inside the sheet's
/// `@State` draft — no store reference crosses the `Form` boundary.
struct SupermuxActionEditorRow: View {
    @Binding var action: SupermuxProjectActionDTO
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    String(
                        localized: "supermux.projectEditor.action.namePrompt",
                        defaultValue: "Name",
                        bundle: .module
                    ),
                    text: $action.name
                )
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(
                    localized: "supermux.projectEditor.action.remove",
                    defaultValue: "Remove Action",
                    bundle: .module
                ))
            }
            TextField(
                String(
                    localized: "supermux.projectEditor.action.commandPrompt",
                    defaultValue: "Command",
                    bundle: .module
                ),
                text: $action.command
            )
            .font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        }
        .padding(.vertical, 2)
    }
}
