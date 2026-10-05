public import Foundation

/// Copies the images attached to a Start Claude prompt on this Mac into a
/// private folder of their own, where Claude reads them.
///
/// Each launch gets a new folder (`<root>/<uuid>/`, owner-only), so the
/// `--add-dir` Claude is given grants exactly that launch's images. A pasted
/// image starts as a temporary file and a dropped one may move later, so the
/// copy is what the prompt names. Folders older than ``retentionInterval``
/// are removed on the next store.
public struct SupermuxAgentAttachmentStore: Sendable {
    /// Launch folders older than this are removed on the next store.
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// The folder that holds one sub-folder per launch.
    public let rootDirectory: URL

    /// Creates the store.
    /// - Parameter rootDirectory: Where launch folders are created.
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Copies `files` into a new launch folder and returns the copies' paths
    /// in the same order. Two files with one name keep both (`shot-2.png`).
    /// - Parameter files: The attached files.
    /// - Returns: The copies' absolute paths; empty (and no folder) for no files.
    /// - Throws: The file system error of a failed copy.
    public func store(_ files: [URL]) throws -> [String] {
        guard !files.isEmpty else { return [] }
        let fileManager = FileManager()
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let launchName = UUID().uuidString.lowercased()
        prune(keeping: launchName, fileManager: fileManager)
        let folder = rootDirectory.appendingPathComponent(launchName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var used: Set<String> = []
        return try files.map { file in
            let destination = folder.appendingPathComponent(Self.uniqueName(file.lastPathComponent, used: &used))
            try fileManager.copyItem(at: file, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination.path
        }
    }

    /// `name`, or `stem-2.ext`, `stem-3.ext`, … when it is taken.
    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let base = name.isEmpty ? "image" : name
        var candidate = base
        var suffix = 2
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        while !used.insert(candidate.lowercased()).inserted {
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    /// Removes launch folders past ``retentionInterval``; nothing else.
    private func prune(keeping current: String, fileManager: FileManager) {
        let cutoff = Date(timeIntervalSinceNow: -Self.retentionInterval)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where entry.lastPathComponent != current {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}
