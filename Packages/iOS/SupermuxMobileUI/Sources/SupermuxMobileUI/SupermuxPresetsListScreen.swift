public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The phone's global terminal-presets manager: the same one-click launcher
/// chips the desktop bar shows above EVERY workspace's terminal (presets are
/// global in the Mac's projects file, never scoped per project — this screen
/// mirrors that truth by living at the Projects section's level).
///
/// Tapping a preset opens ``SupermuxPresetEditorSheet`` in edit mode
/// (rename, command, icon, color, delete-with-confirm); the toolbar "+"
/// opens it in create mode. The list itself renders from the section
/// snapshot, which the store refreshes after every preset write and every
/// `supermux.projects.updated` poke — so desktop edits appear here live.
public struct SupermuxPresetsListScreen: View {
    private let presets: [SupermuxTerminalPresetDTO]
    private let editing: SupermuxProjectEditingActions

    @State private var showingCreateSheet = false
    /// The preset the tapped row seeded the editor with; `nil` while closed.
    @State private var editingPreset: SupermuxTerminalPresetDTO?

    /// Creates the screen.
    /// - Parameters:
    ///   - presets: The global presets, in the Mac bar's order (a value
    ///     snapshot; the pushing view re-evaluates it as the store refetches).
    ///   - editing: The editor seam onto the live session.
    public init(presets: [SupermuxTerminalPresetDTO], editing: SupermuxProjectEditingActions) {
        self.presets = presets
        self.editing = editing
    }

    public var body: some View {
        List {
            Section {
                if presets.isEmpty {
                    Text(String(
                        localized: "supermux.presets.empty",
                        defaultValue: "No presets yet",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(presets, id: \.id) { preset in
                        Button {
                            editingPreset = preset
                        } label: {
                            SupermuxPresetListRow(preset: preset)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("SupermuxPresetRow-\(preset.id)")
                    }
                }
            } footer: {
                Text(String(
                    localized: "supermux.presets.footer.global",
                    defaultValue: "Presets are shared across your whole Mac — the same set appears in every workspace's terminal bar.",
                    bundle: .module
                ))
            }
        }
        .navigationTitle(String(
            localized: "supermux.presets.title",
            defaultValue: "Presets",
            bundle: .module
        ))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("SupermuxPresetsList")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(
                    localized: "supermux.presets.add",
                    defaultValue: "Add Preset",
                    bundle: .module
                ))
                .accessibilityIdentifier("SupermuxPresetsAddButton")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            SupermuxPresetEditorSheet(mode: .create, editing: editing)
        }
        .sheet(
            isPresented: Binding(
                get: { editingPreset != nil },
                set: { if !$0 { editingPreset = nil } }
            )
        ) {
            if let editingPreset {
                SupermuxPresetEditorSheet(mode: .edit(editingPreset), editing: editing)
            }
        }
    }
}

/// One preset row: the chip glyph tinted by the preset's accent, the label,
/// and the command in monospace — a vertical rendering of the desktop chip.
struct SupermuxPresetListRow: View {
    let preset: SupermuxTerminalPresetDTO

    private var accent: Color {
        SupermuxProjectStyle.color(fromHex: preset.colorHex) ?? .secondary
    }

    /// The chip glyph, falling back to the desktop's neutral terminal symbol.
    private var symbol: String {
        let trimmed = preset.iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "terminal" : trimmed
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.18))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accent)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(preset.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
