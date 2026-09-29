import AppKit
import Foundation
import SupermuxMobileCore

/// Runs a remote project's custom action (`mobile.supermux.action.run`) on
/// the Mac that owns it. `open_url` actions come back as a URL and open on
/// THIS Mac (where the user is looking); command actions run over there.
@MainActor
struct SupermuxMirrorProjectActions {
    /// What the owning Mac did.
    enum Outcome: Equatable {
        case openedURL(URL)
        case ranCommand
    }

    let devices: SupermuxDevices
    /// Opens an `open_url` action's URL locally.
    var openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    /// Runs `actionID` of the remote project `projectID` on `target`'s Mac,
    /// in the workspace the mirror shows.
    func run(actionID: String, projectID: String, on target: SupermuxMirrorTarget) async throws -> Outcome {
        let result = try await devices.request(
            .actionRun,
            params: ["project_id": projectID, "action_id": actionID, "workspace_id": target.remoteWorkspaceID],
            on: target.machine
        )
        if result["kind"] as? String == "open_url",
           let raw = result["url"] as? String,
           let url = URL(string: raw) {
            _ = openURL(url)
            return .openedURL(url)
        }
        return .ranCommand
    }
}
