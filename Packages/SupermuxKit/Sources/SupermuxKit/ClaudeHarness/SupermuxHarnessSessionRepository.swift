public import Foundation

/// App-scoped access to persisted Claude main-session JSONL files.
///
/// Construct one actor at the application composition root and inject it into
/// every harness controller. This initial facade preserves the existing
/// discovery behavior while giving the app and tests one constructor-injected
/// repository seam.
///
/// ```swift
/// let repository = SupermuxHarnessSessionRepository(
///     projectsRootURL: projectsURL,
///     fileManager: .default
/// )
/// let sessions = try await repository.listSessions(for: workingDirectoryURL, limit: 20)
/// ```
public actor SupermuxHarnessSessionRepository: SupermuxHarnessSessionReading {
    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let configuration: SupermuxHarnessSessionRepositoryConfiguration
    private let scanObserver: (@Sendable (URL) async -> Void)?
    private let collectsMetrics: Bool
    private var metricsByPath: [String: SupermuxHarnessSessionRepositoryMetrics] = [:]

    /// Creates an app-scoped persisted-session repository.
    ///
    /// - Parameters:
    ///   - projectsRootURL: The Claude projects directory, normally `~/.claude/projects`.
    ///   - fileManager: The filesystem implementation used for discovery and safety checks.
    public init(projectsRootURL: URL, fileManager: FileManager) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
        configuration = .production
        scanObserver = nil
        collectsMetrics = false
    }

    /// Creates an instrumented repository with injectable cache and read bounds.
    init(
        projectsRootURL: URL,
        fileManager: FileManager,
        configuration: SupermuxHarnessSessionRepositoryConfiguration,
        scanObserver: (@Sendable (URL) async -> Void)? = nil
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.configuration = configuration
        self.scanObserver = scanObserver
        collectsMetrics = true
    }

    public func listSessions(
        for workingDirectoryURL: URL,
        limit: Int? = nil
    ) async throws -> [SupermuxHarnessDiscoveredSession] {
        if let limit, limit <= 0 { return [] }
        let discovery = makeDiscovery()
        if collectsMetrics {
            for fileURL in try candidateSessionFiles(
                discovery: discovery,
                workingDirectoryURL: workingDirectoryURL
            ) {
                await recordLegacyScan(fileURL)
            }
        }
        return try discovery.listSessions(for: workingDirectoryURL, limit: limit)
    }

    public func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int? = nil
    ) async throws -> SupermuxHarnessHistoryPage {
        let discovery = makeDiscovery()
        if collectsMetrics,
           let fileURL = discovery.sessionFileURL(
               for: workingDirectoryURL,
               sessionID: sessionID
           ) {
            await recordLegacyScan(fileURL)
            await recordLegacyScan(fileURL)
        }
        return try discovery.loadHistory(
            for: workingDirectoryURL,
            sessionID: sessionID,
            recordLimit: recordLimit
        )
    }

    public func sessionTitle(
        for workingDirectoryURL: URL,
        sessionID: String
    ) async -> String? {
        let discovery = makeDiscovery()
        if collectsMetrics {
            guard let fileURL = discovery.sessionFileURL(
                for: workingDirectoryURL,
                sessionID: sessionID
            ) else {
                return nil
            }
            await recordLegacyScan(fileURL)
        }
        return discovery.sessionTitle(
            for: workingDirectoryURL,
            sessionID: sessionID
        )
    }

    func debugMetrics(for fileURL: URL) -> SupermuxHarnessSessionRepositoryMetrics {
        metricsByPath[canonicalPath(for: fileURL)] ?? SupermuxHarnessSessionRepositoryMetrics()
    }

    func debugCacheMetrics() -> SupermuxHarnessSessionRepositoryCacheMetrics {
        SupermuxHarnessSessionRepositoryCacheMetrics()
    }

    private func makeDiscovery() -> SupermuxHarnessSessionDiscovery {
        SupermuxHarnessSessionDiscovery(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager
        )
    }

    private func candidateSessionFiles(
        discovery: SupermuxHarnessSessionDiscovery,
        workingDirectoryURL: URL
    ) throws -> [URL] {
        var files: [URL] = []
        for directory in discovery.projectDirectoryURLs(for: workingDirectoryURL) {
            guard let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
            values.isDirectory == true,
            values.isSymbolicLink != true else {
                continue
            }
            files.append(contentsOf: try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "jsonl" })
        }
        return files
    }

    private func recordLegacyScan(_ fileURL: URL) async {
        if let scanObserver {
            await scanObserver(fileURL)
        }
        let path = canonicalPath(for: fileURL)
        let byteCount = max(
            0,
            (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        var metrics = metricsByPath[path] ?? SupermuxHarnessSessionRepositoryMetrics()
        metrics.scanCount += 1
        metrics.indexBytesRead += UInt64(byteCount)
        metrics.readOffsets.append(0)
        metrics.maximumReadChunkBytes = max(
            metrics.maximumReadChunkBytes,
            min(byteCount, max(1, configuration.readChunkBytes))
        )
        metricsByPath[path] = metrics
    }

    private func canonicalPath(for fileURL: URL) -> String {
        fileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
