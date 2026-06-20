public import Foundation

/// Typed failure surface for ``SupermuxFileSystemOperations``.
///
/// The domain layer stays free of user-facing strings: each case carries only
/// the data the app layer needs to build a localized message. `Equatable` so
/// unit tests can assert the exact failure.
public enum SupermuxFileSystemOperationError: Error, Equatable, Sendable {
    /// The requested name was empty, contained a path separator, or was `.`/`..`.
    case invalidName(String)
    /// An item with that name already exists in the destination directory.
    case alreadyExists(name: String)
    /// The source item no longer exists on disk.
    case notFound(path: String)
    /// The underlying `FileManager` call failed; `reason` is its description.
    case failed(reason: String)
}

/// Pure filesystem create / rename / duplicate / trash operations backing the
/// supermux file-explorer context-menu commands.
///
/// Stateless static functions over `FileManager.default`, so they are trivially
/// unit-testable against a temporary directory. All naming rules and collision
/// handling live here (not in the AppKit glue) to keep the behavior verifiable
/// without a running app.
public enum SupermuxFileSystemOperations {
    /// Normalizes and validates a single path component (a file or folder name).
    ///
    /// Trims surrounding whitespace and rejects names that are empty, contain a
    /// `/` or NUL, or are `.`/`..` — anything that would not be a single legal
    /// directory entry.
    public static func validatedName(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".."
        else {
            throw SupermuxFileSystemOperationError.invalidName(rawName)
        }
        return trimmed
    }

    /// Creates an empty file named `rawName` inside `directory`.
    /// - Returns: the URL of the created file.
    @discardableResult
    public static func createFile(named rawName: String, in directory: URL) throws -> URL {
        let name = try validatedName(rawName)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SupermuxFileSystemOperationError.alreadyExists(name: name)
        }
        do {
            try Data().write(to: destination, options: .withoutOverwriting)
        } catch {
            throw SupermuxFileSystemOperationError.failed(reason: error.localizedDescription)
        }
        return destination
    }

    /// Creates a directory named `rawName` inside `directory`.
    /// - Returns: the URL of the created directory.
    @discardableResult
    public static func createDirectory(named rawName: String, in directory: URL) throws -> URL {
        let name = try validatedName(rawName)
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SupermuxFileSystemOperationError.alreadyExists(name: name)
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw SupermuxFileSystemOperationError.failed(reason: error.localizedDescription)
        }
        return destination
    }

    /// Renames the item at `url` to `rawName`, keeping it in the same directory.
    ///
    /// A no-op rename to the identical name returns `url` unchanged. A rename
    /// that differs only in letter case (on a case-insensitive volume) is allowed
    /// through; a genuine collision with a different item throws `.alreadyExists`.
    /// - Returns: the URL of the renamed item.
    @discardableResult
    public static func rename(_ url: URL, to rawName: String) throws -> URL {
        let name = try validatedName(rawName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw SupermuxFileSystemOperationError.notFound(path: url.path)
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        if destination.standardizedFileURL == url.standardizedFileURL {
            return url
        }
        let isCaseOnlyRename = destination.path.lowercased() == url.path.lowercased()
        if !isCaseOnlyRename, fileManager.fileExists(atPath: destination.path) {
            throw SupermuxFileSystemOperationError.alreadyExists(name: name)
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            throw SupermuxFileSystemOperationError.failed(reason: error.localizedDescription)
        }
        return destination
    }

    /// Duplicates the item at `url` next to it with a Finder-style " copy" name.
    /// - Returns: the URL of the duplicate.
    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw SupermuxFileSystemOperationError.notFound(path: url.path)
        }
        let destination = uniqueCopyDestination(for: url, fileManager: fileManager)
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw SupermuxFileSystemOperationError.failed(reason: error.localizedDescription)
        }
        return destination
    }

    /// Moves each URL to the user's Trash, stopping at the first failure.
    public static func moveToTrash(_ urls: [URL]) throws {
        let fileManager = FileManager.default
        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                throw SupermuxFileSystemOperationError.notFound(path: url.path)
            }
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw SupermuxFileSystemOperationError.failed(reason: error.localizedDescription)
            }
        }
    }

    /// Computes a non-colliding " copy" destination for `url`, preserving the
    /// file extension: `name copy.ext`, then `name copy 2.ext`, and so on.
    ///
    /// Duplicating an already-suffixed copy increments the counter (Finder
    /// parity): `report copy.md` → `report copy 2.md`, not `report copy copy.md`.
    public static func uniqueCopyDestination(for url: URL, fileManager: FileManager = .default) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let fullBase = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let stem = copyStem(from: fullBase)

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            return directory.appendingPathComponent(name)
        }

        var destination = candidate(" copy")
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = candidate(" copy \(counter)")
            counter += 1
        }
        return destination
    }

    /// Strips a trailing " copy" or " copy N" so re-duplicating a copy continues
    /// the " copy 2", " copy 3" sequence instead of stacking " copy copy".
    private static func copyStem(from base: String) -> String {
        guard let range = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) else {
            return base
        }
        return String(base[..<range.lowerBound])
    }
}
