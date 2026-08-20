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
