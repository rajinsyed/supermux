import Foundation
import SupermuxMobileCore

/// The Files panel's provider for a device mirror: the owning Mac's folder,
/// read over the device link (`supermux.files_read.v1`). The store hands it
/// absolute paths in the folder's own spelling; it sends them root-relative
/// and the host confines every one to the workspace's folder.
///
/// The identity (Mac, workspace, folder) is immutable, so a `cd` over there
/// builds a new provider. Opening a file downloads it in chunks into the
/// read-only preview cache (``previewLimit``), search runs ripgrep over
/// there, and git colors come from that Mac's own `git status`.
final class SupermuxDeviceFileExplorerProvider: RemoteFileExplorerProvider, @unchecked Sendable {
    /// The largest file a preview copies to this Mac.
    static let previewLimit = 8 * 1024 * 1024
    /// Bytes asked for per `files.read` (the host's own cap).
    static let chunkLength = 512 * 1024

    let root: SupermuxMirrorFileRoot
    private let transport: SupermuxDeviceFileTransport
    private let limiter = SupermuxDeviceFileRequestLimiter(limit: 4)
    private let searchQueue = CloudFileExplorerSearchQueue()
    private let homeLock = NSLock()
    private var learnedHome = ""

    @MainActor
    init(root: SupermuxMirrorFileRoot, devices: SupermuxDevices) {
        self.root = root
        transport = SupermuxDeviceFileTransport(root: root, devices: devices)
    }

    // MARK: - FileExplorerProvider

    /// The owning Mac's home folder, learned from the first listing (so the
    /// header reads `~/project` like the local panel).
    var homePath: String {
        homeLock.lock()
        defer { homeLock.unlock() }
        return learnedHome
    }

    var isAvailable: Bool { true }

    nonisolated var displayTarget: String { root.deviceName }

    nonisolated var remoteIdentity: String {
        "supermux-device:\(root.machine.rawValue)|\(root.remoteWorkspaceID)|\(root.rootPath)"
    }

    nonisolated func resolveHomePath() async throws -> String {
        if !homePath.isEmpty { return homePath }
        _ = try await listDirectory(path: root.rootPath, showHidden: true)
        return homePath
    }

