public import Foundation

/// App-scoped access to persisted Claude main-session JSONL files.
///
/// Construct one actor at the application composition root and inject it into
/// every harness controller. Metadata and history indexes remain bounded and
/// are shared across every injected reader.
///
/// ```swift
/// let repository = SupermuxHarnessSessionRepository(
///     projectsRootURL: projectsURL,
///     fileManager: .default
/// )
/// let sessions = try await repository.listSessions(for: workingDirectoryURL, limit: 20)
/// ```
public actor SupermuxHarnessSessionRepository: SupermuxHarnessSessionReading {
    private struct CandidateFile {
        let fileURL: URL
        let sessionID: String
        let updatedAt: Date
        let encounterOrder: Int
    }

    private struct IndexedState: Sendable {
        let metadata: SupermuxHarnessSessionMetadataCacheEntry
        let history: SupermuxHarnessSessionHistoryCacheEntry?
    }

    private struct ScanFlight {
        let id: UInt64
        let task: Task<IndexedState, any Error>
        var requestedObservation: SupermuxHarnessSessionFileObservation
        var needsHistory: Bool
        var isDirty: Bool
    }

    private let fileManager: FileManager
    private let configuration: SupermuxHarnessSessionRepositoryConfiguration
    private let scanObserver: (@Sendable (URL) async -> Void)?
    private let collectsMetrics: Bool
    private let pathPolicy: SupermuxHarnessSessionPathPolicy
    private let scanner = SupermuxHarnessSessionFileScanner()
    private var metadataCache: SupermuxHarnessLRUCache<
        String,
        SupermuxHarnessSessionMetadataCacheEntry
    >
    private var historyCache: SupermuxHarnessLRUCache<
        String,
        SupermuxHarnessSessionHistoryCacheEntry
    >
    private var flightsByPath: [String: ScanFlight] = [:]
    private var metricsByPath: [String: SupermuxHarnessSessionRepositoryMetrics] = [:]
    private var nextFlightID: UInt64 = 0
    private var nextGeneration: UInt64 = 0

    /// Creates an app-scoped persisted-session repository.
    ///
    /// - Parameters:
    ///   - projectsRootURL: The Claude projects directory, normally `~/.claude/projects`.
    ///   - fileManager: The filesystem implementation used for discovery and safety checks.
    public init(projectsRootURL: URL, fileManager: FileManager) {
        let configuration = SupermuxHarnessSessionRepositoryConfiguration.production
        self.fileManager = fileManager
        self.configuration = configuration
        scanObserver = nil
        collectsMetrics = false
        pathPolicy = SupermuxHarnessSessionPathPolicy(
            projectsRootURL: projectsRootURL
        )
        metadataCache = SupermuxHarnessLRUCache(
            maximumEntries: configuration.metadataMaximumEntries,
            maximumBytes: configuration.metadataMaximumBytes
        )
        historyCache = SupermuxHarnessLRUCache(
            maximumEntries: configuration.historyMaximumEntries,
            maximumBytes: configuration.historyMaximumBytes
        )
    }

    /// Creates an instrumented repository with injectable cache and read bounds.
    init(
        projectsRootURL: URL,
        fileManager: FileManager,
        configuration: SupermuxHarnessSessionRepositoryConfiguration,
        scanObserver: (@Sendable (URL) async -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.configuration = configuration
        self.scanObserver = scanObserver
        collectsMetrics = true
        pathPolicy = SupermuxHarnessSessionPathPolicy(
            projectsRootURL: projectsRootURL
        )
        metadataCache = SupermuxHarnessLRUCache(
            maximumEntries: configuration.metadataMaximumEntries,
            maximumBytes: configuration.metadataMaximumBytes
        )
        historyCache = SupermuxHarnessLRUCache(
            maximumEntries: configuration.historyMaximumEntries,
            maximumBytes: configuration.historyMaximumBytes
        )
    }

    /// Lists persisted sessions for one working directory, newest first.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - limit: Optional maximum result count. Values at or below zero return an empty list.
    /// - Returns: Deduplicated session metadata sorted by modification date.
    /// - Throws: A filesystem or file-reading error for a discovered session file.
    public func listSessions(
        for workingDirectoryURL: URL,
        limit: Int? = nil
    ) async throws -> [SupermuxHarnessDiscoveredSession] {
        if let limit, limit <= 0 { return [] }
        let expectedPaths = SupermuxHarnessSessionPathPolicy.canonicalPaths(
            for: workingDirectoryURL
        )
        let candidates = try candidateSessionFiles(for: workingDirectoryURL)
        var sessionsByID: [String: SupermuxHarnessDiscoveredSession] = [:]
        for candidate in candidates {
            if let limit,
               sessionsByID.count >= limit,
               let cutoffDate = sessionsByID.values.map(\.updatedAt).min(),
               candidate.updatedAt < cutoffDate {
                break
            }
            if let existing = sessionsByID[candidate.sessionID],
               existing.updatedAt >= candidate.updatedAt {
                continue
            }
            let state = try await ensureIndexed(
                candidate.fileURL,
                includesHistory: false
            )
            let metadata = state.metadata.effectiveIndex
            guard belongsToWorkingDirectory(metadata, expectedPaths: expectedPaths) else {
                continue
            }
            sessionsByID[candidate.sessionID] = SupermuxHarnessDiscoveredSession(
                sessionID: candidate.sessionID,
                title: metadata.title ?? candidate.sessionID,
                firstPrompt: metadata.firstPrompt,
                updatedAt: candidate.updatedAt,
                gitBranch: metadata.gitBranch,
                messageCount: metadata.messageCount
            )
        }
        let sorted = sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.sessionID < $1.sessionID
        }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// Loads one session by walking its persisted UUID parent chain.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    ///   - recordLimit: Optional maximum number of newest visible records to return.
    /// - Returns: Root-to-leaf protocol-shaped events and a truncation flag.
    /// - Throws: ``SupermuxHarnessSessionDiscoveryError`` or a file-reading error.
    public func loadHistory(
        for workingDirectoryURL: URL,
        sessionID: String,
        recordLimit: Int? = nil
    ) async throws -> SupermuxHarnessHistoryPage {
        guard pathPolicy.isValidSessionID(sessionID) else {
            throw SupermuxHarnessSessionDiscoveryError.invalidSessionID
        }
        let expectedPaths = SupermuxHarnessSessionPathPolicy.canonicalPaths(
            for: workingDirectoryURL
        )
        for candidateDirectory in pathPolicy.projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = pathPolicy.safeProjectDirectory(candidateDirectory) else {
                continue
            }
            let fileURL = directory.appendingPathComponent(sessionID)
                .appendingPathExtension("jsonl")
            guard pathPolicy.safeSessionFile(fileURL, in: directory) else { continue }
            while true {
                let state = try await ensureIndexed(fileURL, includesHistory: true)
                let metadata = state.metadata
                guard belongsToWorkingDirectory(
                    metadata.effectiveIndex,
                    expectedPaths: expectedPaths
                ) else {
                    break
                }
                let path = canonicalPath(for: fileURL)
                guard let history = state.history,
                      history.observation == metadata.observation,
                      history.generation == metadata.generation else {
                    continue
                }
                let selection = Self.selectedHistory(
                    from: history,
                    recordLimit: recordLimit
                )
                let selectedRead = try await scanner.readSelectedRecords(
                    fileURL,
                    expected: metadata.observation,
                    selections: selection.ranges,
                    fallbackSessionID: sessionID,
                    chunkSize: configuration.readChunkBytes
                )
                recordSelectedRead(selectedRead, path: path)
                guard selectedRead.before == metadata.observation,
                      selectedRead.isStable else {
                    invalidate(path: path)
                    continue
                }
                return SupermuxHarnessHistoryPage(
                    events: selectedRead.events,
                    truncated: selection.truncated
                )
            }
        }
        throw SupermuxHarnessSessionDiscoveryError.sessionNotFound(sessionID)
    }

    /// Returns the current display title for one persisted session.
    ///
    /// - Parameters:
    ///   - workingDirectoryURL: The working directory whose Claude project aliases are probed.
    ///   - sessionID: The persisted session filename without `.jsonl`.
    /// - Returns: The resolved title, or `nil` when unavailable or untitled.
    public func sessionTitle(
        for workingDirectoryURL: URL,
        sessionID: String
    ) async -> String? {
        guard pathPolicy.isValidSessionID(sessionID) else { return nil }
        for candidateDirectory in pathPolicy.projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = pathPolicy.safeProjectDirectory(candidateDirectory) else {
                continue
            }
            let fileURL = directory.appendingPathComponent(sessionID)
                .appendingPathExtension("jsonl")
            guard pathPolicy.safeSessionFile(fileURL, in: directory) else { continue }
            return try? await ensureIndexed(fileURL, includesHistory: false)
                .metadata.effectiveIndex.title
        }
        return nil
    }

    func debugMetrics(for fileURL: URL) -> SupermuxHarnessSessionRepositoryMetrics {
        metricsByPath[canonicalPath(for: fileURL)] ?? SupermuxHarnessSessionRepositoryMetrics()
    }

    func debugCacheMetrics() -> SupermuxHarnessSessionRepositoryCacheMetrics {
        SupermuxHarnessSessionRepositoryCacheMetrics(
            metadataEntryCount: metadataCache.count,
            metadataByteCount: metadataCache.byteCount,
            historyEntryCount: historyCache.count,
            historyByteCount: historyCache.byteCount
        )
    }

    private func candidateSessionFiles(
        for workingDirectoryURL: URL
    ) throws -> [CandidateFile] {
        var candidates: [CandidateFile] = []
        var encounterOrder = 0
        for candidateDirectory in pathPolicy.projectDirectoryURLs(for: workingDirectoryURL) {
            guard let directory = pathPolicy.safeProjectDirectory(candidateDirectory) else {
                continue
            }
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
            for fileURL in files where fileURL.pathExtension.lowercased() == "jsonl" {
                defer { encounterOrder += 1 }
                let sessionID = fileURL.deletingPathExtension().lastPathComponent
                guard pathPolicy.isValidSessionID(sessionID),
                      pathPolicy.safeSessionFile(fileURL, in: directory) else {
                    continue
                }
                let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                candidates.append(CandidateFile(
                    fileURL: fileURL,
                    sessionID: sessionID,
                    updatedAt: values.contentModificationDate ?? .distantPast,
                    encounterOrder: encounterOrder
                ))
            }
        }
        return candidates.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.encounterOrder < $1.encounterOrder
        }
    }

    private func ensureIndexed(
        _ fileURL: URL,
        includesHistory: Bool
    ) async throws -> IndexedState {
        let path = canonicalPath(for: fileURL)
        while true {
            let observation = try await scanner.observe(fileURL)
            if let metadata = metadataCache.value(forKey: path),
               metadata.observation == observation {
                if !includesHistory {
                    return IndexedState(metadata: metadata, history: nil)
                }
                if let history = historyCache.value(forKey: path),
                   history.observation == observation,
                   history.generation == metadata.generation {
                    return IndexedState(metadata: metadata, history: history)
                }
            }

            let task: Task<IndexedState, any Error>
            if var flight = flightsByPath[path] {
                recordCoalescedRequest(path: path)
                if flight.requestedObservation != observation, !flight.isDirty {
                    flight.isDirty = true
                    recordDirtyRerunRequest(path: path)
                }
                flight.requestedObservation = observation
                flight.needsHistory = flight.needsHistory || includesHistory
                task = flight.task
                flightsByPath[path] = flight
            } else {
                nextFlightID &+= 1
                let flightID = nextFlightID
                task = Task {
                    try await self.runScanFlight(
                        fileURL,
                        path: path,
                        flightID: flightID
                    )
                }
                flightsByPath[path] = ScanFlight(
                    id: flightID,
                    task: task,
                    requestedObservation: observation,
                    needsHistory: includesHistory,
                    isDirty: false
                )
            }
            let state = try await task.value
            let latestObservation = try await scanner.observe(fileURL)
            if latestObservation == state.metadata.observation,
               (!includesHistory || state.history != nil) {
                return state
            }
        }
    }

    private func runScanFlight(
        _ fileURL: URL,
        path: String,
        flightID: UInt64
    ) async throws -> IndexedState {
        defer {
            if flightsByPath[path]?.id == flightID {
                flightsByPath.removeValue(forKey: path)
            }
        }
        var forceReset = false
        var latestState: IndexedState?
        while let flight = flightsByPath[path], flight.id == flightID {
            let cachedMetadata = metadataCache.value(forKey: path)
            let cachedHistory = historyCache.value(forKey: path)
            let previousMetadata = forceReset
                ? nil
                : (cachedMetadata ?? latestState?.metadata)
            let previousHistory = forceReset
                ? nil
                : (cachedHistory ?? latestState?.history)
            let canIncrementHistory = previousMetadata != nil &&
                previousHistory?.observation == previousMetadata?.observation &&
                previousHistory?.generation == previousMetadata?.generation
            let includesHistory = flight.needsHistory || canIncrementHistory
            let mustBuildHistoryFromStart = includesHistory && !canIncrementHistory
            let planForcesReset = forceReset || mustBuildHistoryFromStart
            let plan = SupermuxHarnessSessionScanPlan(
                previousObservation: planForcesReset ? nil : previousMetadata?.observation,
                previousCursor: planForcesReset ? nil : previousMetadata?.cursor,
                previousFingerprint: planForcesReset ? nil : previousMetadata?.fingerprint,
                includesHistory: includesHistory,
                forceReset: planForcesReset,
                readChunkBytes: configuration.readChunkBytes,
                continuityValidationBytes: configuration.continuityValidationBytes
            )
            let result = try await scanner.scan(
                fileURL,
                plan: plan,
                observer: scanObserver
            )
            recordScan(result, path: path)
            if !result.isStable {
                if var currentFlight = flightsByPath[path],
                   currentFlight.id == flightID {
                    currentFlight.isDirty = false
                    currentFlight.requestedObservation = result.pathAfter
                    flightsByPath[path] = currentFlight
                }
                forceReset = true
                latestState = nil
                continue
            }
            latestState = commit(
                result,
                path: path,
                previousMetadata: previousMetadata,
                previousHistory: previousHistory
            )
            forceReset = false

            guard var currentFlight = flightsByPath[path],
                  currentFlight.id == flightID,
                  let latestState else {
                throw CocoaError(.fileReadUnknown)
            }
            let needsDirtyRerun = currentFlight.isDirty &&
                currentFlight.requestedObservation != result.after
            currentFlight.requestedObservation = result.after
            currentFlight.isDirty = false
            flightsByPath[path] = currentFlight
            if needsDirtyRerun { continue }
            if currentFlight.needsHistory, latestState.history == nil {
                continue
            }
            return latestState
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func commit(
        _ result: SupermuxHarnessSessionScanResult,
        path: String,
        previousMetadata: SupermuxHarnessSessionMetadataCacheEntry?,
        previousHistory: SupermuxHarnessSessionHistoryCacheEntry?
    ) -> IndexedState {
        var committedMetadata = SupermuxHarnessSessionMetadataIndex()
        if !result.didReset,
           previousMetadata?.observation.identity == result.before.identity,
           let previousMetadata {
            committedMetadata = previousMetadata.committed
        }
        committedMetadata.merge(result.metadataDelta)
        nextGeneration &+= 1
        let generation = nextGeneration
        let metadata = SupermuxHarnessSessionMetadataCacheEntry(
            observation: result.after,
            cursor: result.cursor,
            fingerprint: result.fingerprint,
            committed: committedMetadata,
            provisional: result.provisionalRecord?.metadata,
            generation: generation
        )
        let evictedMetadataPaths = metadataCache.setValue(
            metadata,
            forKey: path,
            byteCost: metadata.byteCost
        )
        for evictedPath in evictedMetadataPaths {
            historyCache.removeValue(forKey: evictedPath)
        }

        var history: SupermuxHarnessSessionHistoryCacheEntry?
        if var historyDelta = result.historyDelta {
            if !result.didReset,
               previousHistory?.observation.identity == result.before.identity,
               previousHistory?.generation == previousMetadata?.generation,
               let previousHistory {
                var merged = previousHistory.committed
                merged.merge(historyDelta)
                historyDelta = merged
            }
            var provisionalHistory: SupermuxHarnessSessionHistoryIndex?
            if let provisionalRecord = result.provisionalRecord {
                var index = SupermuxHarnessSessionHistoryIndex()
                index.apply(provisionalRecord)
                provisionalHistory = index
            }
            history = SupermuxHarnessSessionHistoryCacheEntry(
                observation: result.after,
                committed: historyDelta,
                provisional: provisionalHistory,
                generation: generation
            )
        }

        if !evictedMetadataPaths.contains(path), let history {
            _ = historyCache.setValue(history, forKey: path, byteCost: history.byteCost)
        } else {
            historyCache.removeValue(forKey: path)
        }
        return IndexedState(metadata: metadata, history: history)
    }

    private func invalidate(path: String) {
        metadataCache.removeValue(forKey: path)
        historyCache.removeValue(forKey: path)
    }

    private func belongsToWorkingDirectory(
        _ metadata: SupermuxHarnessSessionMetadataIndex,
        expectedPaths: Set<String>
    ) -> Bool {
        !metadata.foundRecordedDirectory ||
            !metadata.recordedCanonicalPaths.isDisjoint(with: expectedPaths)
    }

    private func canonicalPath(for fileURL: URL) -> String {
        SupermuxHarnessSessionPathPolicy.canonicalFileURL(fileURL).path
    }

    private func recordScan(
        _ result: SupermuxHarnessSessionScanResult,
        path: String
    ) {
        guard collectsMetrics else { return }
        var metrics = metricsByPath[path] ?? SupermuxHarnessSessionRepositoryMetrics()
        metrics.scanCount += 1
        metrics.indexBytesRead += result.bytesRead
        metrics.indexedRecordCount += result.parsedRecordCount
        metrics.readOffsets.append(result.readOffset)
        metrics.maximumReadChunkBytes = max(
            metrics.maximumReadChunkBytes,
            result.maximumReadChunkBytes
        )
        metricsByPath[path] = metrics
    }

    private func recordSelectedRead(
        _ read: SupermuxHarnessSessionSelectedRead,
        path: String
    ) {
        guard collectsMetrics else { return }
        var metrics = metricsByPath[path] ?? SupermuxHarnessSessionRepositoryMetrics()
        metrics.selectedRecordReadCount += read.recordCount
        metrics.selectedRecordBytesRead += read.bytesRead
        metrics.maximumReadChunkBytes = max(
            metrics.maximumReadChunkBytes,
            read.maximumReadChunkBytes
        )
        metricsByPath[path] = metrics
    }

    private func recordCoalescedRequest(path: String) {
        guard collectsMetrics else { return }
        var metrics = metricsByPath[path] ?? SupermuxHarnessSessionRepositoryMetrics()
        metrics.coalescedRequestCount += 1
        metricsByPath[path] = metrics
    }

    private func recordDirtyRerunRequest(path: String) {
        guard collectsMetrics else { return }
        var metrics = metricsByPath[path] ?? SupermuxHarnessSessionRepositoryMetrics()
        metrics.dirtyRerunRequestCount += 1
        metricsByPath[path] = metrics
    }

    private static func selectedHistory(
        from entry: SupermuxHarnessSessionHistoryCacheEntry,
        recordLimit: Int?
    ) -> (ranges: [SupermuxHarnessSessionRecordSelection], truncated: Bool) {
        var index = entry.committed
        if let provisional = entry.provisional {
            index.merge(provisional)
        }
        let preferredLeaves = [index.lastPromptLeaf, index.summaryLeaf]
            .compactMap { $0 }
            .filter {
                !isAncestor($0, ofDescendant: index.lastMainUUID, in: index.linksByUUID)
            } + [index.lastMainUUID].compactMap { $0 }
        var chainUUIDs: [String] = []
        var cursor = preferredLeaves.first { index.linksByUUID[$0] != nil }
        var visited: Set<String> = []
        while let uuid = cursor,
              visited.insert(uuid).inserted,
              let link = index.linksByUUID[uuid] {
            if link.isVisible { chainUUIDs.append(uuid) }
            cursor = link.parentUUID
        }
        chainUUIDs.reverse()

        let truncated: Bool
        if let recordLimit {
            let boundedLimit = max(0, recordLimit)
            truncated = chainUUIDs.count > boundedLimit
            if truncated {
                chainUUIDs = Array(chainUUIDs.suffix(boundedLimit))
            }
        } else {
            truncated = false
        }
        return (
            chainUUIDs.compactMap { uuid in
                index.eventRangesByUUID[uuid].map {
                    SupermuxHarnessSessionRecordSelection(range: $0)
                }
            },
            truncated
        )
    }

    private static func isAncestor(
        _ leaf: String,
        ofDescendant descendant: String?,
        in linksByUUID: [String: SupermuxHarnessSessionRecordLink]
    ) -> Bool {
        guard let descendant, descendant != leaf else { return false }
        var cursor = linksByUUID[descendant]?.parentUUID
        var visited: Set<String> = [descendant]
        while let uuid = cursor, visited.insert(uuid).inserted {
            if uuid == leaf { return true }
            cursor = linksByUUID[uuid]?.parentUUID
        }
        return false
    }
}
