/// Cached metadata plus the shared incremental file cursor.
struct SupermuxHarnessSessionMetadataCacheEntry: Sendable {
    let observation: SupermuxHarnessSessionFileObservation
    let cursor: SupermuxHarnessSessionScanCursor
    let fingerprint: SupermuxHarnessSessionContinuityFingerprint
    let committed: SupermuxHarnessSessionMetadataIndex
    let provisional: SupermuxHarnessSessionMetadataIndex?
    let generation: UInt64

    var effectiveIndex: SupermuxHarnessSessionMetadataIndex {
        var result = committed
        if let provisional {
            result.merge(provisional)
        }
        return result
    }

    var byteCost: Int {
        192 + cursor.provisionalTail.count + fingerprint.byteCost +
            committed.byteCost + (provisional?.byteCost ?? 0)
    }
}
