import Darwin
import Foundation

actor SupermuxHarnessInputWriter {
    /// Covers the largest policy-valid 2 MiB image payload after base64 and JSON framing.
    private static let maximumQueuedBytes = 4 * 1024 * 1024

    private struct QueuedWrite {
        let id: UInt64
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ActiveWrite {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
        var task: Task<Void, Never>?
    }

    private let fileHandle: FileHandle
    private let descriptor: Int32
    private var queuedWrites: [QueuedWrite] = []
    private var queuedByteCount = 0
    private var activeWrite: ActiveWrite?
    private var isClosed = false
    private var nextWriteID: UInt64 = 0

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        self.descriptor = fileHandle.fileDescriptor
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            enqueue(data, continuation: continuation)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let active = activeWrite
        activeWrite = nil
        let writes = queuedWrites
        queuedWrites.removeAll()
        queuedByteCount = 0
        active?.task?.cancel()
        active?.continuation.resume(throwing: SupermuxHarnessProcessError.inputClosed)
        for write in writes {
            write.continuation.resume(throwing: SupermuxHarnessProcessError.inputClosed)
        }
        try? fileHandle.close()
        await active?.task?.value
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

        nextWriteID &+= 1
        queuedWrites.append(QueuedWrite(
            id: nextWriteID,
            data: data,
            continuation: continuation
        ))
        queuedByteCount += data.count
        startNextWriteIfNeeded()
    }

    private func startNextWriteIfNeeded() {
        guard !isClosed, activeWrite == nil, !queuedWrites.isEmpty else { return }
        let write = queuedWrites.removeFirst()
        queuedByteCount -= write.data.count
        activeWrite = ActiveWrite(
            id: write.id,
            continuation: write.continuation,
            task: nil
        )
        let writeDescriptor = Darwin.dup(descriptor)
        guard writeDescriptor >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            finishWrite(id: write.id, result: .failure(error))
            return
        }
        let flags = Darwin.fcntl(writeDescriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(writeDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(writeDescriptor)
            finishWrite(id: write.id, result: .failure(error))
            return
        }
        let id = write.id
        let data = write.data
        let task = Task.detached(priority: .utility) { [weak self] in
            defer { Darwin.close(writeDescriptor) }
            let result = Result { try Self.writeSynchronously(data, to: writeDescriptor) }
            await self?.finishWrite(id: id, result: result)
        }
        activeWrite?.task = task
    }

    private func finishWrite(id: UInt64, result: Result<Void, any Error>) {
        guard let activeWrite, activeWrite.id == id else { return }
        self.activeWrite = nil
        guard !isClosed else { return }
        switch result {
        case .success:
            activeWrite.continuation.resume()
            startNextWriteIfNeeded()
        case .failure(let error):
            activeWrite.continuation.resume(throwing: error)
            closeAfterWriteFailure(error)
        }
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

    private nonisolated static func writeSynchronously(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let pollResult = Darwin.poll(&state, 1, 50)
                    if pollResult >= 0 || errno == EINTR { continue }
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
