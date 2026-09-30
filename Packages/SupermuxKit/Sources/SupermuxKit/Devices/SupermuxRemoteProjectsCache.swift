public import Foundation
public import SupermuxMobileCore

/// The offline copy of other Macs' project lists, so their projects still
/// render (dimmed, "Offline") while a Mac is unreachable.
///
/// One JSON file keyed by machine wire id (`device:<uuid>@<tag>`), separate
/// from the local projects document (`supermux-projects.json`), which remote
/// projects are never written into. Every write re-reads the file and
/// replaces only its own machine's entry, so builds sharing the file do not
/// drop each other's entries. A missing or corrupt file reads as empty.
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
    public func save(_ entry: Entry, forMachine machineID: String) throws {
        var document = readDocument()
        document.machines[machineID] = entry
        try write(document)
    }

    /// Removes one Mac's entry.
    public func forget(machine machineID: String) throws {
        var document = readDocument()
        guard document.machines.removeValue(forKey: machineID) != nil else { return }
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
