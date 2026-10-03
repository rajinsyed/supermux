public import Foundation

/// Project roots a user removed from Projects, so cross-Mac project sync
/// never registers them again (another Mac that still has the project reads
/// this through `project.probe`'s `is_suppressed`). Registering the folder
/// again on this Mac clears it.
///
/// Kept in one JSON file next to the projects document
/// (``SupermuxPaths/projectSyncSuppressionFileURL``) that every build on this
/// Mac shares, like the projects document itself, so a removal made in one
/// build (stable, nightly or a tagged DEV build) holds in all of them. Reads
/// go to disk, so other builds' writes are seen; each write re-reads the file
/// under the cross-build file lock (``SupermuxFileLock``). A missing or
/// corrupt file reads as empty. Overlapping writes apply in lock order;
/// callers that need call order await each write before the next.
///
/// ```swift
/// let suppression = SupermuxProjectSyncSuppression()
/// try await suppression.suppress(rootPath: removed.rootPath)
/// let skip = await suppression.isSuppressed(rootPath: candidate.rootPath)
/// ```
public actor SupermuxProjectSyncSuppression {
    /// Oldest entries are dropped past this many roots.
    public static let capacity = 256

    private struct Document: Codable {
        var version = 1
        var roots: [String] = []
    }

    /// The suppression file.
    public nonisolated let fileURL: URL

    /// Creates the store over `fileURL`.
    /// - Parameter fileURL: The shared suppression file (default
    ///   ``SupermuxPaths/projectSyncSuppressionFileURL``); tests pass a temp file.
    public init(fileURL: URL = SupermuxPaths.projectSyncSuppressionFileURL) {
        self.fileURL = fileURL
    }

    /// Whether sync must skip `rootPath`.
    /// - Parameter rootPath: Any spelling of the root; it is standardized.
    public func isSuppressed(rootPath: String) -> Bool {
        readDocument().roots.contains(Self.key(rootPath))
    }

    /// Records that the user removed the project at `rootPath`.
    /// - Parameter rootPath: The removed project's root.
    /// - Throws: A lock or file-system error; the file is then unchanged.
    public func suppress(rootPath: String) async throws {
        let key = Self.key(rootPath)
        try await update { roots in
            guard !roots.contains(key) else { return }
            roots = Array((roots + [key]).suffix(Self.capacity))
        }
    }

    /// Forgets a suppression (the folder was registered on this Mac again).
    /// - Parameter rootPath: The registered project's root.
    /// - Throws: A lock or file-system error; the file is then unchanged.
    public func clear(rootPath: String) async throws {
        let key = Self.key(rootPath)
        try await update { roots in roots.removeAll { $0 == key } }
    }

    /// Applies `mutate` to the freshly read roots under the file lock and
    /// writes them back when they changed.
    private func update(_ mutate: (inout [String]) -> Void) async throws {
        let lock = SupermuxFileLock(documentURL: fileURL)
        let held = try await lock.acquire()
        defer { lock.release(held) }
        var document = readDocument()
        let before = document.roots
        mutate(&document.roots)
        guard document.roots != before else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    private func readDocument() -> Document {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return document
    }

    private static func key(_ rootPath: String) -> String {
        (rootPath as NSString).standardizingPath
    }
}
