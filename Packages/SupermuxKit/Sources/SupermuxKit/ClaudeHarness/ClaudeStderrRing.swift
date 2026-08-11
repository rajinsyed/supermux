public import Foundation
import SupermuxClaudeHarness

/// Bounded tail of the child's stderr, ANSI-stripped.
///
/// Keeps only the most recent `capacity` bytes (default 64 KiB) so a stderr
/// flood cannot grow memory, while the tail remains available for launcher
/// failure diagnostics (e.g. ccx's proxy-down die()).
public struct ClaudeStderrRing: Sendable {
    public static let defaultCapacity = 64 * 1024

    private let capacity: Int
    private var buffer = Data()

    public init(capacity: Int = ClaudeStderrRing.defaultCapacity) {
        self.capacity = capacity
    }

    /// Appends one raw stderr chunk, trimming to the byte capacity.
    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// The retained tail as ANSI-stripped text.
    public var text: String {
        ClaudeLineClassifier.strippingANSI(String(decoding: buffer, as: UTF8.self))
    }

    public var isEmpty: Bool { buffer.isEmpty }
}
