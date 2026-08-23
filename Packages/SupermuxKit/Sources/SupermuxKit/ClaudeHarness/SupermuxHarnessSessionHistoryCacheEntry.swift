/// Lazily-built parent graph kept separately from listing metadata.
struct SupermuxHarnessSessionHistoryCacheEntry: Sendable {
    let observation: SupermuxHarnessSessionFileObservation
    let committed: SupermuxHarnessSessionHistoryIndex
    let provisional: SupermuxHarnessSessionHistoryIndex?
    let generation: UInt64

    var byteCost: Int {
        128 + committed.byteCost + (provisional?.byteCost ?? 0)
    }
}
