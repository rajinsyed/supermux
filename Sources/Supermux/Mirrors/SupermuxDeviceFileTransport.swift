import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The device-link side of a mirror's Files panel: typed `files.*` calls to
/// the owning Mac. Every call names the owner's workspace and pins
/// `expected_root` to the folder the panel shows, so a `cd` there answers
/// `stale_root` instead of another tree. Reply deadlines are the device
/// facade's per-method table, never set here.
@MainActor
final class SupermuxDeviceFileTransport {
    private let devices: SupermuxDevices
    private let root: SupermuxMirrorFileRoot

    init(root: SupermuxMirrorFileRoot, devices: SupermuxDevices) {
        self.root = root
        self.devices = devices
    }

    /// `files.list` with hidden files (the desktop panel always shows them).
    func list(_ path: String) async throws -> SupermuxFileListDTO {
        try await call(.filesList, ["path": path, "show_hidden": true], as: SupermuxFileListDTO.self)
    }

    /// One `files.read` chunk.
    func read(_ path: String, offset: Int, length: Int) async throws -> SupermuxFileReadDTO {
        try await call(.filesRead, ["path": path, "offset": offset, "length": length], as: SupermuxFileReadDTO.self)
    }

    /// `files.search` for a fixed-string query.
    func search(_ query: String) async throws -> SupermuxFileSearchDTO {
        try await call(.filesSearch, ["query": query], as: SupermuxFileSearchDTO.self)
    }

    /// `files.git_status` for the folder.
    func gitStatus() async throws -> SupermuxFileGitStatusDTO {
        try await call(.filesGitStatus, [:], as: SupermuxFileGitStatusDTO.self)
    }

    /// `files.create` (`kind: file | folder`); returns the new entry's path.
    func create(_ path: String, folder: Bool) async throws -> String {
        try await call(.filesCreate, ["path": path, "kind": folder ? "folder" : "file"], as: PathReply.self).path
    }

    /// `files.rename`; returns the entry's new path.
    func rename(_ path: String, to name: String) async throws -> String {
        try await call(.filesRename, ["path": path, "new_name": name], as: PathReply.self).path
    }

    /// `files.duplicate`; returns the copy's path.
    func duplicate(_ path: String) async throws -> String {
        try await call(.filesDuplicate, ["path": path], as: PathReply.self).path
    }

    /// `files.trash` (the Trash on that Mac, never a permanent delete).
    func trash(_ paths: [String]) async throws {
        _ = try await devices.request(SupermuxMobileMethod.filesTrash.rawValue, params: params(["paths": paths]), on: root.machine)
    }

    /// A mutation's `{ok, path}` reply (root-relative path).
    private struct PathReply: Decodable {
        let path: String
    }

    private func call<Response: Decodable>(
        _ method: SupermuxMobileMethod,
        _ extra: [String: Any],
        as type: Response.Type
    ) async throws -> Response {
        try await devices.request(method.rawValue, params: params(extra), on: root.machine, as: type)
    }

    private func params(_ extra: [String: Any]) -> [String: Any] {
        var params = extra
        params["workspace_id"] = root.remoteWorkspaceID
        params["expected_root"] = root.rootPath
        return params
    }
}

/// At most `limit` file calls in flight per panel: expanding a tree fans out
/// one listing per open folder, and the host serves 16 requests per
/// connection, so the panel keeps room for terminal traffic.
actor SupermuxDeviceFileRequestLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits for a free slot.
    func acquire() async {
        guard running >= limit else {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// Frees a slot (hands it straight to the next waiter).
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
