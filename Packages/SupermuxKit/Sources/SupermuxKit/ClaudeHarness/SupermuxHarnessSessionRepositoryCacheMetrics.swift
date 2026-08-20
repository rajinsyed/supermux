/// Current bounded-cache occupancy used by eviction behavior tests.
struct SupermuxHarnessSessionRepositoryCacheMetrics: Equatable, Sendable {
    var metadataEntryCount = 0
    var metadataByteCount = 0
    var historyEntryCount = 0
    var historyByteCount = 0
}
