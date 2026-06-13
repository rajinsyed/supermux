public import SwiftUI

/// The horizontal "terminal presets" bar rendered above each workspace's
/// terminal area, mirroring piggycode.
///
/// Layout: a leading manage (gear) button, a scrollable row of preset chips
/// (one-click agent launchers), and a trailing Run / Stop button with a
/// chevron menu. Clicking a chip opens the preset's command in a fresh terminal
/// tab (the host supplies that via `onLaunch`); the Run button toggles the
/// active workspace's project run command (the ⌘G action), supplied via
/// `onToggleRun`.
///
/// The bar owns the `@Bindable` model and presents the editor sheet itself
/// (matching ``SupermuxProjectsSectionView``); chips below the `ForEach`
/// receive only immutable values plus a launch closure, never the store.
public struct SupermuxPresetsBarView: View {
    @Bindable private var model: SupermuxProjectsModel
    private let isRunning: Bool
    private let runShortcutHint: String
    private let onLaunch: (SupermuxTerminalPreset) -> Void
    private let onToggleRun: () -> Void

    @State private var showingEditor = false
    @State private var isRunHovering = false

    /// Creates the bar.
    /// - Parameters:
    ///   - model: Shared model owning the global preset list.
    ///   - isRunning: Whether the workspace's run command is currently running,
    ///     for the Run / Stop label.
    ///   - runShortcutHint: Display string for the run shortcut (e.g. "⌘G"),
    ///     shown as a hint pill; empty hides the pill.
    ///   - onLaunch: Opens a preset's command in a new terminal tab.
    ///   - onToggleRun: Starts or stops the workspace run command.
    public init(
        model: SupermuxProjectsModel,
        isRunning: Bool,
        runShortcutHint: String,
        onLaunch: @escaping (SupermuxTerminalPreset) -> Void,
        onToggleRun: @escaping () -> Void
    ) {
        self.model = model
        self.isRunning = isRunning
        self.runShortcutHint = runShortcutHint
        self.onLaunch = onLaunch
        self.onToggleRun = onToggleRun
    }

    public var body: some View {
        HStack(spacing: 8) {
            manageButton
            Divider().frame(height: 14)
            presetChips
            Spacer(minLength: 6)
            runControl
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        // No fill: the window's own backing (host-layer terminal background,
        // including any translucency) shows through, so the bar blends with the
        // surrounding chrome instead of painting an opaque strip over it.
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
        .sheet(isPresented: $showingEditor) {
            SupermuxPresetEditorSheet(model: model)
        }
    }

    // MARK: - Pieces

    private var manageButton: some View {
        Button {
            showingEditor = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "supermux.presetsBar.manage.help", defaultValue: "Manage presets"))
        .accessibilityLabel(String(localized: "supermux.presetsBar.manage.help", defaultValue: "Manage presets"))
    }

    @ViewBuilder
    private var presetChips: some View {
        if model.presets.isEmpty {
            Button {
                showingEditor = true
            } label: {
                Label(
                    String(localized: "supermux.presetsBar.empty", defaultValue: "Add a preset"),
                    systemImage: "plus"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.presets) { preset in
                        SupermuxPresetChip(preset: preset) {
                            onLaunch(preset)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var runControl: some View {
        HStack(spacing: 0) {
            Button(action: onToggleRun) {
                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isRunning
                        ? String(localized: "supermux.presetsBar.stop", defaultValue: "Stop")
                        : String(localized: "supermux.presetsBar.run", defaultValue: "Run"))
                        .font(.system(size: 11, weight: .medium))
                    if !runShortcutHint.isEmpty {
                        Text(runShortcutHint)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(isRunning ? Color.red : Color.accentColor)
                .padding(.leading, 9)
                .padding(.trailing, 8)
                .frame(height: 22)
            }
            .buttonStyle(.plain)
            .help(String(localized: "supermux.presetsBar.run.help", defaultValue: "Start or stop the project run command"))

            Menu {
                Button {
                    showingEditor = true
                } label: {
                    Label(
                        String(localized: "supermux.presetsBar.editPresets", defaultValue: "Edit Presets…"),
                        systemImage: "slider.horizontal.3"
                    )
                }
                Button {
                    model.resetPresetsToDefaults()
                } label: {
                    Label(
                        String(localized: "supermux.presetsBar.resetDefaults", defaultValue: "Reset Presets to Defaults"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 7)
                    .padding(.leading, 2)
                    .frame(height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "supermux.presetsBar.more.help", defaultValue: "More preset options"))
        }
        .background(
            Color.secondary.opacity(isRunHovering ? 0.12 : 0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isRunHovering = $0 }
    }
}

/// A single tappable preset launcher in the bar. Receives an immutable preset
/// value and a launch closure only — never the store — per the list-subtree
/// snapshot-boundary rule.
private struct SupermuxPresetChip: View {
    let preset: SupermuxTerminalPreset
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        let accent = SupermuxProjectColor.color(fromHex: preset.colorHex)
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: preset.resolvedIconSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent ?? .secondary)
                Text(preset.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                (accent ?? Color.secondary).opacity(isHovering ? 0.18 : 0.0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(String(
            localized: "supermux.presetsBar.launch.help",
            defaultValue: "Open \(preset.name) in a new terminal tab"
        ))
        .accessibilityLabel(preset.name)
    }
}
