import Foundation

actor SupermuxHarnessInputWriter {
    /// Covers the largest policy-valid 2 MiB image payload after base64 and JSON framing.
    private static let maximumQueuedBytes = 4 * 1024 * 1024

    private let fileHandle: FileHandle
    private var queuedWrites: [(data: Data, continuation: CheckedContinuation<Void, any Error>)] = []
    private var queuedByteCount = 0
    private var isClosed = false
    private var isDraining = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            enqueue(data, continuation: continuation)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let writes = queuedWrites
        queuedWrites.removeAll()
        queuedByteCount = 0
        for write in writes {
            write.continuation.resume(throwing: SupermuxHarnessProcessError.inputClosed)
        }
        try? fileHandle.close()
    }

    private func enqueue(
        _ data: Data,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        guard !isClosed else {
            continuation.resume(throwing: SupermuxHarnessProcessError.inputClosed)
            return
        }
        guard queuedByteCount + data.count <= Self.maximumQueuedBytes else {
            continuation.resume(throwing: SupermuxHarnessProcessError.inputQueueFull)
            return
        }

        queuedWrites.append((data, continuation))
        queuedByteCount += data.count
        guard !isDraining else { return }
        isDraining = true
        Task(priority: .utility) {
            drain()
        }
    }

    private func drain() {
        while let write = queuedWrites.first {
            queuedWrites.removeFirst()
            queuedByteCount -= write.data.count
            do {
                try fileHandle.write(contentsOf: write.data)
                write.continuation.resume()
            } catch {
                write.continuation.resume(throwing: error)
                closeAfterWriteFailure(error)
                return
            }
        }
        isDraining = false
    }

    private func closeAfterWriteFailure(_ error: any Error) {
        isClosed = true
        let writes = queuedWrites
        queuedWrites.removeAll()
        queuedByteCount = 0
        for write in writes {
            write.continuation.resume(throwing: error)
        }
        try? fileHandle.close()
    }
}
