/// A bounded diagnostic emitted when process output cannot be represented as a protocol line.
public struct SupermuxHarnessOutputDiagnostic: Equatable, Sendable {
    /// The process stream whose physical line overflowed.
    public let stream: Stream
    /// The number of bytes discarded from that physical line, saturated at `Int.max`.
    public let discardedByteCount: Int

    /// Creates an output-overflow diagnostic.
    ///
    /// - Parameters:
    ///   - stream: The process stream whose physical line overflowed.
    ///   - discardedByteCount: The number of bytes discarded before recovery.
    public init(stream: Stream, discardedByteCount: Int) {
        self.stream = stream
        self.discardedByteCount = discardedByteCount
    }

    /// A process output stream.
    public enum Stream: String, Equatable, Sendable {
        /// Claude's newline-delimited JSON protocol stream.
        case stdout
        /// Human-readable process diagnostics.
        case stderr
    }
}
