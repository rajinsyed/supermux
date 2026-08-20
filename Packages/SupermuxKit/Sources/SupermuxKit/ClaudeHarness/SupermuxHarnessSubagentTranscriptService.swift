public import Foundation

/// Caches and incrementally reads local and workflow subagent transcripts.
public actor SupermuxHarnessSubagentTranscriptService: SupermuxHarnessSubagentTranscriptLoading {
    struct ScanInstrumentation: Sendable {
        var willStartScan: (@Sendable () async -> Void)?
        var willProcessChunk: (@Sendable () -> Void)?
        var didDrainChunk: (@Sendable () -> Void)?

        init(
            willStartScan: (@Sendable () async -> Void)? = nil,
            willProcessChunk: (@Sendable () -> Void)? = nil,
            didDrainChunk: (@Sendable () -> Void)? = nil
        ) {
            self.willStartScan = willStartScan
            self.willProcessChunk = willProcessChunk
            self.didDrainChunk = didDrainChunk
        }
    }

    struct CacheSnapshot: Equatable, Sendable {
        let entryCount: Int
        let retainedByteCount: Int
    }

    private struct Entry {
        var revision: Int
        var page: SupermuxHarnessSubagentTranscriptPage
    }

    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let maximumTranscriptBytes: Int
    private let maximumCachedEntries: Int
    private let maximumCachedBytes: Int
    private let scanInstrumentation: ScanInstrumentation?
    private var entries: [SupermuxHarnessSubagentTranscriptAddress: Entry] = [:]

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
    /// This initial implementation deliberately delegates to the established bounded reader so
    /// callers can be constructor-injected before the incremental cursor replaces the full scan.
    ///
    /// - Parameters:
    ///   - address: The local-agent or workflow-agent transcript to read.
    ///   - afterRevision: The consumer's last applied revision, or `nil` for a replacement.
    /// - Returns: A full replacement or an unchanged response.
    /// - Throws: A path-validation or file-reading error.
    public func loadTranscript(
        at address: SupermuxHarnessSubagentTranscriptAddress,
        afterRevision: Int?
    ) async throws -> SupermuxHarnessSubagentTranscriptUpdate {
        if let afterRevision, afterRevision < 0 {
            throw SupermuxHarnessSubagentTranscriptReaderError.invalidRevision
        }
        await scanInstrumentation?.willStartScan?()
        let address = address.canonicalized
        let reader = SupermuxHarnessSubagentTranscriptReader(
            projectsRootURL: projectsRootURL,
            fileManager: fileManager,
            maximumTranscriptBytes: maximumTranscriptBytes
        )
        let page: SupermuxHarnessSubagentTranscriptPage
        switch address {
        case .localAgent(let workingDirectoryURL, let sessionID, let taskID):
            page = try reader.loadLocalAgentTranscript(
                for: workingDirectoryURL,
                sessionID: sessionID,
                taskID: taskID
            )
        case .workflowAgent(
            let workingDirectoryURL,
            let sessionID,
            let workflowRunID,
            let agentID
        ):
            page = try reader.loadWorkflowAgentTranscript(
                for: workingDirectoryURL,
                sessionID: sessionID,
                workflowRunID: workflowRunID,
                agentID: agentID
            )
        }

        if let entry = entries[address], entry.page == page {
            return SupermuxHarnessSubagentTranscriptUpdate(
                revision: entry.revision,
                replace: false,
                droppedEventCount: 0,
                events: [],
                truncated: page.truncated,
                missing: page.missing,
                metadata: .unchanged
            )
        }

        let revision = (entries[address]?.revision ?? 0) + 1
        entries[address] = Entry(revision: revision, page: page)
        return SupermuxHarnessSubagentTranscriptUpdate(
            revision: revision,
            replace: true,
            droppedEventCount: 0,
            events: page.events,
            truncated: page.truncated,
            missing: page.missing,
            metadata: page.metadata.map(
                SupermuxHarnessSubagentTranscriptMetadataUpdate.value
            ) ?? .deleted
        )
    }

    func cacheSnapshot() -> CacheSnapshot {
        _ = maximumCachedEntries
        _ = maximumCachedBytes
        return CacheSnapshot(entryCount: entries.count, retainedByteCount: 0)
    }
}
