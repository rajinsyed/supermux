import Foundation
import SupermuxKit
import SupermuxMobileCore

/// A presets-bar chip clicked inside a device mirror: the preset's terminal
/// opens ON THE MAC THAT OWNS THE WORKSPACE, in the mirrored remote workspace,
/// and reaches this Mac through the mirror's normal layout sync.
///
/// Presets are per Mac, so the local chip is matched to that Mac's preset
/// list (same command first, then same name) and launched with
/// `mobile.supermux.preset.launch {preset_id, workspace_id}`. A preset the
/// other Mac does not have runs as its command typed into a new terminal
/// there (`mobile.terminal.create` + `mobile.terminal.input`), since there is
/// no RPC that creates a terminal with a command.
@MainActor
final class SupermuxMirrorPresetLauncher {
    /// How a launch went, for callers that report it (the socket).
    enum Outcome: Equatable {
        /// Matched to the other Mac's own preset.
        case remotePreset(id: String, terminalID: String?)
        /// No matching preset there; the command was typed into a new terminal.
        case typedCommand(terminalID: String)
    }

    enum LaunchError: Error, LocalizedError {
        case notLaunchable
        case noTerminalCreated

        var errorDescription: String? {
            switch self {
            case .notLaunchable:
                return String(localized: "supermux.mirror.preset.notLaunchable", defaultValue: "This preset has no command.")
            case .noTerminalCreated:
                return String(localized: "supermux.mirror.preset.noTerminal", defaultValue: "The other Mac did not open a terminal.")
            }
        }
    }

    private let remoteState: SupermuxMirrorRemoteState
    private let devices: SupermuxDevices

    init(remoteState: SupermuxMirrorRemoteState, devices: SupermuxDevices) {
        self.remoteState = remoteState
        self.devices = devices
    }

    /// Fire-and-forget launch for the presets bar; failures raise an alert.
    func launchFromBar(_ preset: SupermuxTerminalPreset, in target: SupermuxMirrorTarget) {
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.launch(preset, in: target)
            } catch {
                SupermuxMirrorAlerts.presentPresetFailure(target, error: error)
            }
        }
    }

    /// Launches `preset` in the mirror's remote workspace.
    func launch(_ preset: SupermuxTerminalPreset, in target: SupermuxMirrorTarget) async throws -> Outcome {
        guard preset.isLaunchable else { throw LaunchError.notLaunchable }
        if remoteState.presets(on: target.machine).isEmpty {
            await remoteState.refreshProjects(on: target.machine)
        }
        let outcome: Outcome
        if let match = Self.match(preset, in: remoteState.presets(on: target.machine)) {
            let result = try await devices.request(
                .presetLaunch,
                params: ["preset_id": match.id, "workspace_id": target.remoteWorkspaceID],
                on: target.machine
            )
            outcome = .remotePreset(id: match.id, terminalID: result["terminal_id"] as? String)
        } else {
            outcome = .typedCommand(terminalID: try await typeCommand(preset.command, in: target))
        }
        await pullLayout(of: target)
        return outcome
    }

    /// The owning Mac announces layout changes only on pane-geometry changes,
    /// which a background tab added to a workspace it is not showing does not
    /// produce; pull the layout so the new terminal appears in the mirror now.
    private func pullLayout(of target: SupermuxMirrorTarget) async {
        await devices.provider(for: target.machine)?.refresh(force: true)
    }

    /// The other Mac's preset for a local chip: identical command, else the
    /// same name (case-insensitive).
    static func match(_ preset: SupermuxTerminalPreset, in remote: [SupermuxTerminalPresetDTO]) -> SupermuxTerminalPresetDTO? {
        let command = preset.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return remote.first { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == command }
            ?? remote.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Opens a terminal in the remote workspace and types `command` + Return.
    private func typeCommand(_ command: String, in target: SupermuxMirrorTarget) async throws -> String {
        let created = try await devices.request(
            "mobile.terminal.create",
            params: ["workspace_id": target.remoteWorkspaceID],
            on: target.machine
        )
        guard let terminalID = created["created_terminal_id"] as? String else { throw LaunchError.noTerminalCreated }
        _ = try await devices.request(
            "mobile.terminal.input",
            params: [
                "workspace_id": target.remoteWorkspaceID,
                "surface_id": terminalID,
                "text": command.trimmingCharacters(in: .whitespacesAndNewlines) + "\r",
            ],
            on: target.machine
        )
        return terminalID
    }
}
