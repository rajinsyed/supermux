import Foundation
import SupermuxMobileCore
import SwiftUI

/// The run/presets/actions half of ``SupermuxProjectDetailScreen``: the Run
/// section (status + shared start/stop control), the Presets launcher
/// section, the Actions section, and their toast/alert decorations — split
/// from the main file to respect the per-file length budget.
extension SupermuxProjectDetailScreen {
    // MARK: - Sections

    /// The Run section: the live status (green dot + running command, or
    /// "Not Running") and the shared start/stop control. Rendered only when
    /// `row.run` is non-nil (host serves `supermux.run.v1` AND the project
    /// has a run command).
    func runSection(
        run: SupermuxProjectRunState,
        runActions: SupermuxProjectRunActions
    ) -> some View {
        Section {
            HStack(spacing: 8) {
                if run.isRunning {
                    Text(run.command ?? String(
                        localized: "supermux.run.running",
                        defaultValue: "Running",
                        bundle: .module
                    ))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text(String(
                        localized: "supermux.run.notRunning",
                        defaultValue: "Not Running",
                        bundle: .module
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                SupermuxProjectRunControl(
                    projectID: row.id,
                    run: run,
                    runCommands: row.runCommands,
                    startRun: runActions.startRun,
                    stopRun: runActions.stopRun
                )
            }
            .accessibilityIdentifier("SupermuxProjectDetailRunRow")
        } header: {
            Text(String(
                localized: "supermux.run.sectionTitle",
                defaultValue: "Run",
                bundle: .module
            ))
        }
    }

    /// The Presets section: every global preset as a tap-to-launch row, plus
    /// the presets MANAGER entry (list + create/edit/delete) — the manager's
    /// only mount now that the main list's section-level presets row is
    /// removed (m6-f1). A launch runs the preset at THIS project's root on
    /// the Mac and navigates to the returned workspace (same idiom as
    /// worktree opens).
    var presetsSection: some View {
        Section {
            ForEach(presets, id: \.id) { preset in
                Button {
                    launchPreset(preset)
                } label: {
                    SupermuxPresetLaunchRow(preset: preset)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SupermuxProjectPresetLaunchRow-\(preset.id)")
            }
            if let editing {
                NavigationLink {
                    SupermuxPresetsListScreen(presets: presets, editing: editing)
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.presets.manage",
                            defaultValue: "Manage Presets",
                            bundle: .module
                        ))
                        .font(.body)
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("SupermuxPresetsManageRow")
            }
        } header: {
            Text(String(
                localized: "supermux.presets.title",
                defaultValue: "Presets",
                bundle: .module
            ))
        }
    }

    /// The Actions section: the project's named custom actions. `open_url`
    /// outcomes open locally on the phone; command outcomes run in a fresh
    /// Mac terminal and report a transient confirmation.
    var actionsSection: some View {
        Section {
            ForEach(row.actions, id: \.id) { action in
                Button {
                    runProjectAction(action)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: actionSymbol(for: action))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(action.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SupermuxProjectActionRow-\(action.id)")
            }
        } header: {
            Text(String(
                localized: "supermux.projects.detail.actionsTitle",
                defaultValue: "Actions",
                bundle: .module
            ))
        }
    }

    // MARK: - Decorations

    /// Wraps the list with the run-flow decorations: the transient "fired"
    /// toast (+ its auto-dismiss timer) and the preset/action error alerts.
    func runDecorated(_ content: some View) -> some View {
        content
            .overlay(alignment: .bottom) { actionToastOverlay }
            .task(id: actionToastEpoch) {
                // Auto-dismiss the fired confirmation; a fresh fire bumps the
                // epoch and restarts the timer.
                guard actionToast != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { actionToast = nil }
            }
            .alert(
                String(
                    localized: "supermux.presets.launch.failed.title",
                    defaultValue: "Couldn’t Launch Preset",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { presetErrorMessage != nil },
                    set: { if !$0 { presetErrorMessage = nil } }
                ),
                presenting: presetErrorMessage
            ) { _ in
                Button(role: .cancel) {
                    presetErrorMessage = nil
                } label: {
                    Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
                }
            } message: { message in
                Text(message)
            }
            .alert(
                String(
                    localized: "supermux.actions.failed.title",
                    defaultValue: "Couldn’t Run Action",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { actionErrorMessage != nil },
                    set: { if !$0 { actionErrorMessage = nil } }
                ),
                presenting: actionErrorMessage
            ) { _ in
                Button(role: .cancel) {
                    actionErrorMessage = nil
                } label: {
                    Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
                }
            } message: { message in
                Text(message)
            }
    }

    /// The transient "fired on your Mac" capsule.
    @ViewBuilder
    private var actionToastOverlay: some View {
        if let actionToast {
            Text(actionToast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.thinMaterial))
                .padding(.bottom, 16)
                .transition(.opacity)
                .accessibilityIdentifier("SupermuxActionFiredToast")
        }
    }

    // MARK: - Flows

    /// Launches one global preset at this project's root and navigates to
    /// the workspace the Mac answered with.
    private func launchPreset(_ preset: SupermuxTerminalPresetDTO) {
        guard let runActions else { return }
        Task {
            do {
                let response = try await runActions.launchPreset(preset.id, row.id)
                if let workspaceID = response.workspaceId {
                    selectWorkspace(workspaceID)
                }
            } catch {
                presetErrorMessage = error.localizedDescription
            }
        }
    }

    /// Runs one project action: `open_url` outcomes open locally through the
    /// environment's `openURL` (nothing ran Mac-side); command outcomes
    /// already ran on the Mac, so the phone shows a transient confirmation.
    private func runProjectAction(_ action: SupermuxProjectActionDTO) {
        guard let runActions else { return }
        Task {
            do {
                let outcome = try await runActions.runAction(row.id, action.id)
                if outcome.opensURLLocally {
                    guard let urlString = outcome.url, let url = URL(string: urlString) else {
                        actionErrorMessage = String(
                            localized: "supermux.actions.invalidURL",
                            defaultValue: "The Mac returned an invalid URL.",
                            bundle: .module
                        )
                        return
                    }
                    openURL(url)
                } else {
                    withAnimation {
                        actionToast = String(
                            localized: "supermux.actions.fired",
                            defaultValue: "Action started on your Mac",
                            bundle: .module
                        )
                    }
                    actionToastEpoch += 1
                }
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    /// The action row's glyph: its own SF symbol when set, else the desktop
    /// actions menu's neutral bolt.
    private func actionSymbol(for action: SupermuxProjectActionDTO) -> String {
        let trimmed = action.iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "bolt" : trimmed
    }
}

/// One launchable preset row in the project detail: the chip glyph tinted by
/// the preset's accent, the label + command, and a launch glyph (a play
/// affordance instead of the manager screen's disclosure chevron).
struct SupermuxPresetLaunchRow: View {
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
            Image(systemName: "play.circle")
                .font(.body)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(preset.name)
        .accessibilityHint(String(
            localized: "supermux.presets.launch",
            defaultValue: "Launch Preset",
            bundle: .module
        ))
    }
}
