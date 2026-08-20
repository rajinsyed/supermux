import Foundation

enum SupermuxHarnessOutputLineBufferEvent: Equatable {
    case line(String)
    case overflow(discardedByteCount: Int)
}

struct SupermuxHarnessOutputLineBuffer {
    static let maximumBufferedBytes = 1024 * 1024

    private var buffer = Data()

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func append(_ data: Data) -> [SupermuxHarnessOutputLineBufferEvent] {
        var lines: [SupermuxHarnessOutputLineBufferEvent] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let availableByteCount = max(1, Self.maximumBufferedBytes - buffer.count)
            let remainingByteCount = data.distance(from: cursor, to: data.endIndex)
            let chunkEnd = data.index(cursor, offsetBy: min(availableByteCount, remainingByteCount))
            buffer.append(contentsOf: data[cursor..<chunkEnd])
            cursor = chunkEnd
            drainCompleteLines(into: &lines)
            if buffer.count >= Self.maximumBufferedBytes {
                lines.append(.line(String(decoding: buffer, as: UTF8.self) + "\n"))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return lines
    }

    mutating func flush() -> [SupermuxHarnessOutputLineBufferEvent] {
        guard !buffer.isEmpty else { return [] }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return [.line(text)]
    }

    private mutating func drainCompleteLines(into lines: inout [SupermuxHarnessOutputLineBufferEvent]) {
        var cursor = buffer.startIndex
        var consumedEnd: Data.Index?
        while cursor < buffer.endIndex,
              let newlineIndex = buffer[cursor...].firstIndex(of: 0x0A) {
            let lineData = buffer[cursor..<newlineIndex]
            lines.append(.line(String(decoding: lineData, as: UTF8.self) + "\n"))
            cursor = buffer.index(after: newlineIndex)
            consumedEnd = cursor
        }
        if let consumedEnd {
            buffer.removeSubrange(buffer.startIndex..<consumedEnd)
        }
    }
}
