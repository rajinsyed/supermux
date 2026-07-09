public import Foundation
public import SupermuxMobileCore

/// Typed failure surface for ``SupermuxMobileFileBrowser``.
///
/// `Equatable` so unit tests can assert the exact failure; the wire mapping
/// to `code/message` error objects lives in ``SupermuxMobileFilesWireFailure``.
public enum SupermuxMobileFileBrowserError: Error, Equatable, Sendable {
    /// The root itself is missing or not a directory (maps to `unavailable`).
    case rootUnavailable(path: String)
    /// The request's path resolves outside the root — `..` traversal or a
    /// symlink escape (maps to `invalid_params`).
    case pathOutsideRoot(path: String)
    /// The request's path is malformed for the operation, e.g. listing a
    /// regular file or mutating the root itself (maps to `invalid_params`).
    case invalidPath(path: String)
    /// No entry exists at the request's path (maps to `not_found`).
    case notFound(path: String)
}

/// The confinement engine behind the `mobile.supermux.files.*` RPCs
/// (architecture §10): every request path is root-relative, canonicalized
/// (symlinks fully resolved) and rejected unless the resolution stays inside
/// the canonical root. Operations reuse ``SupermuxFileSystemOperations`` —
/// the exact engine behind the desktop file-explorer commands — so deletion
/// is Trash, never `rm`.
///
/// Listing mirrors the desktop file explorer's defaults: dotfiles are hidden
/// (`FileExplorerStore.showHiddenFiles` defaults to `false`) and entries sort
/// directories-first, then case-insensitively by name.
public struct SupermuxMobileFileBrowser: Sendable {
    /// The canonical (symlink-resolved) absolute root path. All request
    /// paths resolve relative to this and must stay inside it.
    public let rootPath: String

