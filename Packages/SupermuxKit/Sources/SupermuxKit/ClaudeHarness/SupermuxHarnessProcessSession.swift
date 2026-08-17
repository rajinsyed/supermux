import Darwin
public import Foundation

/// Owns the lifecycle and stdio streams for exactly one multi-turn Claude Code process.
@MainActor
public final class SupermuxHarnessProcessSession {
    /// Whether a process is still tracked, including the interval while its output drains after exit.
    public var isRunning: Bool {
        runningProcess != nil
    }

    /// The active harness run identifier, or `nil` when stopped.
    public var activeRunID: String? {
        runningProcess?.runID
    }

    private let decoder: SupermuxHarnessProtocolDecoder
    private let protocolLineSink: SupermuxHarnessProtocolLineSink
    private let stderrSink: SupermuxHarnessStderrSink
    private let lifecycleSink: SupermuxHarnessLifecycleSink
    private let terminationEscalationNanoseconds: Int
    private var runningProcess: SupermuxHarnessRunningProcess?
    /// Keeps escalation alive after the panel releases its process-session owner.
    private var terminationRetainer: SupermuxHarnessProcessSession?

    /// Creates a single-process session.
    ///
    /// - Parameters:
    ///   - decoder: The tolerant stdout protocol decoder.
    ///   - terminationEscalationInterval: Seconds between SIGTERM, SIGKILL, and forced-drain checks.
    ///   - protocolLineSink: Receives every valid stdout JSON line, including unknown frame types.
    ///   - stderrSink: Receives stderr text.
    ///   - lifecycleSink: Receives start and fully-drained exit events.
    public init(
        decoder: SupermuxHarnessProtocolDecoder = SupermuxHarnessProtocolDecoder(),
        terminationEscalationInterval: TimeInterval = 3,
        protocolLineSink: @escaping SupermuxHarnessProtocolLineSink,
        stderrSink: @escaping SupermuxHarnessStderrSink,
        lifecycleSink: @escaping SupermuxHarnessLifecycleSink
    ) {
        self.decoder = decoder
        self.protocolLineSink = protocolLineSink
        self.stderrSink = stderrSink
        self.lifecycleSink = lifecycleSink
        terminationEscalationNanoseconds = max(1, Int(terminationEscalationInterval * 1_000_000_000))
    }

