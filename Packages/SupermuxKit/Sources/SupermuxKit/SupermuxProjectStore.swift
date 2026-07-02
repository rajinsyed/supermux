import Darwin
public import Foundation

/// Repository mediating the supermux projects JSON file on disk.
///
/// All reads and writes go through this actor so concurrent in-process
/// mutations cannot interleave, and ``update(_:)`` additionally holds a
/// cross-process file lock because the projects file is intentionally shared
/// across stable/nightly/DEV builds that can run simultaneously. Writes are
/// atomic (rename-into-place) and the parent directory is created on demand.
/// The file location is injected so tests can point the store at a temporary
/// directory.
///
/// ```swift
/// let store = SupermuxProjectStore(fileURL: SupermuxPaths.defaultProjectsFileURL)
/// var file = await store.load()
/// file.projects.append(project)
/// try await store.save(file)
/// ```
public actor SupermuxProjectStore {
    /// Why the most recent disk read fell back to ``SupermuxProjectsFile/empty``.
    public enum LoadFailure: Equatable, Sendable {
        /// The bytes did not decode; they were quarantined at `backupURL`
        /// (`nil` when even the backup write failed).
        case corrupted(backupURL: URL?)
        /// The file exists but could not be read (permissions, I/O error).
        case unreadable(message: String)
    }

    private let fileURL: URL
    private var cached: SupermuxProjectsFile?
    /// Set when the last read fell back to `.empty` for a reason other than
    /// "file does not exist"; cleared by a successful read or save. Lets the
    /// model tell the user their list was reset (and where the backup went)
    /// instead of failing silently.
    public private(set) var lastLoadFailure: LoadFailure?

    /// Creates a store backed by the given file.
    /// - Parameter fileURL: Location of the projects JSON document.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the document, returning ``SupermuxProjectsFile/empty`` when the
    /// file is missing or unreadable. A corrupt (undecodable) file is preserved
    /// on disk as a timestamped `.corrupt-<epoch>` sibling for inspection
    /// rather than silently overwritten; check ``lastLoadFailure`` to
    /// distinguish a genuinely empty document from a fallback.
    public func load() -> SupermuxProjectsFile {
        if let cached { return cached }
        do {
            let file = try loadFromDisk()
            cached = file
            return file
        } catch {
            // A transient read failure must not pin an empty document for the
            // process lifetime: return .empty WITHOUT caching so a later read
            // can recover once the file is readable again.
            return .empty
        }
    }

    /// Reads and decodes the document, distinguishing the three failure modes:
    /// a missing file is a clean `.empty`; undecodable bytes are quarantined
    /// and decode as `.empty` (the user's data is preserved on disk); a read
    /// error (permissions, I/O) throws so callers never treat an intact
    /// on-disk document as empty — and never save over it.
    private func loadFromDisk() throws -> SupermuxProjectsFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            lastLoadFailure = nil
            return .empty
        } catch {
            lastLoadFailure = .unreadable(message: error.localizedDescription)
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(SupermuxProjectsFile.self, from: data)
            lastLoadFailure = nil
            return file
        } catch {
            // Keep the bad bytes around so the user's project list is
            // recoverable by hand instead of being clobbered by the next save.
            lastLoadFailure = .corrupted(backupURL: quarantineCorruptBytes(data))
            return .empty
        }
    }

    /// Writes `data` to a fresh timestamped `.corrupt-<epoch>` sibling of the
    /// document, never overwriting an earlier backup. Returns the backup
    /// location, or `nil` when no backup could be written.
    private func quarantineCorruptBytes(_ data: Data) -> URL? {
        let epoch = Int(Date().timeIntervalSince1970)
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "corrupt-\(epoch)" : "corrupt-\(epoch)-\(attempt)"
            let backupURL = URL(fileURLWithPath: fileURL.path + ".\(suffix)")
            if (try? data.write(to: backupURL, options: .withoutOverwriting)) != nil {
                return backupURL
            }
        }
        return nil
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
        lastLoadFailure = nil
    }

    /// Applies a mutation to the latest on-disk document and saves the result.
    ///
    /// The current file is re-read from disk first (bypassing the in-memory
    /// cache) and the whole read-modify-write runs under an exclusive
    /// cross-process file lock, so a concurrent process — the projects file is
    /// intentionally shared across stable/nightly/DEV builds — does not get
    /// its writes silently clobbered by an interleaved read-modify-write.
    /// Mutations must therefore be *semantic* (edit the freshly-read document)
    /// rather than wholesale snapshot assignments.
    ///
    /// A document written by a newer build keeps its higher `version` number
    /// instead of being stamped down. (Top-level keys unknown to this build
    /// are still dropped by re-encoding; see ``SupermuxProjectsFile``.)
    /// - Parameter mutate: In-place transformation of the document.
    /// - Returns: The document after the mutation.
    /// - Throws: Any error from reading the intact document, locking, or
    ///   ``save(_:)``. A transient read failure aborts the update rather than
    ///   saving a mutated empty document over the user's data.
    @discardableResult
    public func update(_ mutate: @Sendable (inout SupermuxProjectsFile) -> Void) async throws -> SupermuxProjectsFile {
        cached = nil
        let lockFD = try await acquireExclusiveFileLock()
        defer { releaseExclusiveFileLock(lockFD) }
        var file = try loadFromDisk()
        mutate(&file)
        file.version = max(file.version, SupermuxProjectsFile.currentVersion)
        try save(file)
        return file
    }

    /// Takes an exclusive cross-process lock for the read-modify-write cycle.
    ///
    /// The lock lives on a sidecar `.lock` file (never renamed) because the
    /// document itself is replaced by an atomic rename on every save, so an
    /// flock on the document's fd would reference a dead inode after the first
    /// write. The lock is taken non-blockingly with a backoff retry loop, so a
    /// contended wait suspends the actor instead of pinning a cooperative-pool
    /// thread; holders only ever perform one small read-decode-encode-write
    /// cycle, so contention is brief. Cancellation during the wait surfaces
    /// through the caller (the model's persist catch path).
    private func acquireExclusiveFileLock() async throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Self.posixError("open", code: errno) }
        var delay: UInt64 = 10_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw Self.posixError("flock", code: code)
            }
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                close(fd)
                throw error
            }
            delay = min(delay * 2, 250_000_000)
        }
        return fd
    }

    private func releaseExclusiveFileLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    private static func posixError(_ operation: String, code: Int32) -> any Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
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
