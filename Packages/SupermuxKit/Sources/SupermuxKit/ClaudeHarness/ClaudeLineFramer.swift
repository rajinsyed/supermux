public import Foundation

/// Newline-framer for the Claude stdout pipe.
///
/// Preserves an incomplete final fragment across chunk boundaries until EOF and
/// bounds a single line: once accumulation exceeds `maxLineBytes` the content
/// is discarded through the next newline and reported as `.oversized`.
public struct ClaudeLineFramer: Sendable {
    /// One framed unit of stdout.
    public enum Frame: Sendable, Equatable {
        case line(Data)
        case oversized(byteCount: Int)
    }

    /// Default single-line byte bound (32 MiB).
    public static let defaultMaxLineBytes = 32 * 1024 * 1024

    private let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false
    private var discardedCount = 0

    public init(maxLineBytes: Int = ClaudeLineFramer.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Consumes one chunk from the pipe, returning every completed frame.
    public mutating func consume(_ chunk: Data) -> [Frame] {
        var frames: [Frame] = []
        var start = chunk.startIndex
        while let newlineIndex = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let piece = chunk[start..<newlineIndex]
            if discarding {
                frames.append(.oversized(byteCount: discardedCount + piece.count))
                discarding = false
                discardedCount = 0
            } else if buffer.count + piece.count > maxLineBytes {
                // The bound holds even when the newline arrives in the same
                // chunk as the over-limit bytes.
                frames.append(.oversized(byteCount: buffer.count + piece.count))
                buffer = Data()
            } else {
                buffer.append(contentsOf: piece)
                frames.append(.line(buffer))
                buffer = Data()
            }
            start = chunk.index(after: newlineIndex)
        }
        let tail = chunk[start...]
        if discarding {
            discardedCount += tail.count
        } else {
            buffer.append(contentsOf: tail)
            if buffer.count > maxLineBytes {
                discarding = true
                discardedCount = buffer.count
                buffer = Data()
            }
        }
        return frames
    }

    /// Flushes the final unterminated fragment at EOF, if any.
    public mutating func finish() -> Frame? {
        if discarding {
            let frame = Frame.oversized(byteCount: discardedCount)
            discarding = false
            discardedCount = 0
            return frame
        }
        guard !buffer.isEmpty else { return nil }
        let frame = Frame.line(buffer)
        buffer = Data()
        return frame
    }
}
