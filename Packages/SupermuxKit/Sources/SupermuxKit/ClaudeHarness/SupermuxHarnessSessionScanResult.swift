/// Stable result of one bounded physical scan.
struct SupermuxHarnessSessionScanResult: Sendable {
    let before: SupermuxHarnessSessionFileObservation
    let after: SupermuxHarnessSessionFileObservation
    let pathAfter: SupermuxHarnessSessionFileObservation
    let metadataDelta: SupermuxHarnessSessionMetadataIndex
    let historyDelta: SupermuxHarnessSessionHistoryIndex?
    let provisionalRecord: SupermuxHarnessSessionIndexedRecord?
    let cursor: SupermuxHarnessSessionScanCursor
    let fingerprint: SupermuxHarnessSessionContinuityFingerprint
    let didReset: Bool
    let readOffset: UInt64
    let bytesRead: UInt64
    let parsedRecordCount: Int
    let maximumReadChunkBytes: Int

    var isStable: Bool { before == after && after == pathAfter }
}
