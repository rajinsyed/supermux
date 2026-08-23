import Foundation

@MainActor
final class SupermuxHarnessRunningProcess {
    let runID: String
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    let stderr: Pipe
    let inputWriter: SupermuxHarnessInputWriter
    var stdoutReadTask: Task<Void, Never>?
    var stderrReadTask: Task<Void, Never>?
    /// A repeating deadline source is required because pipe descendants may outlive the killed process.
    var terminationEscalationTimer: (any DispatchSourceTimer)?
    var pendingExitStatus: Int32?
    var forcedDrainDeadline: ContinuousClock.Instant?
    var isTerminating = false
    var isForcedDrainInProgress = false
    var drainedStreams: Set<SupermuxHarnessProcessStream> = []
    private var stdoutBuffer = SupermuxHarnessOutputLineBuffer()
    private var stderrBuffer = SupermuxHarnessOutputLineBuffer()

    init(
        runID: String,
        process: Process,
        stdin: Pipe,
        stdout: Pipe,
        stderr: Pipe,
        inputWriter: SupermuxHarnessInputWriter
    ) {
        self.runID = runID
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.inputWriter = inputWriter
    }

    func append(_ data: Data, stream: SupermuxHarnessProcessStream) -> [SupermuxHarnessOutputLineBufferEvent] {
        switch stream {
        case .stdout:
            stdoutBuffer.append(data)
        case .stderr:
            stderrBuffer.append(data)
        }
    }

    func flush(stream: SupermuxHarnessProcessStream) -> [SupermuxHarnessOutputLineBufferEvent] {
        switch stream {
        case .stdout:
            stdoutBuffer.flush()
        case .stderr:
            stderrBuffer.flush()
        }
    }
}

enum SupermuxHarnessProcessStream: String, Sendable {
    case stdout
    case stderr
}
