public import Foundation

/// Caches and incrementally reads local and workflow subagent transcripts.
public actor SupermuxHarnessSubagentTranscriptService: SupermuxHarnessSubagentTranscriptLoading {
    struct ScanInstrumentation: Sendable {
        var didBeginRequest: (@Sendable () async -> Void)?
        var willStartScan: (@Sendable () async -> Void)?
        var willProcessChunk: (@Sendable () -> Void)?
        var didDrainChunk: (@Sendable () -> Void)?

        init(
            didBeginRequest: (@Sendable () async -> Void)? = nil,
            willStartScan: (@Sendable () async -> Void)? = nil,
            willProcessChunk: (@Sendable () -> Void)? = nil,
            didDrainChunk: (@Sendable () -> Void)? = nil
        ) {
            self.didBeginRequest = didBeginRequest
            self.willStartScan = willStartScan
            self.willProcessChunk = willProcessChunk
            self.didDrainChunk = didDrainChunk
        }
    }

    struct CacheSnapshot: Equatable, Sendable {
        let entryCount: Int
        let retainedByteCount: Int
    }

    private struct RevisionChange: Sendable {
        let fromRevision: Int?
        let toRevision: Int
        let change: SupermuxHarnessSubagentTranscriptScanner.Change
    }

    private struct Entry: Sendable {
        var revision: Int
        var state: SupermuxHarnessSubagentTranscriptScanner.State
        var latestChange: RevisionChange
        var completedRequestToken: UInt64
        var lastAccess: UInt64
    }

    private struct Flight: Sendable {
        let token: UInt64
        let coveredRequestToken: UInt64
        let task: Task<SupermuxHarnessSubagentTranscriptScanner.Result, any Error>
        var dirty: Bool
    }

    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let maximumTranscriptBytes: Int
    private let maximumCachedEntries: Int
    private let maximumCachedBytes: Int
    private let scanInstrumentation: ScanInstrumentation?
    private var entries: [SupermuxHarnessSubagentTranscriptAddress: Entry] = [:]
    private var flights: [SupermuxHarnessSubagentTranscriptAddress: Flight] = [:]
    private var leases: [SupermuxHarnessSubagentTranscriptAddress: Int] = [:]
    private var nextRevision = 0
    private var nextFlightToken: UInt64 = 0
    private var nextRequestToken: UInt64 = 0
    private var accessClock: UInt64 = 0

    /// Creates a shared incremental transcript service.
    ///
    /// - Parameters:
    ///   - projectsRootURL: The Claude projects directory, normally `~/.claude/projects`.
    ///   - fileManager: The filesystem implementation to use.
    ///   - maximumTranscriptBytes: The maximum replayable source-record bytes retained per transcript.
    ///   - maximumCachedEntries: The maximum number of transcript cursors retained between requests.
    ///   - maximumCachedBytes: The maximum combined source bytes retained between requests.
    public init(
        projectsRootURL: URL,
        fileManager: FileManager,
        maximumTranscriptBytes: Int = 1 << 20,
        maximumCachedEntries: Int = 64,
        maximumCachedBytes: Int = 32 << 20
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.maximumTranscriptBytes = max(0, maximumTranscriptBytes)
        self.maximumCachedEntries = max(0, maximumCachedEntries)
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.scanInstrumentation = nil
    }

    init(
        projectsRootURL: URL,
        fileManager: FileManager,
        maximumTranscriptBytes: Int = 1 << 20,
        maximumCachedEntries: Int = 64,
        maximumCachedBytes: Int = 32 << 20,
        scanInstrumentation: ScanInstrumentation?
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.maximumTranscriptBytes = max(0, maximumTranscriptBytes)
        self.maximumCachedEntries = max(0, maximumCachedEntries)
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.scanInstrumentation = scanInstrumentation
    }

    /// Loads the current transcript state through the revisioned API.
    ///
    /// Concurrent callers for the same logical address share one scan. A request arriving while
    /// that scan is active marks one coalesced dirty rerun, so no caller can settle on a snapshot
    /// taken before a concurrently requested refresh.
    ///
    /// - Parameters:
    ///   - address: The local-agent or workflow-agent transcript to read.
    ///   - afterRevision: The consumer's last applied revision, or `nil` for a replacement.
    /// - Returns: A replacement, append delta, metadata mutation, or unchanged response.
    /// - Throws: A path-validation or file-reading error.
    public func loadTranscript(
        at address: SupermuxHarnessSubagentTranscriptAddress,
        afterRevision: Int?
    ) async throws -> SupermuxHarnessSubagentTranscriptUpdate {
        if let afterRevision, afterRevision < 0 {
            throw SupermuxHarnessSubagentTranscriptReaderError.invalidRevision
        }
        beginLease(for: address)
        defer { endLease(for: address) }
        await scanInstrumentation?.didBeginRequest?()
        nextRequestToken &+= 1
        let requestToken = nextRequestToken

        try await refresh(address, requestToken: requestToken)
        guard var entry = entries[address] else {
            throw CocoaError(.fileReadUnknown)
        }
        touch(&entry)
        entries[address] = entry
        return update(for: entry, afterRevision: afterRevision)
    }

    func cacheSnapshot() -> CacheSnapshot {
        CacheSnapshot(
            entryCount: entries.count,
            retainedByteCount: retainedCacheByteCount()
        )
    }

    private func refresh(
        _ address: SupermuxHarnessSubagentTranscriptAddress,
        requestToken: UInt64
    ) async throws {
        while true {
            if flights[address] == nil {
                if let completedRequestToken = entries[address]?.completedRequestToken,
                   completedRequestToken >= requestToken {
                    return
                }
                startFlight(for: address)
            } else if let flight = flights[address],
                      requestToken > flight.coveredRequestToken {
                flights[address]?.dirty = true
            }
            guard let flight = flights[address] else { continue }

            let result: SupermuxHarnessSubagentTranscriptScanner.Result
            do {
                result = try await flight.task.value
            } catch {
                if flights[address]?.token == flight.token {
                    flights.removeValue(forKey: address)
                    enforceCacheLimits()
                }
                throw error
            }
            guard let currentFlight = flights[address],
                  currentFlight.token == flight.token else {
                continue
            }

            apply(result, to: address)
            let reruns = currentFlight.dirty || result.requiresRerun
            flights.removeValue(forKey: address)
            if reruns {
                startFlight(for: address)
                continue
            }
            entries[address]?.completedRequestToken = currentFlight.coveredRequestToken
            enforceCacheLimits()
            return
        }
    }

    private func startFlight(
        for address: SupermuxHarnessSubagentTranscriptAddress
    ) {
        nextFlightToken &+= 1
        let token = nextFlightToken
        let baseline = entries[address]?.state
        let scanner = SupermuxHarnessSubagentTranscriptScanner(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager,
            maximumTranscriptBytes: maximumTranscriptBytes,
            instrumentation: scanInstrumentation
        )
        let task = Task.detached(priority: .utility) {
            try await scanner.scan(address: address, baseline: baseline)
        }
        flights[address] = Flight(
            token: token,
            coveredRequestToken: nextRequestToken,
            task: task,
            dirty: false
        )
    }

    private func apply(
        _ result: SupermuxHarnessSubagentTranscriptScanner.Result,
        to address: SupermuxHarnessSubagentTranscriptAddress
    ) {
        if let change = result.change {
            let priorEntry = entries[address]
            nextRevision += 1
            accessClock &+= 1
            entries[address] = Entry(
                revision: nextRevision,
                state: result.state,
                latestChange: RevisionChange(
                    fromRevision: priorEntry?.revision,
                    toRevision: nextRevision,
                    change: change
                ),
                completedRequestToken: priorEntry?.completedRequestToken ?? 0,
                lastAccess: accessClock
            )
            return
        }
        guard var entry = entries[address] else { return }
        entry.state = result.state
        touch(&entry)
        entries[address] = entry
    }

    private func update(
        for entry: Entry,
        afterRevision: Int?
    ) -> SupermuxHarnessSubagentTranscriptUpdate {
        if afterRevision == entry.revision {
            return SupermuxHarnessSubagentTranscriptUpdate(
                revision: entry.revision,
                replace: false,
                droppedEventCount: 0,
                events: [],
                truncated: entry.state.truncated,
                missing: entry.state.missing,
                metadata: .unchanged
            )
        }
        if let afterRevision,
           entry.latestChange.fromRevision == afterRevision,
           entry.latestChange.toRevision == entry.revision {
            let change = entry.latestChange.change
            return SupermuxHarnessSubagentTranscriptUpdate(
                revision: entry.revision,
                replace: change.replace,
                droppedEventCount: change.droppedEventCount,
                events: change.events,
                truncated: entry.state.truncated,
                missing: entry.state.missing,
                metadata: change.metadata
            )
        }
        return SupermuxHarnessSubagentTranscriptUpdate(
            revision: entry.revision,
            replace: true,
            droppedEventCount: 0,
            events: entry.state.events,
            truncated: entry.state.truncated,
            missing: entry.state.missing,
            metadata: entry.state.metadata.map(
                SupermuxHarnessSubagentTranscriptMetadataUpdate.value
            ) ?? .deleted
        )
    }

    private func beginLease(
        for address: SupermuxHarnessSubagentTranscriptAddress
    ) {
        leases[address, default: 0] += 1
    }

    private func endLease(
        for address: SupermuxHarnessSubagentTranscriptAddress
    ) {
        let remaining = (leases[address] ?? 1) - 1
        if remaining > 0 {
            leases[address] = remaining
        } else {
            leases.removeValue(forKey: address)
        }
        enforceCacheLimits()
    }

    private func touch(_ entry: inout Entry) {
        accessClock &+= 1
        entry.lastAccess = accessClock
    }

    private func enforceCacheLimits() {
        while entries.count > maximumCachedEntries
            || retainedCacheByteCount() > maximumCachedBytes {
            let candidate = entries
                .filter { address, _ in
                    leases[address] == nil && flights[address] == nil
                }
                .min { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }
            guard let address = candidate?.key else { return }
            entries.removeValue(forKey: address)
        }
    }

    private func retainedCacheByteCount() -> Int {
        entries.values.reduce(into: 0) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.state.cacheByteCount)
            total = overflow ? Int.max : sum
        }
    }
}
