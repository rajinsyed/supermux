import Foundation

/// Incremental line cursor retained with metadata.
struct SupermuxHarnessSessionScanCursor: Sendable {
    let committedOffset: UInt64
    let provisionalTail: Data
    let isSkippingOverlongTail: Bool
}
