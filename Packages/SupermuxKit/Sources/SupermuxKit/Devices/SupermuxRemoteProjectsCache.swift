public import Foundation
public import SupermuxMobileCore

/// The offline copy of other Macs' project lists, so their projects still
/// render (dimmed, "Offline") while a Mac is unreachable.
///
/// One JSON file keyed by machine wire id (`device:<uuid>@<tag>`), separate
/// from the local projects document (`supermux-projects.json`), which remote
/// projects are never written into. Every write re-reads the file under the
/// cross-build file lock (``SupermuxFileLock``) and replaces only its own
/// machine's entry, so concurrent writers (several Macs refreshed at once, or
/// builds sharing the file) never drop each other's entries. A missing or
/// corrupt file reads as empty.
public struct SupermuxRemoteProjectsCache: Sendable {
    /// One Mac's cached projects.
    public struct Entry: Codable, Sendable, Equatable {
        /// The Mac's friendly name when it was cached.
        public var name: String
        /// Its `projects.list` projects.
        public var projects: [SupermuxProjectDTO]
        /// When the entry was written.
        public var savedAt: Date

        /// Creates an entry.
        public init(name: String, projects: [SupermuxProjectDTO], savedAt: Date) {
            self.name = name
            self.projects = projects
            self.savedAt = savedAt
        }
    }

    private struct Document: Codable {
        var version = 1
        var machines: [String: Entry] = [:]
    }

    /// The cache file.
    public let fileURL: URL

    /// Creates a cache over `fileURL`
    /// (default ``SupermuxPaths/remoteProjectsCacheFileURL``).
    public init(fileURL: URL = SupermuxPaths.remoteProjectsCacheFileURL) {
        self.fileURL = fileURL
    }

    /// Every cached Mac's entry, keyed by machine id; empty when unreadable.
    public func load() -> [String: Entry] {
        readDocument().machines
    }

    /// Replaces one Mac's entry.
    /// - Throws: A lock or file-system error; the file is then unchanged.
    public func save(_ entry: Entry, forMachine machineID: String) async throws {
        try await update { $0[machineID] = entry }
    }

    /// Removes one Mac's entry.
    /// - Throws: A lock or file-system error; the file is then unchanged.
    public func forget(machine machineID: String) async throws {
        try await update { $0.removeValue(forKey: machineID) }
    }

    /// Applies `mutate` to the freshly read entries under the file lock and
    /// writes them back when they changed.
    private func update(_ mutate: (inout [String: Entry]) -> Void) async throws {
        let lock = SupermuxFileLock(documentURL: fileURL)
        let held = try await lock.acquire()
        defer { lock.release(held) }
        var document = readDocument()
        let before = document.machines
        mutate(&document.machines)
        guard document.machines != before else { return }
        try write(document)
    }

    private func readDocument() -> Document {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return document
    }

    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }
}
