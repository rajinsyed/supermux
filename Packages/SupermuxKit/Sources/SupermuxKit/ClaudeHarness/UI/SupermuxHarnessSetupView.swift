import AppKit
import SwiftUI
import SupermuxClaudeHarness
import SupermuxZeronUI

/// The empty-panel state, in zeron chrome: the shared empty canvas over the
/// directory, launcher and model pickers.
///
/// ── What this screen must keep doing ──
///
/// The **launcher selector is user-critical and is preserved in full**: plain
/// `claude`, `ccx`, and a custom executable path. `ccx` is the user's own Claude
/// Code setup — a build that cannot select it is a broken build — and the custom
/// path row is the escape hatch when neither is on `PATH`. The resume
/// affordance is likewise kept: a restored panel arrives here with a persisted
/// provider session id and nothing else, and offering "Resume" beside "Start"
/// is the whole reason a panel survives a relaunch.
///
/// ── The zeron half ──
///
/// The layout is zeron's onboarding canvas (`shell.rs:4435–4481`): a centered
/// column under a `FADE_IN` with a 16 pt MEDIUM title, a 13 pt muted subtitle,
/// and the primary button. The form sits between the subtitle and the buttons,
/// built from `menu_heading` labels and the picker card's own row primitives, so
/// nothing on this screen invents chrome the design system does not have.
///
/// The old build styled this with `SupermuxHarnessTokens` and AppKit `Picker`
/// menus. Both are gone: the token table is superseded by `SupermuxZeronMetrics`
/// and a system pop-up menu cannot be themed to zeron's rows.
struct SupermuxHarnessSetupView: View {
    let workingDirectory: String
    let launcher: ClaudeLauncher?
    let availability: [ClaudeLauncher.Kind: Bool]
    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let resumableSessionID: String?
    let errorMessage: String?
    let theme: SupermuxZeronTheme
    let onPickDirectory: (String) -> Void
    let onSelectLauncher: (ClaudeLauncher.Kind, String?) -> Void
    let onSelectModel: (String?) -> Void
    let onStart: (Bool) -> Void

    @State private var customPath = ""
    @State private var showsModelPicker = false
    @State private var pickerState = SupermuxZeronPickerState()
    /// The `note_trigger_press` / `take_press_was_open` guard, shared by this
    /// screen's triggers so a click on one switches menus rather than being
    /// swallowed.
    @State private var pressGuard = SupermuxZeronMenuPressGuard()

    private typealias T = SupermuxZeronMetrics.Theme

    var body: some View {
        ZStack {
            SupermuxZeronGridBackdrop(theme: theme)
            SupermuxZeronEmptyCanvas(
                kind: .onboarding,
                theme: theme,
                title: Self.title,
                subtitle: workingDirectory
            ) {
                // zeron paints its own logo mark here. This port ships no brand
                // marks (plan §6.4), so the watermark slot stays empty and the
                // geometry below it is unchanged.
                EmptyView()
            }
            .overlay {
                form
            }
        }
    }

