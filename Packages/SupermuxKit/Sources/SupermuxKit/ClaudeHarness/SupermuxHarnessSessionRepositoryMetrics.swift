/// Runtime I/O counters used by repository behavior tests.
struct SupermuxHarnessSessionRepositoryMetrics: Equatable, Sendable {
    var scanCount = 0
    var indexBytesRead: UInt64 = 0
    var indexedRecordCount = 0
    var selectedRecordReadCount = 0
    var selectedRecordBytesRead: UInt64 = 0
    var coalescedRequestCount = 0
    var dirtyRerunRequestCount = 0
    var readOffsets: [UInt64] = []
    var maximumReadChunkBytes = 0
}
