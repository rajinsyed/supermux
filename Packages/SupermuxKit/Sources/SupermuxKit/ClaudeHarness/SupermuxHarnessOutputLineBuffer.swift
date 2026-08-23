import Foundation

enum SupermuxHarnessOutputLineBufferEvent: Equatable {
    case line(String)
    case overflow(discardedByteCount: Int)
}

struct SupermuxHarnessOutputLineBuffer {
    static let maximumBufferedBytes = 1024 * 1024

    private var buffer = Data()
    private var isDiscardingOverflow = false
    private var discardedByteCount = 0

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func append(_ data: Data) -> [SupermuxHarnessOutputLineBufferEvent] {
        var events: [SupermuxHarnessOutputLineBufferEvent] = []
        var cursor = data.startIndex

        while cursor < data.endIndex {
            if isDiscardingOverflow {
                guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else {
                    addDiscardedBytes(data.distance(from: cursor, to: data.endIndex))
                    break
                }
                addDiscardedBytes(data.distance(from: cursor, to: newlineIndex))
                events.append(.overflow(discardedByteCount: discardedByteCount))
                resetOverflow()
                cursor = data.index(after: newlineIndex)
                continue
            }

            if let newlineIndex = data[cursor...].firstIndex(of: 0x0A) {
                let incomingByteCount = data.distance(from: cursor, to: newlineIndex)
                if buffer.count + incomingByteCount <= Self.maximumBufferedBytes {
                    buffer.append(contentsOf: data[cursor..<newlineIndex])
                    events.append(.line(String(decoding: buffer, as: UTF8.self) + "\n"))
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    beginOverflow(discarding: buffer.count + incomingByteCount)
                    events.append(.overflow(discardedByteCount: discardedByteCount))
                    resetOverflow()
                }
                cursor = data.index(after: newlineIndex)
                continue
            }

            let incomingByteCount = data.distance(from: cursor, to: data.endIndex)
            if buffer.count + incomingByteCount <= Self.maximumBufferedBytes {
                buffer.append(contentsOf: data[cursor..<data.endIndex])
            } else {
                beginOverflow(discarding: buffer.count + incomingByteCount)
            }
            break
        }

        return events
    }

    mutating func flush() -> [SupermuxHarnessOutputLineBufferEvent] {
        if isDiscardingOverflow {
            let event = SupermuxHarnessOutputLineBufferEvent.overflow(
                discardedByteCount: discardedByteCount
            )
            resetOverflow()
            return [event]
        }
        guard !buffer.isEmpty else { return [] }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return [.line(text)]
    }

    private mutating func beginOverflow(discarding byteCount: Int) {
        isDiscardingOverflow = true
        discardedByteCount = byteCount
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func addDiscardedBytes(_ byteCount: Int) {
        let (sum, overflowed) = discardedByteCount.addingReportingOverflow(byteCount)
        discardedByteCount = overflowed ? Int.max : sum
    }

    private mutating func resetOverflow() {
        isDiscardingOverflow = false
        discardedByteCount = 0
    }
}