    /// Launches the configured Claude process and keeps stdin open for multiple turns.
    ///
    /// - Parameter plan: The executable, arguments, environment, and working directory.
    /// - Returns: The run and operating-system process identifiers.
    /// - Throws: ``SupermuxHarnessProcessError/alreadyRunning`` or a Foundation process-launch error.
    @discardableResult
    public func start(plan: SupermuxHarnessLaunchPlan) throws -> SupermuxHarnessStartedProcess {
        guard runningProcess == nil else {
            throw SupermuxHarnessProcessError.alreadyRunning
        }

        let runID = UUID().uuidString
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectoryURL

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let inputWriter = SupermuxHarnessInputWriter(fileHandle: stdin.fileHandleForWriting)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let session = SupermuxHarnessRunningProcess(
            runID: runID,
            process: process,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            inputWriter: inputWriter
        )
        runningProcess = session
        session.stdoutReadTask = makeReadTask(
            fileDescriptor: stdout.fileHandleForReading.fileDescriptor,
            runID: runID,
            stream: .stdout
        )
        session.stderrReadTask = makeReadTask(
            fileDescriptor: stderr.fileHandleForReading.fileDescriptor,
            runID: runID,
            stream: .stderr
        )
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor in
                guard let self,
                      let current = self.runningProcess,
                      current.runID == runID else {
                    return
                }
                current.pendingExitStatus = status
                self.finishIfExitedAndDrained(current)
            }
        }

        do {
            try process.run()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        } catch {
            process.terminationHandler = nil
            session.stdoutReadTask?.cancel()
            session.stderrReadTask?.cancel()
            try? stdin.fileHandleForReading.close()
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
            runningProcess = nil
            throw error
        }

        let started = SupermuxHarnessStartedProcess(
            runID: runID,
            processID: process.processIdentifier
        )
        lifecycleSink(.started(runID: started.runID, processID: started.processID))
        return started
    }

    /// Writes one encoded protocol frame through the serialized one-megabyte stdin queue.
    ///
    /// - Parameter frame: A newline-terminated frame produced by ``SupermuxHarnessProtocolEncoder``.
    /// - Throws: ``SupermuxHarnessProcessError/notRunning`` or an input-writer error.
    public func send(_ frame: SupermuxHarnessEncodedFrame) async throws {
        try await sendFrame(frame, expectedRunID: nil)
    }

    /// Writes a frame only when the identified run is still the active process.
    ///
    /// - Parameters:
    ///   - frame: A newline-terminated frame produced by ``SupermuxHarnessProtocolEncoder``.
    ///   - runID: The run that owns the control request producing this frame.
    /// - Throws: ``SupermuxHarnessProcessError/notRunning`` when another run replaced it, or an
    ///   input-writer error.
    public func send(_ frame: SupermuxHarnessEncodedFrame, forRunID runID: String) async throws {
        try await sendFrame(frame, expectedRunID: runID)
    }

    /// Closes stdin without sending a signal, allowing Claude Code to end gracefully.
    ///
    /// - Throws: ``SupermuxHarnessProcessError/notRunning`` when no process is active.
    public func closeInput() async throws {
        guard let session = runningProcess else {
            throw SupermuxHarnessProcessError.notRunning
        }
        await session.inputWriter.close()
    }

    /// Sends SIGTERM and installs the three-second SIGKILL escalation cycle.
    ///
    /// - Throws: ``SupermuxHarnessProcessError/notRunning`` when no process is active.
    public func terminate() throws {
        guard let session = runningProcess else {
            throw SupermuxHarnessProcessError.notRunning
        }
        requestTermination(session)
    }

    /// Terminates the active process when present and otherwise does nothing.
    public func close() {
        guard let session = runningProcess else { return }
        requestTermination(session)
    }

    private func sendFrame(
        _ frame: SupermuxHarnessEncodedFrame,
        expectedRunID: String?
    ) async throws {
        guard let session = runningProcess,
              expectedRunID == nil || session.runID == expectedRunID else {
            throw SupermuxHarnessProcessError.notRunning
        }
        guard !session.isTerminating else {
            throw SupermuxHarnessProcessError.inputClosed
        }
        try await session.inputWriter.write(frame.lineData)
    }

    private func makeReadTask(
        fileDescriptor: Int32,
        runID: String,
        stream: SupermuxHarnessProcessStream
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { storage in
                    Darwin.read(fileDescriptor, storage.baseAddress, storage.count)
                }
                if count > 0 {
                    let data = Data(bytes: bytes, count: count)
                    await self?.consume(data, runID: runID, stream: stream)
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                await self?.consume(Data(), runID: runID, stream: stream)
                return
            }
        }
    }

    private func consume(
        _ data: Data,
        runID: String,
        stream: SupermuxHarnessProcessStream
    ) {
        guard let session = runningProcess, session.runID == runID else { return }
        if data.isEmpty {
            for line in session.flush(stream: stream) {
                emit(line, stream: stream)
            }
            session.drainedStreams.insert(stream)
            finishIfExitedAndDrained(session)
            return
        }
        for line in session.append(data, stream: stream) {
            emit(line, stream: stream)
        }
    }

    private func emit(_ text: String, stream: SupermuxHarnessProcessStream) {
        switch stream {
        case .stdout:
            guard let decoded = try? decoder.decodeLine(text) else { return }
            protocolLineSink(decoded)
        case .stderr:
            stderrSink(text)
        }
    }

    private func finishIfExitedAndDrained(_ session: SupermuxHarnessRunningProcess) {
        guard let status = session.pendingExitStatus,
              session.drainedStreams.isSuperset(of: [.stdout, .stderr]),
              runningProcess === session else {
            return
        }
        runningProcess = nil
        cancelTasks(session)
        terminationRetainer = nil
        lifecycleSink(.exited(runID: session.runID, status: status))
    }

    private func requestTermination(_ session: SupermuxHarnessRunningProcess) {
        terminationRetainer = self
        if !session.isTerminating {
            session.isTerminating = true
            Task {
                await session.inputWriter.close()
            }
        }
        if session.process.isRunning {
            session.process.terminate()
        }
        installTerminationEscalationTimer(session)
    }

    private func installTerminationEscalationTimer(_ session: SupermuxHarnessRunningProcess) {
        guard session.terminationEscalationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = DispatchTimeInterval.nanoseconds(terminationEscalationNanoseconds)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        let runID = session.runID
        // Explicit sendability prevents main-actor inheritance on the timer's global dispatch queue.
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleTerminationEscalation(runID: runID)
            }
        }
        session.terminationEscalationTimer = timer
        timer.resume()
    }

    private func handleTerminationEscalation(runID: String) {
        guard let session = runningProcess, session.runID == runID else { return }
        if session.process.isRunning {
            _ = Darwin.kill(session.process.processIdentifier, SIGKILL)
            return
        }
        guard session.pendingExitStatus != nil else { return }
        session.drainedStreams.formUnion([.stdout, .stderr])
        finishIfExitedAndDrained(session)
    }

    private func cancelTasks(_ session: SupermuxHarnessRunningProcess) {
        session.process.terminationHandler = nil
        session.terminationEscalationTimer?.cancel()
        session.terminationEscalationTimer = nil
        try? session.stdout.fileHandleForReading.close()
        try? session.stderr.fileHandleForReading.close()
        session.stdoutReadTask?.cancel()
        session.stdoutReadTask = nil
        session.stderrReadTask?.cancel()
        session.stderrReadTask = nil
        Task {
            await session.inputWriter.close()
        }
    }
}
