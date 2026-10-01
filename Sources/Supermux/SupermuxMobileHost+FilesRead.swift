import CmuxCloud
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// The read-only `mobile.supermux.files.*` handlers another Mac's Files panel
/// uses (capability `supermux.files_read.v1`): `files.read`, `files.search`
/// and `files.git_status`. Like `files.list`, each request names a
/// `workspace_id` (or `project_id`) and is confined to that root by
/// ``SupermuxMobileFileBrowser``; `expected_root` pins the folder the viewer
/// shows, so a `cd` here answers `stale_root` instead of another tree.
///
/// None of these takes a command or a flag: reads are bounded `pread`s of
/// regular files, search is ripgrep with fixed arguments
/// (``SupermuxHostFileSearch``), and git status is the desktop panel's own
/// `git status --porcelain` (``GitStatusProvider``) behind a time bound.
extension TerminalController {
    /// How long `files.git_status` waits for git before answering `timed_out`
    /// (inside the call's own bound, `SupermuxMobileFileBrowser.gitStatusTimeout`).
    nonisolated static let supermuxFilesGitStatusTimeout = SupermuxMobileFileBrowser.operationTimeout
    /// The most decorated paths one `files.git_status` returns.
    nonisolated static let supermuxFilesGitStatusMaxEntries = 20_000

    /// `mobile.supermux.files.read`: one chunk of the regular file at
    /// root-relative `path` (`offset`, `length` ≤ 512 KiB). Result:
    /// ``SupermuxFileReadDTO``. Refused with `forbidden` while this Mac's
    /// `DisableFileTransfer` policy is on (a read copies the file off this Mac).
    @MainActor
    func v2SupermuxFilesRead(params: [String: Any]) async -> V2CallResult {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return .err(code: "invalid_params", message: "path is required", data: nil)
        }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? SupermuxMobileFileBrowser.maxReadChunk
        guard !ManagedFileTransferPolicy.isDisabled else {
            return .err(code: "forbidden", message: ManagedFileTransferPolicy.disabledMessage, data: nil)
        }
        return await supermuxFilesOperation(params: params) { browser in
            .ok(try SupermuxWireJSON().dictionary(from: browser.read(path: path, offset: offset, length: length)))
        }
    }

    /// `mobile.supermux.files.search`: file contents matching `query` (a fixed
    /// string, 1–1000 characters) under the root. Result:
    /// ``SupermuxFileSearchDTO`` with root-relative paths. `rg_missing` when
    /// this Mac has no ripgrep. Refused with `forbidden` while
    /// `DisableFileTransfer` is on, like `files.read`: each result carries a
    /// line of the file, so repeated searches would copy files off this Mac.
    @MainActor
    func v2SupermuxFilesSearch(params: [String: Any]) async -> V2CallResult {
        guard let query = params["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 1000 else {
            return .err(code: "invalid_params", message: "query must be 1 to 1000 characters", data: nil)
        }
        guard !ManagedFileTransferPolicy.isDisabled else {
            return .err(code: "forbidden", message: ManagedFileTransferPolicy.disabledMessage, data: nil)
        }
        return await supermuxFilesOperation(params: params) { browser in
            do {
                let result = try SupermuxHostFileSearch.search(query: query, root: browser.rootPath)
                return .ok(try SupermuxWireJSON().dictionary(from: result))
            } catch SupermuxHostFileSearch.Failure.ripgrepMissing {
                return .err(code: "rg_missing", message: "ripgrep (rg) is not installed on this Mac", data: nil)
            } catch SupermuxHostFileSearch.Failure.failed(let reason) {
                return .err(code: "unavailable", message: reason, data: nil)
            }
        }
    }

    /// `mobile.supermux.files.git_status`: the git colors the desktop Files
    /// panel shows for the root (changed files and their folders), keyed by
    /// root-relative path. Result: ``SupermuxFileGitStatusDTO``.
    @MainActor
    func v2SupermuxFilesGitStatus(params: [String: Any]) async -> V2CallResult {
        await supermuxFilesOperation(params: params, timeout: SupermuxMobileFileBrowser.gitStatusTimeout) { browser in
            .ok(try SupermuxWireJSON().dictionary(from: Self.supermuxGitStatus(root: browser.rootPath)))
        }
    }

    /// Whether a workspace's folder is not on this Mac (an SSH, Cloud or
    /// device-mirror workspace): its `currentDirectory` names a path on
    /// another machine, so `files.*` must not read this disk there.
    @MainActor
    static func supermuxWorkspaceFilesAreElsewhere(_ workspaceID: String) -> Bool {
        guard let id = UUID(uuidString: workspaceID), let workspace = Workspace.liveWorkspace(id: id) else {
            return false
        }
        return workspace.usesRemoteDirectoryProvenance
    }

    /// The desktop panel's git status for `root`, re-keyed root-relative.
    /// Blocks for at most ``supermuxFilesGitStatusTimeout``; call it off the
    /// main actor. Joins the folder's `git status` already running, if any
    /// (``SupermuxGitStatusRuns``), so a git slower than the requests for it
    /// never piles up git processes.
    nonisolated static func supermuxGitStatus(root: String) -> SupermuxFileGitStatusDTO {
        let run = SupermuxGitStatusRuns.shared.join(root: root)
        let isRepository = supermuxIsInsideRepository(root)
        guard let found = run.wait(seconds: supermuxFilesGitStatusTimeout) else {
            return SupermuxFileGitStatusDTO(isRepository: isRepository, timedOut: true, statuses: [])
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let statuses = found.compactMap { path, status -> SupermuxFileGitStatusEntryDTO? in
            guard path.hasPrefix(prefix) else { return nil }
            return SupermuxFileGitStatusEntryDTO(path: String(path.dropFirst(prefix.count)), status: String(describing: status))
        }.sorted { $0.path < $1.path }
        // Colors only: a repository with a huge change set keeps its reply far
        // inside the device link's frame by dropping the rest.
        return SupermuxFileGitStatusDTO(
            isRepository: isRepository || !statuses.isEmpty,
            statuses: Array(statuses.prefix(supermuxFilesGitStatusMaxEntries))
        )
    }

    /// Whether `directory` or one of its ancestors holds a `.git` entry.
    private nonisolated static func supermuxIsInsideRepository(_ directory: String) -> Bool {
        var current = directory
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }
}

