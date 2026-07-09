import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.changes.*` handlers (part 1: watch/status/diff/stage/
/// unstage/discard): the Mac side of the iOS Changes screen. All git work
/// runs through the shared ``SupermuxGitChangesService`` — the exact engine
/// behind the desktop Changes panel, never a re-implementation — against the
/// directory of the EXPLICIT `workspace_id` param (the desktop panel binds to
/// each window's selected workspace; the phone names its target instead).
/// Wire payloads are built by package-tested SupermuxKit types.
///
/// Commit/push/pull/stash/history/generate_commit_message arrive with the
/// next changes feature; until then they return `method_not_found` and the
/// phone must tolerate that under the already-advertised
/// `supermux.changes.v1` capability.
extension TerminalController {
    /// One process-wide git engine for the mobile changes handlers (an actor
    /// wrapping a `CommandRunner`; requests serialize per invocation exactly
    /// like the desktop panel's per-model service).
    @MainActor
    private static let supermuxMobileChangesService = SupermuxGitChangesService()

    /// `mobile.supermux.changes.watch`: starts, heartbeats, or stops the
    /// per-workspace repository watcher lease (see
    /// ``SupermuxMobileChangesWatchRegistry``). Result:
    /// `{watching, ttl_seconds}` — the phone re-sends `{enable: true}` every
    /// 60 s to stay inside the 120 s TTL.
    @MainActor
    func v2SupermuxChangesWatch(params: [String: Any]) async -> V2CallResult {
        guard let enable = params["enable"] as? Bool else {
            return .err(code: "invalid_params", message: "enable must be a boolean", data: nil)
        }
        guard enable else {
            guard let workspaceID = v2UUID(params, "workspace_id") else {
                return .err(
                    code: "invalid_params", message: "workspace_id must be a workspace UUID", data: nil
                )
            }
            // Stop immediately, even when the workspace has since closed.
            SupermuxMobileHostGlue.changesWatchRegistry.unwatch(
                workspaceId: workspaceID.uuidString
            )
            return .ok(["watching": false])
        }
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        SupermuxMobileHostGlue.changesWatchRegistry.watch(
            workspaceId: target.workspaceId,
            directory: target.directory
        )
        return .ok([
            "watching": true,
            "ttl_seconds": Int(SupermuxMobileChangesWatchRegistry.ttl),
        ])
    }

    /// `mobile.supermux.changes.status`: the workspace repository's status
    /// snapshot as a `SupermuxChangesStatusDTO` payload (branch, upstream,
    /// ahead/behind, staged/unstaged/untracked arrays, stash_count).
    @MainActor
    func v2SupermuxChangesStatus(params: [String: Any]) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        let snapshot = await Self.supermuxMobileChangesService.status(repoPath: target.directory)
        do {
            return .ok(try SupermuxMobileChangesPayloadBuilder().status(
                workspaceId: target.workspaceId,
                snapshot: snapshot
            ))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode changes status", data: nil)
        }
    }

    /// `mobile.supermux.changes.diff`: one file's unified diff as a
    /// `SupermuxDiffDTO` payload. `staged: true` diffs the index; binary
    /// files return `is_binary` with no text; oversized diffs are byte-capped
    /// and flagged `truncated`.
    @MainActor
    func v2SupermuxChangesDiff(params: [String: Any]) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        guard let path = params["path"] as? String, !path.isEmpty else {
            return .err(code: "invalid_params", message: "path is required", data: nil)
        }
        let staged = params["staged"] as? Bool ?? false
        let diff = await Self.supermuxMobileChangesService.fileDiff(
            repoPath: target.directory,
            path: path,
            staged: staged
        )
        do {
            return .ok(try SupermuxMobileChangesPayloadBuilder().diff(path: path, diff: diff))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode diff", data: nil)
        }
    }

    /// `mobile.supermux.changes.stage`: stages `{paths}` or everything with
    /// `{all: true}` (`git add -A`, untracked included — the desktop Stage
    /// All). Result: `{ok: true}`.
    @MainActor
    func v2SupermuxChangesStage(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesMutation(params: params) { directory, service in
            switch supermuxPathsSelection(params: params) {
            case .all:
                try await service.stageAll(repoPath: directory)
            case let .paths(paths):
                try await service.stage(repoPath: directory, paths: paths)
            case .invalid:
                return .err(
                    code: "invalid_params",
                    message: "Provide a non-empty paths array or all: true",
                    data: nil
                )
            }
            return nil
        }
    }

    /// `mobile.supermux.changes.unstage`: unstages `{paths}` or everything
    /// with `{all: true}` (`git reset -q`). Result: `{ok: true}`.
    @MainActor
    func v2SupermuxChangesUnstage(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesMutation(params: params) { directory, service in
            switch supermuxPathsSelection(params: params) {
            case .all:
                try await service.unstageAll(repoPath: directory)
            case let .paths(paths):
                try await service.unstage(repoPath: directory, paths: paths)
            case .invalid:
                return .err(
                    code: "invalid_params",
                    message: "Provide a non-empty paths array or all: true",
                    data: nil
                )
            }
            return nil
        }
    }

    /// `mobile.supermux.changes.discard`: discards `{paths}` after
    /// re-validating every path against a FRESH status snapshot (the phone's
    /// confirmation dialog is not trusted): any path that is not a current
    /// change rejects the whole request with `not_found` and nothing is
    /// mutated. Tracked files restore HEAD/index content; untracked files are
    /// deleted — the shared desktop discard path. Result: `{ok: true}`.
    @MainActor
    func v2SupermuxChangesDiscard(params: [String: Any]) async -> V2CallResult {
        await supermuxChangesMutation(params: params) { directory, service in
            guard case let .paths(paths) = supermuxPathsSelection(params: params) else {
                return .err(
                    code: "invalid_params", message: "Provide a non-empty paths array", data: nil
                )
            }
            let snapshot = await service.status(repoPath: directory)
            switch SupermuxMobileChangesDiscard.resolve(paths: paths, in: snapshot) {
            case let .unknownPaths(unknown):
                return .err(
                    code: "not_found",
                    message: "Paths are not current changes",
                    data: ["paths": unknown]
                )
            case let .changes(changes):
                for change in changes {
                    try await service.discard(repoPath: directory, change: change)
                }
            }
            return nil
        }
    }

    // MARK: - Shared pieces

    /// The `{paths}` / `{all}` selection a stage/unstage/discard request made.
    private enum SupermuxPathsSelection {
        case all
        case paths([String])
        case invalid
    }

    /// Parses the mutation param shape: `all: true` wins, otherwise a
    /// non-empty string array under `paths` (blank entries dropped, matching
    /// the shared patch-value conventions).
    private func supermuxPathsSelection(params: [String: Any]) -> SupermuxPathsSelection {
        if params["all"] as? Bool == true { return .all }
        guard let raw = params["paths"] as? [Any] else { return .invalid }
        let paths = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard paths.count == raw.count, !paths.isEmpty else { return .invalid }
        return .paths(paths)
    }

    /// Runs one changes mutation: resolves the workspace, executes `work`
    /// (which may return an early wire error), and maps git failures to the
    /// shared error shape. Success is `{ok: true}` — the phone refetches
    /// status (and the watcher pokes it anyway).
    @MainActor
    private func supermuxChangesMutation(
        params: [String: Any],
        work: @MainActor (String, SupermuxGitChangesService) async throws -> V2CallResult?
    ) async -> V2CallResult {
        let target: (workspaceId: String, directory: String)
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return error
        case let .success(resolved): target = resolved
        }
        do {
            if let earlyError = try await work(target.directory, Self.supermuxMobileChangesService) {
                return earlyError
            }
        } catch let error as SupermuxGitError {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        } catch {
            return .err(code: "unavailable", message: error.localizedDescription, data: nil)
        }
        return .ok(["ok": true])
    }

    /// Resolves the request's `workspace_id` to the workspace's current
    /// directory — the same directory the desktop Changes panel binds to
    /// (`tabManager.selectedWorkspace?.currentDirectory`), located across all
    /// open windows.
    @MainActor
    func supermuxResolveWorkspaceDirectory(
        params: [String: Any]
    ) -> SupermuxParamResolution<(workspaceId: String, directory: String)> {
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .failure(.err(
                code: "invalid_params", message: "workspace_id must be a workspace UUID", data: nil
            ))
        }
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .failure(.err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceID.uuidString,
            ]))
        }
        let directory = workspace.currentDirectory
        guard !directory.isEmpty else {
            return .failure(.err(
                code: "unavailable",
                message: "Workspace has no working directory",
                data: ["workspace_id": workspaceID.uuidString]
            ))
        }
        return .success((workspaceID.uuidString, directory))
    }
}