    /// Creates a browser confined to `rootPath` (a workspace's current
    /// directory or a project's `root_path`).
    /// - Throws: ``SupermuxMobileFileBrowserError/rootUnavailable(path:)``
    ///   when the root does not exist or is not a directory.
    public init(rootPath: String) throws {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SupermuxMobileFileBrowserError.rootUnavailable(path: rootPath)
        }
        self.rootPath = canonical
    }

    // MARK: - files.list

    /// Lists the children of the directory at root-relative `path`
    /// (`nil`/empty = the root itself), dotfiles excluded, directories first
    /// then case-insensitive by name (the desktop file-explorer order).
    public func list(path: String?) throws -> [SupermuxFileEntryDTO] {
        let directory = try resolveExisting(path ?? "", allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SupermuxMobileFileBrowserError.invalidPath(path: path ?? "")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { entry(named: $0, in: directory) }
            .sorted { a, b in
                if (a.isDir ?? false) != (b.isDir ?? false) { return a.isDir ?? false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// The `files.list` result payload: `{path, entries}` with snake_case
    /// ``SupermuxFileEntryDTO`` objects (`path` echoes the normalized
    /// root-relative directory, `""` for the root).
    public func listPayload(path: String?) throws -> [String: Any] {
        let directory = try resolveExisting(path ?? "", allowRoot: true)
        let wire = SupermuxWireJSON()
        return [
            "path": relativePath(of: directory),
            "entries": try list(path: path).map { try wire.dictionary(from: $0) },
        ]
    }

    // MARK: - files.create

    /// Creates an empty file at root-relative `path` (parent must exist
    /// inside the root). - Returns: the created entry's root-relative path.
    @discardableResult
    public func createFile(at path: String) throws -> String {
        let (parent, name) = try resolveForCreate(path)
        return relativePath(of: try SupermuxFileSystemOperations.createFile(named: name, in: parent))
    }

    /// Creates a directory at root-relative `path` (parent must exist inside
    /// the root). - Returns: the created entry's root-relative path.
    @discardableResult
    public func createFolder(at path: String) throws -> String {
        let (parent, name) = try resolveForCreate(path)
        return relativePath(
            of: try SupermuxFileSystemOperations.createDirectory(named: name, in: parent)
        )
    }

    // MARK: - files.rename

    /// Renames the entry at root-relative `path` to `newName` (a single
    /// component). - Returns: the entry's new root-relative path.
    @discardableResult
    public func rename(path: String, to newName: String) throws -> String {
        let url = try resolveExisting(path, allowRoot: false)
        return relativePath(of: try SupermuxFileSystemOperations.rename(url, to: newName))
    }

    // MARK: - files.duplicate

    /// Duplicates the entry at root-relative `path` next to itself with a
    /// Finder-style " copy" name. - Returns: the copy's root-relative path.
    @discardableResult
    public func duplicate(path: String) throws -> String {
        let url = try resolveExisting(path, allowRoot: false)
        return relativePath(of: try SupermuxFileSystemOperations.duplicate(url))
    }

    // MARK: - files.trash

    /// Moves the entries at root-relative `paths` to the Trash (never `rm`).
    ///
    /// Validation is batch-first: EVERY path is resolved and confined before
    /// anything is touched, so one escaping path rejects the whole request
    /// with no filesystem effect. Already-missing entries are skipped
    /// (idempotent), matching ``SupermuxFileSystemOperations/moveToTrash(_:fileManager:)``.
    public func trash(paths: [String]) throws {
        var resolved: [URL] = []
        for path in paths {
            do {
                resolved.append(try resolveExisting(path, allowRoot: false))
            } catch SupermuxMobileFileBrowserError.notFound {
                continue
            }
        }
        let topLevel = SupermuxFileSystemOperations.topLevelPaths(resolved.map(\.path))
        try SupermuxFileSystemOperations.moveToTrash(topLevel.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Confinement

    /// Resolves a root-relative path to the on-disk entry it names, throwing
    /// unless the entry exists and its FULL symlink resolution stays inside
    /// the root. The returned URL preserves a final symlink component that
    /// resolves inside the root (operations act on the entry, like the
    /// desktop explorer), while any resolution escaping the root — via `..`
    /// or a symlink — is rejected before it can be operated on.
    private func resolveExisting(_ relativePath: String, allowRoot: Bool) throws -> URL {
        let standardized = standardizedAbsolutePath(for: relativePath)
        guard standardized == rootPath
                || SupermuxFileSystemOperations.pathIsAncestor(rootPath, of: standardized) else {
            throw SupermuxMobileFileBrowserError.pathOutsideRoot(path: relativePath)
        }
        if standardized == rootPath {
            guard allowRoot else {
                throw SupermuxMobileFileBrowserError.invalidPath(path: relativePath)
            }
            return URL(fileURLWithPath: standardized, isDirectory: true)
        }
        guard (try? FileManager.default.attributesOfItem(atPath: standardized)) != nil else {
            throw SupermuxMobileFileBrowserError.notFound(path: relativePath)
        }
        // Canonicalize BEFORE the confinement decision: a symlink anywhere in
        // the path pointing outside the root must reject the request.
        let canonical = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        guard canonical == rootPath
                || SupermuxFileSystemOperations.pathIsAncestor(rootPath, of: canonical) else {
            throw SupermuxMobileFileBrowserError.pathOutsideRoot(path: relativePath)
        }
        return URL(fileURLWithPath: standardized)
    }

    /// Splits a root-relative create path into its (existing, confined)
    /// parent directory and the new entry's name. The name itself is
    /// validated by ``SupermuxFileSystemOperations/validatedName(_:)`` inside
    /// the create call (rejecting `..`, separators, and empty names).
    private func resolveForCreate(_ relativePath: String) throws -> (parent: URL, name: String) {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SupermuxMobileFileBrowserError.invalidPath(path: relativePath)
        }
        let name = (trimmed as NSString).lastPathComponent
        let parentRelative = (trimmed as NSString).deletingLastPathComponent
        let parent = try resolveExisting(parentRelative, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SupermuxMobileFileBrowserError.invalidPath(path: relativePath)
        }
        return (parent, name)
    }

    /// The standardized absolute path a root-relative request path names
    /// (`..`/`.` collapsed textually; symlink resolution happens separately).
    private func standardizedAbsolutePath(for relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = (rootPath as NSString).appendingPathComponent(trimmed)
        return (combined as NSString).standardizingPath
    }

    /// The root-relative representation of an inside-the-root URL (`""` for
    /// the root itself).
    private func relativePath(of url: URL) -> String {
        let path = (url.path as NSString).standardizingPath
        guard path != rootPath else { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// One directory entry as its wire DTO: flags read without traversing
    /// the entry's own symlink (`is_symlink` from `lstat`-style attributes),
    /// while `is_dir` follows the link so a symlink-to-directory browses as
    /// a directory, exactly like the desktop explorer. `size` travels for
    /// regular files only.
    private func entry(named name: String, in directory: URL) -> SupermuxFileEntryDTO? {
        let url = directory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return SupermuxFileEntryDTO(
            name: name,
            isDir: isDirectory.boolValue,
            isSymlink: type == .typeSymbolicLink,
            size: type == .typeRegular ? (attributes[.size] as? NSNumber)?.intValue : nil,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        )
    }
}

/// Maps engine failures onto the wire's `code/message` error shape so the
/// app-target handler stays a thin pass-through and the `invalid_params`
/// guarantee for confinement violations is package-tested.
public enum SupermuxMobileFilesWireFailure {
    /// The wire `code` and unlocalized developer `message` for one failure.
    public static func classify(_ error: any Error) -> (code: String, message: String) {
        switch error {
        case let browserError as SupermuxMobileFileBrowserError:
            switch browserError {
            case let .rootUnavailable(path):
                return ("unavailable", "Root directory is unavailable: \(path)")
            case let .pathOutsideRoot(path):
                return ("invalid_params", "Path escapes the resolved root: \(path)")
            case let .invalidPath(path):
                return ("invalid_params", "Invalid path for this operation: \(path)")
            case let .notFound(path):
                return ("not_found", "No entry exists at path: \(path)")
            }
        case let operationError as SupermuxFileSystemOperationError:
            switch operationError {
            case let .invalidName(name):
                return ("invalid_params", "Invalid name: \(name)")
            case let .alreadyExists(name):
                return ("invalid_params", "An item named \(name) already exists")
            case let .notFound(path):
                return ("not_found", "No entry exists at path: \(path)")
            case let .failed(reason):
                return ("unavailable", reason)
            }
        default:
            return ("unavailable", error.localizedDescription)
        }
    }
}
