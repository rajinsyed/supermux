public import Foundation

/// Repository mediating the supermux projects JSON file on disk.
///
/// All reads and writes go through this actor so concurrent mutations cannot
/// interleave. Writes are atomic (rename-into-place) and the parent directory
/// is created on demand. The file location is injected so tests can point the
/// store at a temporary directory.
///
/// ```swift
/// let store = SupermuxProjectStore(fileURL: SupermuxPaths.defaultProjectsFileURL)
/// var file = await store.load()
/// file.projects.append(project)
/// try await store.save(file)
/// ```
public actor SupermuxProjectStore {
    private let fileURL: URL
    private var cached: SupermuxProjectsFile?

    /// Creates a store backed by the given file.
    /// - Parameter fileURL: Location of the projects JSON document.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the document, returning ``SupermuxProjectsFile/empty`` when the
    /// file is missing or unreadable (a corrupt file is preserved on disk as
    /// `.corrupt` for inspection rather than silently overwritten).
    public func load() -> SupermuxProjectsFile {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL) else {
            cached = .empty
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(SupermuxProjectsFile.self, from: data)
            cached = file
            return file
        } catch {
            // Keep the bad bytes around so the user's project list is
            // recoverable by hand instead of being clobbered by the next save.
            let backupURL = fileURL.appendingPathExtension("corrupt")
            try? data.write(to: backupURL)
            cached = .empty
            return .empty
        }
    }

    /// Persists the document atomically.
    /// - Parameter file: The document to write.
    /// - Throws: Any file-system error from creating the directory or writing.
    public func save(_ file: SupermuxProjectsFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        cached = file
    }

    /// Applies a mutation to the latest on-disk document and saves the result.
    ///
    /// The current file is re-read from disk first (bypassing the in-memory
    /// cache) so a concurrent process — the projects file is intentionally
    /// shared across stable/nightly/DEV builds — does not get its newly added
    /// projects silently clobbered by a stale-cache write.
    /// - Parameter mutate: In-place transformation of the document.
    /// - Returns: The document after the mutation.
    /// - Throws: Any error from ``save(_:)``.
    @discardableResult
    public func update(_ mutate: @Sendable (inout SupermuxProjectsFile) -> Void) throws -> SupermuxProjectsFile {
        cached = nil
        var file = load()
        mutate(&file)
        file.version = SupermuxProjectsFile.currentVersion
        try save(file)
        return file
    }
}

/// Well-known file locations for supermux state.
public enum SupermuxPaths {
    /// The default projects document: `~/Library/Application Support/cmux/supermux-projects.json`.
    ///
    /// Lives next to (not inside) cmux's session snapshot so projects survive
    /// session resets and are shared by stable, nightly, and DEV builds.
    public static var defaultProjectsFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("cmux/supermux-projects.json")
    }
}
