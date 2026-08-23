/// A bounded diagnostic emitted when process output cannot be represented completely.
public struct SupermuxHarnessOutputDiagnostic: Equatable, Sendable {
    /// Why output could not be represented completely.
    public let kind: Kind
    /// The process stream affected by the diagnostic.
    public let stream: Stream
    /// The number of bytes discarded, saturated at `Int.max` when known.
    public let discardedByteCount: Int

    /// Creates an output diagnostic.
    ///
    /// - Parameters:
    ///   - stream: The process stream affected by the diagnostic.
    ///   - discardedByteCount: The number of discarded bytes when known.
    ///   - kind: The reason output could not be represented completely.
    public init(
        stream: Stream,
        discardedByteCount: Int,
        kind: Kind = .lineOverflow
    ) {
        self.kind = kind
        self.stream = stream
        self.discardedByteCount = discardedByteCount
    }

    /// Why output could not be represented completely.
    public enum Kind: String, Equatable, Sendable {
        /// One physical line exceeded the bounded line buffer.
        case lineOverflow
        /// A descendant kept the pipe open beyond the termination drain deadline.
        case truncated
    }

    /// A process output stream.
    public enum Stream: String, Equatable, Sendable {
        /// Claude's newline-delimited JSON protocol stream.
        case stdout
        /// Human-readable process diagnostics.
        case stderr
    }
}