    /// The form, centered in the canvas.
    ///
    /// Overlaid rather than injected into the canvas's column so the canvas
    /// keeps its exact zeron offsets (+24 title, +6 subtitle, +20 button) and
    /// this port does not silently redefine them.
    private var form: some View {
        VStack(alignment: .leading, spacing: T.spaceMD) {
            Spacer(minLength: 0)
            directoryRow
            launcherRow
            if launcher?.kind == .custom || !(availability[.claude] ?? false) {
                customPathRow
            }
            modelRow

            if let errorMessage {
                Text(errorMessage)
                    .font(SupermuxZeronFonts.sans(size: 12))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: T.spaceSM) {
                if resumableSessionID != nil {
                    SupermuxZeronSecondaryButton(theme: theme, label: Self.resume) {
                        onStart(true)
                    }
                    .disabled(launcher == nil)
                    .opacity(launcher == nil ? 0.4 : 1)
                }
                SupermuxZeronPrimaryButton(theme: theme, label: Self.start) {
                    onStart(false)
                }
                .disabled(launcher == nil)
                .opacity(launcher == nil ? 0.4 : 1)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, T.spaceXS)
        }
        .padding(T.spaceLG)
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, 120)
    }

    // MARK: - Directory

    private var directoryRow: some View {
        VStack(alignment: .leading, spacing: T.spaceXS) {
            heading(Self.workingDirectoryLabel)
            HStack(spacing: T.spaceSM) {
                Text(workingDirectory)
                    .font(SupermuxZeronFonts.mono(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    // Head truncation keeps the leaf directory visible, which is
                    // the part that identifies the project.
                    .truncationMode(.head)
                Spacer(minLength: 0)
                SupermuxZeronSecondaryButton(theme: theme, label: Self.choose) {
                    presentDirectoryPicker()
                }
            }
        }
    }

    // MARK: - Launcher

    /// **User-critical.** Every launcher stays selectable; `ccx` is the user's
    /// own Claude Code setup.
    private var launcherRow: some View {
        VStack(alignment: .leading, spacing: T.spaceXS) {
            heading(Self.launchWithLabel)
            HStack(spacing: SupermuxZeronMetrics.Composer.chipGap) {
                launcherChip(.claude)
                launcherChip(.ccx)
                launcherChip(.custom)
            }
        }
    }

    /// One launcher as a zeron trigger chip: 32 pt, radius 8, px 10.
    ///
    /// An unavailable launcher dims to 0.35 — the rail's locked treatment —
    /// rather than vanishing, so "not on your PATH" stays discoverable instead
    /// of looking like the option was never offered.
    private func launcherChip(_ kind: ClaudeLauncher.Kind) -> some View {
        let isAvailable = availability[kind] ?? (kind == .custom)
        let isSelected = launcher?.kind == kind
        return SupermuxZeronTriggerChip(
            theme: theme,
            label: Self.launcherName(kind),
            isSet: isSelected,
            isOpen: isSelected,
            action: { onSelectLauncher(kind, kind == .custom ? customPath : nil) }
        )
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.35)
        .help(isAvailable ? Self.launcherName(kind) : Self.launcherUnavailable)
        .accessibilityLabel(Self.launcherName(kind))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var customPathRow: some View {
        VStack(alignment: .leading, spacing: T.spaceXS) {
            heading(Self.executablePathLabel)
            TextField(Self.executablePathPlaceholder, text: $customPath)
                .textFieldStyle(.plain)
                .font(SupermuxZeronFonts.mono(size: 12))
                .foregroundStyle(theme.text)
                .padding(.horizontal, SupermuxZeronMetrics.Pickers.searchPadX)
                .padding(.vertical, T.spaceSM)
                .background(
                    RoundedRectangle(cornerRadius: T.controlRadius, style: .continuous)
                        .fill(theme.inputGlassBG())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: T.controlRadius, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .onSubmit { onSelectLauncher(.custom, customPath) }
        }
    }

    // MARK: - Model

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: T.spaceXS) {
            heading(Self.modelLabel)
            SupermuxZeronTriggerChip(
                theme: theme,
                label: selectedModelLabel,
                icon: .altArrowDown,
                isSet: selectedModel != nil,
                isOpen: showsModelPicker,
                action: {
                    // The double-toggle guard (`take_press_was_open`,
                    // `pickers.rs:766–771`). The card's outside-press dismissal
                    // fires on the SAME press that will produce this click, so
                    // by click time the menu already reads closed and a naive
                    // toggle reopens it. The press left a note; consume it.
                    if pressGuard.takePressWasOpen(identity: "setup-model") {
                        showsModelPicker = false
                        return
                    }
                    showsModelPicker.toggle()
                }
            )
            .supermuxZeronAnchoredMenu(
                isPresented: $showsModelPicker,
                identity: "setup-model",
                pressGuard: pressGuard
            ) {
                SupermuxZeronPickerCard(
                    theme: theme,
                    rows: modelRows,
                    selectedID: selectedModel,
                    state: $pickerState,
                    onSelect: { row in
                        // The sentinel row clears the selection back to the
                        // CLI's own default, which is a real choice here: a
                        // fresh panel has no live model list, only aliases.
                        onSelectModel(row.id == Self.defaultRowID ? nil : row.id)
                        showsModelPicker = false
                    },
                    onDismiss: { showsModelPicker = false }
                )
            }
        }
    }

    /// The model list cannot be fetched before the CLI is running, so a fresh
    /// panel offers the CLI's stable aliases; a live list (from a previous
    /// session in this process) replaces them.
    private var modelRows: [SupermuxZeronPickerRow] {
        var rows = [
            SupermuxZeronPickerRow(
                id: Self.defaultRowID,
                label: Self.defaultModel,
                subline: Self.defaultModelSubline
            )
        ]
        if models.isEmpty {
            rows += Self.aliasRows
        } else {
            rows += models.map { model in
                SupermuxZeronPickerRow(
                    id: model.value,
                    label: model.displayName ?? model.value,
                    subline: model.description?.isEmpty == false
                        ? (model.description ?? model.value)
                        : model.value
                )
            }
        }
        // A persisted selection outside the list must stay representable, or the
        // picker silently deselects it.
        if let selectedModel, !rows.contains(where: { $0.id == selectedModel }) {
            rows.append(
                SupermuxZeronPickerRow(
                    id: selectedModel,
                    label: selectedModel,
                    subline: Self.persistedSelectionSubline
                )
            )
        }
        return rows
    }

    private var selectedModelLabel: String {
        guard let selectedModel else { return Self.defaultModel }
        return modelRows.first { $0.id == selectedModel }?.label ?? selectedModel
    }

    /// The sentinel id for "let the CLI choose". Not a model value, and
    /// deliberately not empty — an empty id would collide with a real one.
    private static let defaultRowID = "__supermux.default__"

    private static var aliasRows: [SupermuxZeronPickerRow] {
        [
            SupermuxZeronPickerRow(
                id: "sonnet",
                label: String(
                    localized: "supermux.harness.model.alias.sonnet",
                    defaultValue: "Sonnet (alias)"
                ),
                subline: Self.aliasSubline
            ),
            SupermuxZeronPickerRow(
                id: "opus",
                label: String(
                    localized: "supermux.harness.model.alias.opus",
                    defaultValue: "Opus (alias)"
                ),
                subline: Self.aliasSubline
            ),
            SupermuxZeronPickerRow(
                id: "haiku",
                label: String(
                    localized: "supermux.harness.model.alias.haiku",
                    defaultValue: "Haiku (alias)"
                ),
                subline: Self.aliasSubline
            ),
        ]
    }

    // MARK: - Chrome

    /// `menu_heading`: 10 pt MEDIUM, uppercase, `textMuted @ 0.6`, tracked 1.0.
    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(
                SupermuxZeronFonts.sans(
                    size: SupermuxZeronMetrics.Pickers.menuHeadingTextSize,
                    weight: .medium
                )
            )
            .tracking(SupermuxZeronMetrics.Pickers.menuHeadingTracking)
            .foregroundStyle(
                theme.textMuted.opacity(SupermuxZeronMetrics.Pickers.menuHeadingTextAlpha)
            )
    }

    /// Directory picker. Modal panel, so it must not run inside `body`.
    private func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        panel.prompt = Self.usePrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPickDirectory(url.path)
    }

    // MARK: - Strings

    static func launcherName(_ kind: ClaudeLauncher.Kind) -> String {
        switch kind {
        case .claude:
            String(localized: "supermux.harness.launcher.claude.name", defaultValue: "claude")
        case .ccx:
            String(localized: "supermux.harness.launcher.ccx.name", defaultValue: "ccx")
        case .custom:
            String(localized: "supermux.harness.launcher.custom.name", defaultValue: "Custom…")
        }
    }

    private static var title: String {
        String(
            localized: "supermux.harness.session.new",
            defaultValue: "New Claude Code session"
        )
    }

    private static var start: String {
        String(localized: "supermux.harness.session.start", defaultValue: "Start")
    }

    private static var resume: String {
        String(
            localized: "supermux.harness.session.resume",
            defaultValue: "Resume previous session"
        )
    }

    private static var choose: String {
        String(localized: "supermux.harness.session.pick", defaultValue: "Choose…")
    }

    private static var usePrompt: String {
        String(localized: "supermux.harness.session.pickPrompt", defaultValue: "Use Folder")
    }

    private static var workingDirectoryLabel: String {
        String(
            localized: "supermux.harness.session.workingDirectory",
            defaultValue: "Working directory"
        )
    }

    private static var launchWithLabel: String {
        String(
            localized: "supermux.harness.launcher.picker.title",
            defaultValue: "Launch with"
        )
    }

    private static var launcherUnavailable: String {
        String(
            localized: "supermux.harness.launcher.unavailable",
            defaultValue: "Not found on your PATH."
        )
    }

    private static var executablePathLabel: String {
        String(
            localized: "supermux.harness.launcher.customPath.label",
            defaultValue: "Executable path"
        )
    }

    private static var executablePathPlaceholder: String {
        String(
            localized: "supermux.harness.launcher.customPath.placeholder",
            defaultValue: "/usr/local/bin/claude"
        )
    }

    private static var modelLabel: String {
        String(localized: "supermux.harness.model.picker.title", defaultValue: "Model")
    }

    private static var defaultModel: String {
        String(
            localized: "supermux.harness.model.default",
            defaultValue: "Claude Code default"
        )
    }

    private static var defaultModelSubline: String {
        String(
            localized: "supermux.harness.model.default.subline",
            defaultValue: "Whatever the CLI is configured for"
        )
    }

    private static var aliasSubline: String {
        String(
            localized: "supermux.harness.model.alias.subline",
            defaultValue: "Resolved by the CLI at launch"
        )
    }

    private static var persistedSelectionSubline: String {
        String(
            localized: "supermux.harness.model.persisted.subline",
            defaultValue: "Saved for this panel"
        )
    }
}