    /// Lists a folder over there. Hidden files always travel (the host lists
    /// them as the desktop panel does); the store asks with hidden files on.
    nonisolated func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let relative = try relativePath(path)
        let transport = self.transport
        let listing = try await limited { try await transport.list(relative) }
        if let home = listing.home, !home.isEmpty { learnHome(home) }
        return listing.entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .map { FileExplorerEntry(name: $0.name, path: Self.join(path, $0.name), isDirectory: $0.isDir ?? false) }
    }

    /// Copies a file into the preview cache chunk by chunk. A file that
    /// changes while it is read is read again once; one over
    /// ``previewLimit`` is refused before any of it is copied.
    nonisolated func downloadFile(path: String, to localURL: URL) async throws {
        let relative = try relativePath(path)
        var data = try await readWhole(relative, restartOnChange: true)
        if data == nil { data = try await readWhole(relative, restartOnChange: false) }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data()).write(to: localURL, options: .atomic)
    }

    // MARK: - Search and git colors

    /// Searches the folder over there; the newest query replaces a pending one.
    nonisolated func search(query: String, rootPath: String) async throws -> FileSearchSnapshot {
        let transport = self.transport
        return try await searchQueue.submit { [self] in
            let found = try await limited { try await transport.search(query) }
            let results = found.results.map {
                FileSearchResult(
                    path: Self.join(rootPath, $0.path), relativePath: $0.path,
                    lineNumber: $0.line, columnNumber: $0.column, preview: $0.preview
                )
            }
            let status: FileSearchSnapshot.Status
            if found.status == "limited" {
                status = .limited(found.limit ?? results.count)
            } else {
                status = results.isEmpty ? .noMatches : .matches
            }
            return FileSearchSnapshot(query: query, results: results, status: status, isSearching: false)
        }
    }

    /// The git colors for the folder, keyed like the store's nodes; empty when
    /// that Mac cannot answer.
    nonisolated func gitStatus() async -> [String: GitFileStatus] {
        let transport = self.transport
        guard let reply = try? await limited({ try await transport.gitStatus() }) else { return [:] }
        var statuses: [String: GitFileStatus] = [:]
        for entry in reply.statuses {
            guard let status = Self.gitFileStatus(entry.status) else { continue }
            statuses[Self.join(root.rootPath, entry.path)] = status
        }
        return statuses
    }

    // MARK: - File operations (the panel's New File, Rename, Duplicate, Trash)

    /// Creates an empty file or a folder at an absolute path; returns its path.
    nonisolated func create(at path: String, folder: Bool) async throws -> String {
        let relative = try relativePath(path)
        let transport = self.transport
        let created = try await limited { try await transport.create(relative, folder: folder) }
        return Self.join(root.rootPath, created)
    }

    /// Renames an entry; returns its new absolute path.
    nonisolated func rename(_ path: String, to name: String) async throws -> String {
        let relative = try relativePath(path)
        let transport = self.transport
        let renamed = try await limited { try await transport.rename(relative, to: name) }
        return Self.join(root.rootPath, renamed)
    }

    /// Duplicates an entry next to itself; returns the copy's absolute path.
    nonisolated func duplicate(_ path: String) async throws -> String {
        let relative = try relativePath(path)
        let transport = self.transport
        let copy = try await limited { try await transport.duplicate(relative) }
        return Self.join(root.rootPath, copy)
    }

    /// Moves entries to the Trash on that Mac.
    nonisolated func trash(_ paths: [String]) async throws {
        let relative = try paths.map(relativePath)
        let transport = self.transport
        try await limited { try await transport.trash(relative) }
    }

    // MARK: - Helpers

    /// A full read, or `nil` when the file changed under it and
    /// `restartOnChange` asks for another try.
    private func readWhole(_ relative: String, restartOnChange: Bool) async throws -> Data? {
        let transport = self.transport
        var data = Data()
        var first: SupermuxFileReadDTO?
        while true {
            try Task.checkCancellation()
            let offset = data.count
            let chunk = try await limited { try await transport.read(relative, offset: offset, length: Self.chunkLength) }
            if let first, chunk.size != first.size || chunk.modifiedAt != first.modifiedAt {
                if restartOnChange { return nil }
            }
            guard chunk.size <= Self.previewLimit else {
                throw SupermuxDeviceFileError.tooLarge(deviceName: root.deviceName)
            }
            guard let bytes = Data(base64Encoded: chunk.data) else {
                throw SupermuxDeviceError.malformedResponse(SupermuxMobileMethod.filesRead.rawValue)
            }
            first = first ?? chunk
            data.append(bytes)
            if chunk.eof || bytes.isEmpty { return data }
            if data.count > Self.previewLimit {
                throw SupermuxDeviceFileError.tooLarge(deviceName: root.deviceName)
            }
        }
    }

    /// Runs one call inside the panel's concurrency limit, mapping a host
    /// refusal to a sentence that names the Mac.
    private func limited<Value: Sendable>(_ body: () async throws -> Value) async throws -> Value {
        await limiter.acquire()
        do {
            let value = try await body()
            await limiter.release()
            return value
        } catch {
            await limiter.release()
            throw SupermuxDeviceFileError.from(error, deviceName: root.deviceName)
        }
    }

    /// The root-relative form of an absolute path in the folder's spelling.
    private func relativePath(_ path: String) throws -> String {
        let base = root.rootPath
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else {
            throw SupermuxDeviceFileError.outsideFolder(deviceName: root.deviceName)
        }
        return String(path.dropFirst(prefix.count))
    }

    private func learnHome(_ home: String) {
        homeLock.lock()
        learnedHome = home
        homeLock.unlock()
    }

    private static func join(_ base: String, _ relative: String) -> String {
        relative.isEmpty ? base : (base as NSString).appendingPathComponent(relative)
    }

    private static func gitFileStatus(_ name: String) -> GitFileStatus? {
        switch name {
        case "modified": return .modified
        case "added": return .added
        case "deleted": return .deleted
        case "renamed": return .renamed
        case "untracked": return .untracked
        default: return nil
        }
    }
}
