import Foundation

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

/// Current bounded-cache occupancy used by eviction behavior tests.
struct SupermuxHarnessSessionRepositoryCacheMetrics: Equatable, Sendable {
    var metadataEntryCount = 0
    var metadataByteCount = 0
    var historyEntryCount = 0
    var historyByteCount = 0
}

/// Repository tuning kept injectable so package tests can exercise small bounds.
struct SupermuxHarnessSessionRepositoryConfiguration: Equatable, Sendable {
    var metadataMaximumEntries: Int
    var metadataMaximumBytes: Int
    var historyMaximumEntries: Int
    var historyMaximumBytes: Int
    var readChunkBytes: Int
    var continuityValidationBytes: Int

    static let production = Self(
        metadataMaximumEntries: 512,
        metadataMaximumBytes: 16 << 20,
        historyMaximumEntries: 64,
        historyMaximumBytes: 64 << 20,
        readChunkBytes: 1 << 20,
        continuityValidationBytes: 64 << 10
    )
}
