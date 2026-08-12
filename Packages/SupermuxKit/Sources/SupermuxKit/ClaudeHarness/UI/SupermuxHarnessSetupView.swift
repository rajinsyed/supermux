import AppKit
import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// The empty-panel state: pick a directory, a launcher, and a model, then start.
///
/// It also carries the resume affordance, because a restored panel arrives here
/// with a persisted provider session id and nothing else — offering "Resume"
/// beside "Start" is the whole reason a panel survives a relaunch.
struct SupermuxHarnessSetupView: View {
    let workingDirectory: String
    let launcher: ClaudeLauncher?
    let availability: [ClaudeLauncher.Kind: Bool]
    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let resumableSessionID: String?
    let errorMessage: String?
    let theme: SupermuxHarnessTheme
    let onPickDirectory: (String) -> Void
    let onSelectLauncher: (ClaudeLauncher.Kind, String?) -> Void
    let onSelectModel: (String?) -> Void
    let onStart: (Bool) -> Void

    @State private var customPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing12) {
            Text(
                String(
                    localized: "supermux.harness.session.new",
                    defaultValue: "New Claude Code session"
                )
            )
            .cmuxFont(size: SupermuxHarnessTokens.title3, weight: .medium)
            .foregroundStyle(theme.text)

            directoryRow
            launcherRow
            if launcher?.kind == .custom || !(availability[.claude] ?? false) {
                customPathRow
            }
            modelRow

            if let errorMessage {
                Text(errorMessage)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: SupermuxHarnessTokens.spacing8) {
                if resumableSessionID != nil {
                    themedButton(
                        String(
                            localized: "supermux.harness.session.resume",
                            defaultValue: "Resume previous session"
                        ),
                        prominent: false
                    ) {
                        onStart(true)
                    }
                    .disabled(launcher == nil)
                }
                themedButton(
                    String(
                        localized: "supermux.harness.session.start",
                        defaultValue: "Start"
                    ),
                    prominent: true
                ) {
                    onStart(false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(launcher == nil)
            }
        }
        .padding(SupermuxHarnessTokens.spacing12 * 2)
        .frame(maxWidth: 460, alignment: .leading)
        // Centre the form column: without this the 460pt form hugs the
        // top-left of a wide panel with a large empty void beside it.
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private var directoryRow: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            label(
                String(
                    localized: "supermux.harness.session.workingDirectory",
                    defaultValue: "Working directory"
                )
            )
            HStack(spacing: SupermuxHarnessTokens.spacing6) {
                Text(workingDirectory)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote, design: .monospaced)
                    .foregroundStyle(theme.softText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                themedButton(
                    String(
                        localized: "supermux.harness.session.pick",
                        defaultValue: "Choose…"
                    ),
                    prominent: false
                ) {
                    presentDirectoryPicker()
                }
            }
        }
    }

    private var launcherRow: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            label(
                String(
                    localized: "supermux.harness.launcher.picker.title",
                    defaultValue: "Launch with"
                )
            )
            HStack(spacing: SupermuxHarnessTokens.spacing6) {
                launcherButton(kind: .claude, title: Self.launcherName(.claude))
                launcherButton(kind: .ccx, title: Self.launcherName(.ccx))
                launcherButton(kind: .custom, title: Self.launcherName(.custom))
            }
        }
    }

    private func launcherButton(kind: ClaudeLauncher.Kind, title: String) -> some View {
        let isAvailable = availability[kind] ?? (kind == .custom)
        let isSelected = launcher?.kind == kind
        return Button {
            onSelectLauncher(kind, kind == .custom ? customPath : nil)
        } label: {
            HStack(spacing: SupermuxHarnessTokens.spacing4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: SupermuxHarnessTokens.caption))
                Text(title)
                    .cmuxFont(size: SupermuxHarnessTokens.footnote)
            }
            .foregroundStyle(isAvailable ? theme.text : theme.mutedText)
            .padding(.horizontal, SupermuxHarnessTokens.spacing8)
            .padding(.vertical, SupermuxHarnessTokens.spacing4)
            .background(
                RoundedRectangle(
                    cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
                )
                .fill(isSelected ? theme.accentSoft : theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(
            isAvailable
                ? title
                : String(
                    localized: "supermux.harness.launcher.unavailable",
                    defaultValue: "Not found on your PATH."
                )
        )
    }

    private var customPathRow: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            label(
                String(
                    localized: "supermux.harness.launcher.customPath.label",
                    defaultValue: "Executable path"
                )
            )
            TextField(
                String(
                    localized: "supermux.harness.launcher.customPath.placeholder",
                    defaultValue: "/usr/local/bin/claude"
                ),
                text: $customPath
            )
            .textFieldStyle(.plain)
            .cmuxFont(size: SupermuxHarnessTokens.footnote, design: .monospaced)
            .foregroundStyle(theme.text)
            .padding(.horizontal, SupermuxHarnessTokens.spacing6)
            .padding(.vertical, SupermuxHarnessTokens.spacing4)
            .background(
                RoundedRectangle(
                    cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
                )
                .fill(theme.inputBackground)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SupermuxHarnessTokens.fileBoxRadius, style: .continuous
                )
                .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
            )
            .onSubmit { onSelectLauncher(.custom, customPath) }
        }
    }

    /// The model list cannot be fetched before the CLI is running, so a fresh
    /// panel offers the CLI's stable aliases; a live list (from a previous
    /// session in this process) replaces them. The picker is never disabled —
    /// spawn-time `--model` is the whole point of this row.
    private var modelChoices: [(value: String, label: String)] {
        var choices: [(value: String, label: String)]
        if models.isEmpty {
            choices = Self.aliasChoices
        } else {
            choices = models.map { ($0.value, $0.displayName ?? $0.value) }
        }
        // A persisted selection outside the list must stay representable, or
        // the picker silently deselects it.
        if let selectedModel, !choices.contains(where: { $0.value == selectedModel }) {
            choices.append((selectedModel, selectedModel))
        }
        return choices
    }

    private static var aliasChoices: [(value: String, label: String)] {
        [
            (
                "sonnet",
                String(
                    localized: "supermux.harness.model.alias.sonnet",
                    defaultValue: "Sonnet (alias)"
                )
            ),
            (
                "opus",
                String(
                    localized: "supermux.harness.model.alias.opus",
                    defaultValue: "Opus (alias)"
                )
            ),
            (
                "haiku",
                String(
                    localized: "supermux.harness.model.alias.haiku",
                    defaultValue: "Haiku (alias)"
                )
            ),
        ]
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            label(
                String(
                    localized: "supermux.harness.model.picker.title",
                    defaultValue: "Model"
                )
            )
            Picker("", selection: modelBinding) {
                Text(
                    String(
                        localized: "supermux.harness.model.default",
                        defaultValue: "Claude Code default"
                    )
                )
                .tag(String?.none)
                ForEach(modelChoices, id: \.value) { choice in
                    Text(choice.label).tag(String?.some(choice.value))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { selectedModel }, set: { onSelectModel($0) })
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: SupermuxHarnessTokens.caption2, weight: .semibold)
            .foregroundStyle(theme.mutedText)
            .textCase(.uppercase)
    }

    /// Theme-styled action button: every other harness control is themed, so
    /// the first screen must not fall back to gray AppKit chrome.
    private func themedButton(
        _ title: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .cmuxFont(size: SupermuxHarnessTokens.footnote, weight: .medium)
                .foregroundStyle(
                    prominent
                        ? (theme.pageIsTransparent ? theme.text : theme.popoverBackground)
                        : theme.text
                )
                .padding(.horizontal, SupermuxHarnessTokens.spacing10)
                .padding(.vertical, SupermuxHarnessTokens.spacing6)
                .background(
                    RoundedRectangle(
                        cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
                    )
                    .fill(prominent ? theme.accent : theme.surface)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
                    )
                    .strokeBorder(
                        prominent ? Color.clear : theme.border,
                        lineWidth: SupermuxHarnessTokens.hairline
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Directory picker. Modal panel, so it must not run inside `body`.
    private func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        panel.prompt = String(
            localized: "supermux.harness.session.pickPrompt",
            defaultValue: "Use Folder"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPickDirectory(url.path)
    }

    static func launcherName(_ kind: ClaudeLauncher.Kind) -> String {
        switch kind {
        case .claude:
            return String(
                localized: "supermux.harness.launcher.claude.name",
                defaultValue: "claude"
            )
        case .ccx:
            return String(
                localized: "supermux.harness.launcher.ccx.name",
                defaultValue: "ccx"
            )
        case .custom:
            return String(
                localized: "supermux.harness.launcher.custom.name",
                defaultValue: "Custom…"
            )
        }
    }
}
