import Darwin
public import Foundation

/// One event from a running Claude child process.
public enum ClaudeProcessEvent: Sendable {
    /// One complete newline-framed stdout line (without the newline).
    case stdoutLine(Data)
    /// A stdout line exceeded the byte bound and was discarded.
    case stdoutOversized(byteCount: Int)
    /// One raw stderr chunk.
    case stderr(Data)
    /// The process terminated; always the final event.
    case exited(status: Int32)
}

/// A live child-process handle: its event stream and control callbacks.
public struct ClaudeProcessHandle: Sendable {
    /// Framed stdout/stderr/exit events. `exited` is always last.
    public let events: AsyncStream<ClaudeProcessEvent>
    /// Writes bytes to the child's stdin (caller appends the newline).
    public let writeStdin: @Sendable (Data) throws -> Void
    /// Closes stdin (EOF), the first stage of graceful termination.
    public let closeStdin: @Sendable () -> Void
    /// Sends SIGTERM.
    public let terminate: @Sendable () -> Void
    /// Sends SIGKILL.
    public let kill: @Sendable () -> Void

    public init(
        events: AsyncStream<ClaudeProcessEvent>,
        writeStdin: @escaping @Sendable (Data) throws -> Void,
        closeStdin: @escaping @Sendable () -> Void,
        terminate: @escaping @Sendable () -> Void,
        kill: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.writeStdin = writeStdin
        self.closeStdin = closeStdin
        self.terminate = terminate
        self.kill = kill
    }
}

/// Spawn failure before a child process exists (e.g. launcher ENOENT).
public struct ClaudeSpawnError: Error, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Spawns Claude child processes. Faked in tests.
public protocol ClaudeProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?
    ) throws -> ClaudeProcessHandle
}

/// The real `Foundation.Process` runner.
///
/// stdout and stderr are drained concurrently from the moment the process
/// starts (a stalled drain deadlocks the child). stdout is newline-framed with
/// the partial tail preserved across chunks and a 32 MiB single-line bound.
public struct ClaudeProcessRunner: ClaudeProcessRunning {
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = ClaudeLineFramer.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    public func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?
    ) throws -> ClaudeProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if let environment {
            process.environment = environment
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (events, continuation) = AsyncStream<ClaudeProcessEvent>.makeStream()

        do {
            try process.run()
        } catch {
            throw ClaudeSpawnError(message: "\(error.localizedDescription)")
        }

        let coordinator = DrainCoordinator(continuation: continuation)
        let maxLineBytes = self.maxLineBytes
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        Task.detached {
            var framer = ClaudeLineFramer(maxLineBytes: maxLineBytes)
            while true {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { break }
                for frame in framer.consume(chunk) {
                    switch frame {
                    case .line(let data):
                        continuation.yield(.stdoutLine(data))
                    case .oversized(let count):
                        continuation.yield(.stdoutOversized(byteCount: count))
                    }
                }
            }
            switch framer.finish() {
            case .line(let data):
                continuation.yield(.stdoutLine(data))
            case .oversized(let count):
                continuation.yield(.stdoutOversized(byteCount: count))
            case nil:
                break
            }
            try? stdoutHandle.close()
            coordinator.drainFinished()
        }

        Task.detached {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                continuation.yield(.stderr(chunk))
            }
            try? stderrHandle.close()
            coordinator.drainFinished()
        }

        process.terminationHandler = { finished in
            coordinator.processExited(status: finished.terminationStatus)
        }

        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdinBox = StdinBox(handle: stdinHandle)
        return ClaudeProcessHandle(
            events: events,
            writeStdin: { data in try stdinBox.write(data) },
            closeStdin: { stdinBox.close() },
            terminate: { process.terminate() },
            kill: { Darwin.kill(process.processIdentifier, SIGKILL) }
        )
    }
}

/// Emits `.exited` only after both drains and the termination handler fired,
/// so no stdout/stderr event can follow the terminal event.
private final class DrainCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<ClaudeProcessEvent>.Continuation
    private var remainingDrains = 2
    private var exitStatus: Int32?
    private var finished = false

    init(continuation: AsyncStream<ClaudeProcessEvent>.Continuation) {
        self.continuation = continuation
    }

    func drainFinished() {
        lock.lock()
        remainingDrains -= 1
        let done = remainingDrains == 0 && exitStatus != nil && !finished
        if done { finished = true }
        let status = exitStatus
        lock.unlock()
        if done, let status {
            continuation.yield(.exited(status: status))
            continuation.finish()
        }
    }

    func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let done = remainingDrains == 0 && !finished
        if done { finished = true }
        lock.unlock()
        if done {
            continuation.yield(.exited(status: status))
            continuation.finish()
        }
    }
}

/// Serializes stdin writes and makes close idempotent.
private final class StdinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw ClaudeSpawnError(message: "stdin is closed")
        }
        try handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