/// The `git status` runs in progress on this Mac, at most one per folder. A
/// request for a folder whose run is still going waits for that run instead
/// of starting another git: a request that gives up at its bound leaves its
/// git running (`GitStatusProvider` cannot stop it), and the next request
/// must not add a second one.
private final class SupermuxGitStatusRuns: @unchecked Sendable {
    static let shared = SupermuxGitStatusRuns()

    private let lock = NSLock()
    private var running: [String: SupermuxGitStatusRun] = [:]

    /// The folder's run in progress, or a new one started now.
    func join(root: String) -> SupermuxGitStatusRun {
        lock.lock()
        defer { lock.unlock() }
        if let run = running[root] { return run }
        let run = SupermuxGitStatusRun()
        running[root] = run
        DispatchQueue.global(qos: .utility).async {
            let statuses = GitStatusProvider().fetchStatus(directory: root)
            self.end(run, for: root)
            run.finish(statuses)
        }
        return run
    }

    private func end(_ run: SupermuxGitStatusRun, for root: String) {
        lock.lock()
        if running[root] === run { running[root] = nil }
        lock.unlock()
    }
}

/// One `git status` run; any number of requests wait for it.
private final class SupermuxGitStatusRun: @unchecked Sendable {
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var statuses: [String: GitFileStatus] = [:]

    init() {
        finished.enter()
    }

    func finish(_ statuses: [String: GitFileStatus]) {
        lock.lock()
        self.statuses = statuses
        lock.unlock()
        finished.leave()
    }

    /// The run's result, or `nil` while it is still going after `seconds`.
    func wait(seconds: TimeInterval) -> [String: GitFileStatus]? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }
}
