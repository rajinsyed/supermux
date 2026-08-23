/// Prior state and requested index depth for one physical scan.
struct SupermuxHarnessSessionScanPlan: Sendable {
    let previousObservation: SupermuxHarnessSessionFileObservation?
    let previousCursor: SupermuxHarnessSessionScanCursor?
    let previousFingerprint: SupermuxHarnessSessionContinuityFingerprint?
    let includesHistory: Bool
    let forceReset: Bool
    let readChunkBytes: Int
    let continuityValidationBytes: Int
}
