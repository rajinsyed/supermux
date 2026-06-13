public import SwiftUI

/// A sheet for managing the global terminal presets shown in the bar.
///
/// The preset list is copied into local state on init; nothing is persisted
/// until the user confirms with Done, which routes the edited list through
/// ``SupermuxProjectsModel/setPresets(_:)``. Rows support inline name / command
/// / icon / color edits, deletion, and drag-reordering; an empty name or
/// command is dropped on save.
public struct SupermuxPresetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let model: SupermuxProjectsModel
    @State private var edited: [SupermuxTerminalPreset]

    /// Creates the editor.
    /// - Parameter model: Shared model that receives the saved preset list.
    public init(model: SupermuxProjectsModel) {
        self.model = model
        _edited = State(initialValue: model.presets)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "supermux.presetEditor.title", defaultValue: "Terminal Presets"))
                .font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 2)
            Text(String(
                localized: "supermux.presetEditor.subtitle",
                defaultValue: "Shown in the bar above every terminal. Click one to run it in a new tab."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            List {
                ForEach($edited) { $preset in
                    SupermuxPresetEditorRow(preset: $preset) {
                        edited.removeAll { $0.id == preset.id }
                    }
                }
                .onMove { indices, destination in
                    edited.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)

            HStack {
                Button {
                    edited.append(SupermuxTerminalPreset(name: "", command: ""))
                } label: {
                    Label(
                        String(localized: "supermux.presetEditor.add", defaultValue: "Add Preset"),
                        systemImage: "plus"
                    )
                }
                Spacer()
                Button {
                    edited = SupermuxTerminalPreset.defaults
                } label: {
                    Label(
                        String(localized: "supermux.presetEditor.reset", defaultValue: "Reset to Defaults"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()
            buttonBar
        }
        .frame(width: 480, height: 460)
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "supermux.presetEditor.done", defaultValue: "Done")) {
                save()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func save() {
        let cleaned = edited
            .map { preset -> SupermuxTerminalPreset in
                var trimmed = preset
                trimmed.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                trimmed.command = preset.command.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }
            .filter { $0.isLaunchable }
        model.setPresets(cleaned)
        dismiss()
    }
}

/// A single editable preset row: color swatch, icon, name, command, delete.
///
/// Binds a ``SupermuxTerminalPreset`` value in place and exposes a delete
/// callback so the parent editor can remove it from the list.
private struct SupermuxPresetEditorRow: View {
    @Binding var preset: SupermuxTerminalPreset
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            colorMenu
            TextField(
                String(localized: "supermux.presetEditor.iconPrompt", defaultValue: "Icon"),
                text: iconBinding,
                prompt: Text(String(localized: "supermux.presetEditor.iconPrompt", defaultValue: "Icon"))
            )
            .frame(width: 56)
            .autocorrectionDisabled()
            TextField(
                String(localized: "supermux.presetEditor.namePrompt", defaultValue: "Name"),
                text: $preset.name,
                prompt: Text(String(localized: "supermux.presetEditor.namePrompt", defaultValue: "Name"))
            )
            .frame(width: 96)
            TextField(
                String(localized: "supermux.presetEditor.commandPrompt", defaultValue: "Command"),
                text: $preset.command,
                prompt: Text(String(localized: "supermux.presetEditor.commandPrompt", defaultValue: "Command"))
            )
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.presetEditor.delete", defaultValue: "Remove Preset"))
        }
    }

    /// A compact color picker: the preset's icon tinted with the chosen accent,
    /// opening the standard palette plus a "No Color" option.
    private var colorMenu: some View {
        let accent = SupermuxProjectColor.color(fromHex: preset.colorHex)
        return Menu {
            Button {
                preset.colorHex = nil
            } label: {
                Label(
                    String(localized: "supermux.presetEditor.noColor", defaultValue: "No Color"),
                    systemImage: "circle.slash"
                )
            }
            ForEach(SupermuxProjectColor.palette) { entry in
                Button {
                    preset.colorHex = entry.hex
                } label: {
                    Label(entry.name, systemImage: "circle.fill")
                }
            }
        } label: {
            Image(systemName: preset.resolvedIconSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent ?? .secondary)
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "supermux.presetEditor.color", defaultValue: "Color"))
    }

    private var iconBinding: Binding<String> {
        Binding(
            get: { preset.iconSymbol ?? "" },
            set: { preset.iconSymbol = $0.isEmpty ? nil : $0 }
        )
    }
}
