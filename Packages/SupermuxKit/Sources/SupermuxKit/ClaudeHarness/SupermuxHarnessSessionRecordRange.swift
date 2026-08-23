/// Byte range for one JSONL record, excluding its trailing newline.
struct SupermuxHarnessSessionRecordRange: Equatable, Hashable, Sendable {
    let lowerBound: UInt64
    let upperBound: UInt64

    var count: UInt64 { upperBound - lowerBound }
}
