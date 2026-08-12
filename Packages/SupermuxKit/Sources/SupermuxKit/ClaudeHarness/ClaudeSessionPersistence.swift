public import Foundation
public import SupermuxClaudeHarness

/// The state a ``ClaudeSession`` hands to its persistence sink.
///
/// Captured on the session actor at every persistence-critical moment; never
/// contains tokens, environment, PIDs, or unredacted stderr.
public struct ClaudeSessionPersistenceSnapshot: Sendable {
    /// The stable local session identity (``ClaudeSessionConfiguration/id``).
    public let sessionID: UUID
    /// The provider session ID from `system.init` (the `--resume` identity).
    public let providerSessionID: String?
    public let launcher: ClaudeLauncher
    public let workingDirectory: String
    /// Queue entries with delivery states (uncertain entries preserved).
    public let queueEntries: [ClaudeQueuedInput]
    public let lastResult: ClaudeResult?
    /// The redacted stderr tail after an unclean process end, if any.
    public let redactedStderrTail: String?

    public init(
        sessionID: UUID,
        providerSessionID: String?,
        launcher: ClaudeLauncher,
        workingDirectory: String,
        queueEntries: [ClaudeQueuedInput],
        lastResult: ClaudeResult?,
        redactedStderrTail: String?
    ) {
        self.sessionID = sessionID
        self.providerSessionID = providerSessionID
        self.launcher = launcher
        self.workingDirectory = workingDirectory
        self.queueEntries = queueEntries
        self.lastResult = lastResult
        self.redactedStderrTail = redactedStderrTail
    }
}

/// Persists session snapshots so a crash cannot lose the provider session ID
/// or queued/dispatching/uncertain delivery states.
///
/// The session awaits `persist` before writing a dispatched prompt to stdin
/// (the "persist dispatching before writing" invariant), so implementations
/// must be safe to call from the session actor.
public protocol ClaudeSessionPersisting: Sendable {
    func persist(_ snapshot: ClaudeSessionPersistenceSnapshot) async
}

/// Bridges ``ClaudeSessionPersisting`` onto ``SupermuxHarnessSessionStore``,
/// merging each snapshot into the record for one stable surface ID.
public struct SupermuxHarnessSessionPersistence: ClaudeSessionPersisting {
    private let store: SupermuxHarnessSessionStore
    private let stableSurfaceID: UUID

    public init(store: SupermuxHarnessSessionStore, stableSurfaceID: UUID) {
        self.store = store
        self.stableSurfaceID = stableSurfaceID
    }

    public func persist(_ snapshot: ClaudeSessionPersistenceSnapshot) async {
        // One atomic read-modify-write on the store actor. A separate
        // load + save pair here raced concurrent writers (the view model's
        // persistRecord, the mobile host's record edits): both could load
        // the same stale record and the loser's save would erase the
        // winner's fields — including the just-learned Claude session ID,
        // which is the `--resume` identity (lost-update race).
        let stableSurfaceID = self.stableSurfaceID
        try? await store.update(
            stableSurfaceID: stableSurfaceID,
            default: {
                SupermuxHarnessSessionRecord(
                    stableSurfaceID: stableSurfaceID,
                    launcher: snapshot.launcher,
                    workingDirectory: snapshot.workingDirectory
                )
            }
        ) { record in
            record.claudeSessionID = snapshot.providerSessionID ?? record.claudeSessionID
            record.launcher = snapshot.launcher
            record.workingDirectory = snapshot.workingDirectory
            record.queueEntries = snapshot.queueEntries
            record.lastActiveAt = Date()
            if let result = snapshot.lastResult {
                record.lastTotalCostUSD = result.totalCostUSD ?? record.lastTotalCostUSD
                record.lastInputTokens = result.usage?.inputTokens ?? record.lastInputTokens
                record.lastOutputTokens = result.usage?.outputTokens ?? record.lastOutputTokens
            }
            if let tail = snapshot.redactedStderrTail {
                record.redactedDiagnostic = tail
            }
        }
    }
}
