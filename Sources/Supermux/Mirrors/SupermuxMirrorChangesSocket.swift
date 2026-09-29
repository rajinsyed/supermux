import Foundation
import SupermuxKit

/// `supermux.devices.mirror.changes`: drives the Changes model a mirror's
/// panel uses. When a window's Changes panel is showing the mirror, its own
/// (mounted) model is used; otherwise one is built by the same factory the
/// panel uses. Either way git runs on the owning Mac. `compare_local: true`
/// adds `local_model`: this Mac's own panel for the same directory.
@MainActor
enum SupermuxMirrorChangesSocket {
    static func handle(_ params: [String: Any], workspace: Workspace) async throws -> [String: Any] {
        guard let target = SupermuxComposition.mirrorResolver.target(for: workspace) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "workspace_id is not a device mirror")
        }
        let mounted = SupermuxComposition.mirrorChangesPanels.source(showing: workspace.id)?.remoteModel
        let model = mounted ?? SupermuxMirrorChangesSource.makeModel(for: target, devices: SupermuxComposition.devices)
        await settle(model)
        var payload: [String: Any] = ["source": mounted == nil ? "transient" : "mounted_panel"]
        switch params["action"] as? String ?? "status" {
        case "status":
            break
        case "stage":
            let path = try SupermuxMirrorSocketCommands.string(params, "path")
            guard let change = (model.snapshot.unstaged + model.snapshot.untracked).first(where: { $0.path == path }) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "\(path) is not an unstaged change")
            }
            await model.stage(change)
        case "unstage":
            let path = try SupermuxMirrorSocketCommands.string(params, "path")
            guard let change = model.snapshot.staged.first(where: { $0.path == path }) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "\(path) is not a staged change")
            }
            await model.unstage(change)
        case "diff":
            payload["diff"] = try await diff(params, model: model, workspace: workspace)
        case "fetch":
            // The panel's Fetch and its auto-fetch timer.
            await model.fetchAndRefresh()
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "action must be status, stage, unstage, diff or fetch")
        }
        payload["model"] = describe(model)
        if params["compare_local"] as? Bool == true {
            payload["local_model"] = try await describeLocalPanel(at: model.directory)
        }
        return payload
    }

    /// What THIS Mac's own Changes panel shows for `directory` (the loopback
    /// device's repository is on this disk too), built like the window's
    /// local model: the reference a mirror's panel must match.
    private static func describeLocalPanel(at directory: String?) async throws -> [String: Any] {
        guard let directory else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the mirror's model has no directory")
        }
        let local = SupermuxChangesModel(
            service: SupermuxGitChangesService(runner: CommandRunner()),
            commitGenerator: SupermuxComposition.aiCommitMessenger
        )
        local.setDirectory(directory)
        await settle(local)
        return describe(local)
    }

    private static func diff(_ params: [String: Any], model: SupermuxChangesModel, workspace: Workspace) async throws -> [String: Any] {
        let path = try SupermuxMirrorSocketCommands.string(params, "path")
        let staged = params["staged"] as? Bool ?? false
        let changes = staged ? model.snapshot.staged : model.snapshot.unstaged + model.snapshot.untracked
        guard let change = changes.first(where: { $0.path == path }) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "\(path) is not a change on that side")
        }
        guard let patch = await model.fileDiffPatch(for: change, staged: staged) else {
            return ["patch": NSNull(), "last_error": model.lastError ?? NSNull()]
        }
        var result: [String: Any] = [
            "patch": String(patch.patch.prefix(4000)),
            "is_remote": patch.isRemote,
            "repo_path": patch.repoPath,
            "title": patch.title,
        ]
        if params["open_viewer"] as? Bool == true, let manager = workspace.owningTabManager {
            manager.selectWorkspace(workspace)
            result["viewer_opened"] = SupermuxFileDiffOpener.shared.present(patch, for: manager)
        }
        return result
    }

    /// A just-mounted panel's model may still be on its first read (a
    /// `refresh()` issued meanwhile only queues a follow-up), so wait briefly
    /// for a repository snapshot before acting on it.
    private static func settle(_ model: SupermuxChangesModel) async {
        for _ in 0..<30 {
            await model.refresh()
            if model.snapshot.isRepository { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func describe(_ model: SupermuxChangesModel) -> [String: Any] {
        func files(_ changes: [SupermuxGitFileChange]) -> [[String: Any]] {
            changes.map { ["path": $0.path, "kind": $0.kind.rawValue] }
        }
        let snapshot = model.snapshot
        return [
            "directory": model.directory ?? NSNull(),
            "is_remote": model.isRemote,
            "is_repository": snapshot.isRepository,
            "branch": snapshot.branch ?? NSNull(),
            "staged": files(snapshot.staged),
            "unstaged": files(snapshot.unstaged),
            "untracked": files(snapshot.untracked),
            "last_error": model.lastError ?? NSNull(),
            "ai_commit_configured": model.aiCommitConfigured,
            "is_ai_commit_mode": model.isAICommitMode,
            "can_commit": model.canCommit,
            "commit_button_title": model.commitButtonTitle,
        ]
    }
}
