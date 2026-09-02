public import Foundation

/// A prompt that travels through a file instead of inline on the launch line.
///
/// The launch line is written into a just-spawned shell's pty while that tty
/// is still in canonical mode, and macOS silently discards canonical input
/// beyond MAX_CANON (1024 bytes) — the shell then sees a truncated line with
/// an unterminated quote and never runs anything. Long prompts are therefore
/// saved to a file and the (short) line reads them from there.
public struct SupermuxAgentPromptFile: Equatable, Sendable {
    /// Where the prompt is (or will be) written.
    public var url: URL
    /// The exact prompt text the file holds.
    public var contents: String

    /// Creates a prompt file description.
    public init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }
}

/// Writes prompt files privately and keeps the directory from growing forever.
public enum SupermuxAgentPromptFileStore {
    /// Prompt files older than this are removed on the next write.
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Writes `file` (creating its directory) with owner-only permissions and
    /// prunes sibling files older than ``retentionInterval``.
    /// - Parameter fileManager: Injectable for tests.
    public static func write(_ file: SupermuxAgentPromptFile, fileManager: FileManager = .default) throws {
        let directory = file.url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(file.contents.utf8).write(to: file.url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        prune(directory: directory, keeping: file.url, fileManager: fileManager)
    }

    /// The extension every prompt file carries; pruning touches nothing else.
    static let fileExtension = "txt"

    /// Removes stale prompt files only: regular `.txt` files past
    /// ``retentionInterval``. Directories and other files are left alone.
    private static func prune(directory: URL, keeping current: URL, fileManager: FileManager) {
        let cutoff = Date(timeIntervalSinceNow: -retentionInterval)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let siblings = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        for sibling in siblings where sibling.lastPathComponent != current.lastPathComponent {
            guard sibling.pathExtension == fileExtension,
                  let values = try? sibling.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: sibling)
        }
    }
}
