import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.project.probe` / `project.clone`: the host side of
/// cross-Mac project setup (capability `supermux.project_setup.v1`). Another
/// Mac probes a folder here before registering its copy of a repository
/// (project sync), and "Set Up on <Mac>…" clones into a folder here.
extension TerminalController {
    /// `mobile.supermux.project.probe {root_path}` →
    /// `{root_path, exists, is_directory, is_git_repo, git_remote_url?, is_suppressed}`
    /// (``SupermuxProjectProbeDTO``). `is_suppressed` is true when this Mac's
    /// user removed a project at that root, so sync must not re-add it.
    func v2SupermuxProjectProbe(params: [String: Any]) async -> V2CallResult {
        guard let raw = params["root_path"] as? String,
              let root = SupermuxProjectSetupService.standardizedRoot(raw) else {
            return .err(code: "invalid_params", message: "root_path must be an absolute folder path", data: nil)
        }
        let (service, suppressed) = await MainActor.run {
            (
                SupermuxComposition.projectSetupService,
                SupermuxComposition.projectSyncSuppression.isSuppressed(rootPath: root)
            )
        }
        let probe = await service.probe(rootPath: root, isSuppressed: suppressed)
        do {
            return .ok(try SupermuxWireJSON().dictionary(from: probe))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode probe", data: nil)
        }
    }

    /// `mobile.supermux.project.clone {remote_url, root_path}`: `git clone`s
    /// the repository into `root_path` (which must not exist, or be an empty
    /// folder; parents are created) and registers it through the desktop add
    /// path. Result: `{project}` like `project.create`. Errors:
    /// `invalid_params`, `destination_exists`, `clone_failed`.
    @MainActor
    func v2SupermuxProjectClone(params: [String: Any]) async -> V2CallResult {
        guard let remoteURL = params["remote_url"] as? String,
              let rootPath = params["root_path"] as? String else {
            return .err(code: "invalid_params", message: "remote_url and root_path are required", data: nil)
        }
        let root: String
        do {
            root = try await SupermuxComposition.projectSetupService.clone(remoteURL: remoteURL, into: rootPath)
        } catch let error as SupermuxProjectSetupError {
            return .err(code: error.code, message: error.localizedDescription, data: ["root_path": rootPath])
        } catch {
            return .err(code: "clone_failed", message: error.localizedDescription, data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        let project = await model.addProject(rootPath: root)
        return await supermuxProjectResult(project)
    }
}
