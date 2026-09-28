import AppKit
import Foundation

/// User-facing explanations for mirror actions that cannot run, each naming
/// the Mac that owns the workspace.
@MainActor
enum SupermuxMirrorAlerts {
    /// ⌘G / Run on a remote workspace that belongs to no project on its Mac.
    static func presentNoRemoteProject(_ target: SupermuxMirrorTarget) {
        present(
            title: String(
                localized: "supermux.mirror.run.noProject.title",
                defaultValue: "No project for this workspace"
            ),
            message: String(
                localized: "supermux.mirror.run.noProject.message",
                defaultValue: "This workspace is on \(target.deviceName) and is not part of a project there. Add its folder as a project on \(target.deviceName) to configure run commands."
            )
        )
    }

    /// A remote run start/stop the owning Mac refused or could not deliver.
    static func presentRunFailure(_ target: SupermuxMirrorTarget, error: any Error) {
        present(
            title: String(
                localized: "supermux.mirror.run.failed.title",
                defaultValue: "Couldn’t run on \(target.deviceName)"
            ),
            message: error.localizedDescription
        )
    }

    /// A preset that could not launch on the owning Mac.
    static func presentPresetFailure(_ target: SupermuxMirrorTarget, error: any Error) {
        present(
            title: String(
                localized: "supermux.mirror.preset.failed.title",
                defaultValue: "Couldn’t open the preset on \(target.deviceName)"
            ),
            message: error.localizedDescription
        )
    }

    private static func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
