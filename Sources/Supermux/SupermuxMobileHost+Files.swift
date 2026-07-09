import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.files.*` handlers: the Mac side of the iOS file browser.
/// Each request names its root explicitly — a `workspace_id` (the workspace's
/// current directory, like the desktop file-explorer panel) XOR a
/// `project_id` (the project's `root_path`) — and every path is confined to
/// that root by the package-tested ``SupermuxMobileFileBrowser`` engine
/// (architecture §10: canonicalize, reject `..` traversal and symlink
/// escapes with `invalid_params`; deletion is Trash, never `rm`).
///
/// Ticket scoping is enforced upstream by ``SupermuxMobileAuthorization``:
/// workspace-scoped tickets pass only their own `workspace_id`; `project_id`
/// requests require a Mac-wide ticket.
extension TerminalController {
    /// `mobile.supermux.files.list`: children of the directory at
    /// root-relative `path` (absent = the root). Result:
    /// `{path, entries: [SupermuxFileEntryDTO]}`.
    @MainActor
    func v2SupermuxFilesList(params: [String: Any]) async -> V2CallResult {
        await supermuxFilesOperation(params: params) { browser in
            .ok(try browser.listPayload(path: params["path"] as? String))
        }
    }

    /// `mobile.supermux.files.create`: creates an empty file or a folder at
    /// root-relative `path` per `kind: "file" | "folder"`. Result:
    /// `{ok: true, path}`.
    @MainActor
    func v2SupermuxFilesCreate(params: [String: Any]) async -> V2CallResult {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return .err(code: "invalid_params", message: "path is required", data: nil)
        }
        guard let kind = params["kind"] as? String, kind == "file" || kind == "folder" else {
            return .err(
                code: "invalid_params", message: "kind must be \"file\" or \"folder\"", data: nil
            )
        }
        return await supermuxFilesOperation(params: params) { browser in
            let created = kind == "file"
                ? try browser.createFile(at: path)
                : try browser.createFolder(at: path)
            return .ok(["ok": true, "path": created])
        }
    }

    /// `mobile.supermux.files.rename`: renames the entry at root-relative
    /// `path` to `new_name` (a single component). Result: `{ok: true, path}`
    /// with the entry's new root-relative path.
    @MainActor
    func v2SupermuxFilesRename(params: [String: Any]) async -> V2CallResult {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return .err(code: "invalid_params", message: "path is required", data: nil)
        }
        guard let newName = params["new_name"] as? String, !newName.isEmpty else {
            return .err(code: "invalid_params", message: "new_name is required", data: nil)
        }
        return await supermuxFilesOperation(params: params) { browser in
            .ok(["ok": true, "path": try browser.rename(path: path, to: newName)])
        }
    }

    /// `mobile.supermux.files.duplicate`: duplicates the entry at
    /// root-relative `path` with a Finder-style " copy" name. Result:
    /// `{ok: true, path}` with the copy's root-relative path.
    @MainActor
    func v2SupermuxFilesDuplicate(params: [String: Any]) async -> V2CallResult {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return .err(code: "invalid_params", message: "path is required", data: nil)
        }
        return await supermuxFilesOperation(params: params) { browser in
            .ok(["ok": true, "path": try browser.duplicate(path: path)])
        }
    }

    /// `mobile.supermux.files.trash`: moves the entries at root-relative
    /// `paths` to the Trash (batch-validated first — one escaping path
    /// rejects the whole request with no filesystem effect). Result:
    /// `{ok: true}`.
    @MainActor
    func v2SupermuxFilesTrash(params: [String: Any]) async -> V2CallResult {
        guard let raw = params["paths"] as? [Any] else {
            return .err(
                code: "invalid_params", message: "paths must be a non-empty array", data: nil
            )
        }
        let paths = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard paths.count == raw.count, !paths.isEmpty else {
            return .err(
                code: "invalid_params", message: "paths must be a non-empty array", data: nil
            )
        }
        return await supermuxFilesOperation(params: params) { browser in
            try browser.trash(paths: paths)
            return .ok(["ok": true])
        }
    }

    // MARK: - Shared pieces

    /// Resolves the request's root, builds the confined browser, runs `work`,
    /// and maps engine failures onto the wire error shape (package-tested
    /// classification: confinement violations → `invalid_params`).
    @MainActor
    private func supermuxFilesOperation(
        params: [String: Any],
        work: (SupermuxMobileFileBrowser) throws -> V2CallResult
    ) async -> V2CallResult {
        let root: String
        switch await supermuxResolveFilesRoot(params: params) {
        case let .failure(error): return error
        case let .success(resolved): root = resolved
        }
        do {
            return try work(try SupermuxMobileFileBrowser(rootPath: root))
        } catch {
            let (code, message) = SupermuxMobileFilesWireFailure.classify(error)
            return .err(code: code, message: message, data: nil)
        }
    }

    /// Resolves the request's root directory: exactly ONE of `workspace_id`
    /// (the workspace's current directory) or `project_id` (the project's
    /// `root_path`); both or neither is `invalid_params` — the root selector
    /// must be unambiguous because it also decides the ticket scope.
    @MainActor
    private func supermuxResolveFilesRoot(
        params: [String: Any]
    ) async -> SupermuxParamResolution<String> {
        let hasWorkspace = ((params["workspace_id"] as? String).map { !$0.isEmpty }) ?? false
        let hasProject = ((params["project_id"] as? String).map { !$0.isEmpty }) ?? false
        guard hasWorkspace != hasProject else {
            return .failure(.err(
                code: "invalid_params",
                message: "Provide exactly one of workspace_id or project_id",
                data: nil
            ))
        }
        if hasProject {
            switch await supermuxResolveProject(params: params) {
            case let .failure(error): return .failure(error)
            case let .success(project): return .success(project.rootPath)
            }
        }
        switch supermuxResolveWorkspaceDirectory(params: params) {
        case let .failure(error): return .failure(error)
        case let .success(resolved): return .success(resolved.directory)
        }
    }
}
