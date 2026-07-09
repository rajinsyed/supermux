import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The `mobile.supermux.files.*` half of ``FakeSupermuxMacClient``, served
/// from the mutable `filesTree` fixture — split from the main file to
/// respect the per-file length budget. Behavior is byte-identical to the
/// pre-split methods; recording goes through the main file's `record` seams.
extension FakeSupermuxMacClient {
    func filesList(_ request: SupermuxFilesListRequest) async throws -> SupermuxFilesListResponse {
        record("filesList", method: request.wireMethod, params: request.wireParams)
        if let filesListError { throw filesListError }
        let path = request.path ?? ""
        guard let entries = filesTree[path] else {
            throw MobileShellConnectionError.rpcError(
                "not_found",
                "No such directory: \(path)"
            )
        }
        return SupermuxFilesListResponse(path: path, entries: entries)
    }

    func filesCreate(_ request: SupermuxFilesCreateRequest) async throws -> SupermuxFilesMutationResponse {
        record("filesCreate", method: request.wireMethod, params: request.wireParams)
        if let filesCreateError { throw filesCreateError }
        let (parent, name) = splitFilesPath(request.path)
        let isFolder = request.kind == .folder
        filesTree[parent, default: []].append(
            SupermuxFileEntryDTO(name: name, isDir: isFolder, isSymlink: false)
        )
        if isFolder {
            filesTree[request.path] = []
        }
        return SupermuxFilesMutationResponse(ok: true, path: request.path)
    }

    func filesRename(_ request: SupermuxFilesRenameRequest) async throws -> SupermuxFilesMutationResponse {
        record("filesRename", method: request.wireMethod, params: request.wireParams)
        if let filesRenameError { throw filesRenameError }
        let (parent, name) = splitFilesPath(request.path)
        filesTree[parent] = (filesTree[parent] ?? []).map { entry in
            guard entry.name == name else { return entry }
            var renamed = entry
            renamed.name = request.newName
            return renamed
        }
        let newPath = parent.isEmpty ? request.newName : parent + "/" + request.newName
        return SupermuxFilesMutationResponse(ok: true, path: newPath)
    }

    func filesDuplicate(_ request: SupermuxFilesDuplicateRequest) async throws -> SupermuxFilesMutationResponse {
        record("filesDuplicate", method: request.wireMethod, params: request.wireParams)
        if let filesDuplicateError { throw filesDuplicateError }
        let (parent, name) = splitFilesPath(request.path)
        guard let entry = filesTree[parent]?.first(where: { $0.name == name }) else {
            throw MobileShellConnectionError.rpcError(
                "not_found",
                "No such entry: \(request.path)"
            )
        }
        var copy = entry
        copy.name = name + " copy"
        filesTree[parent, default: []].append(copy)
        let copyPath = parent.isEmpty ? copy.name : parent + "/" + copy.name
        return SupermuxFilesMutationResponse(ok: true, path: copyPath)
    }

    func filesTrash(_ request: SupermuxFilesTrashRequest) async throws -> SupermuxFilesMutationResponse {
        record("filesTrash", method: request.wireMethod, params: request.wireParams)
        if let filesTrashError { throw filesTrashError }
        for path in request.paths {
            let (parent, name) = splitFilesPath(path)
            filesTree[parent]?.removeAll { $0.name == name }
        }
        return SupermuxFilesMutationResponse(ok: true)
    }

    /// Splits a root-relative path into its parent directory ("" = root) and
    /// entry name.
    private func splitFilesPath(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}
