import Foundation

/// The process lifecycle phase of one Claude session.
///
/// Every spawn receives a monotonically increasing generation; events carrying
/// a stale generation are ignored. Process phase and turn phase are separate:
/// interrupting a turn does not change the process phase.
public enum ClaudeProcessPhase: Sendable, Equatable {
    case dormant
    case spawning(generation: UInt64)
    case handshaking(generation: UInt64)
    case running(generation: UInt64)
    case stopping(generation: UInt64)
    case exited(ClaudeProcessExit)
    case failed(message: String)

    /// The live generation, when one exists.
    public var generation: UInt64? {
        switch self {
        case .spawning(let g), .handshaking(let g), .running(let g), .stopping(let g):
            return g
        case .dormant, .exited, .failed:
            return nil
        }
    }
}

/// How a process ended.
public struct ClaudeProcessExit: Sendable, Equatable {
    public let status: Int32?
    public let wasClean: Bool

    public init(status: Int32?, wasClean: Bool) {
        self.status = status
        self.wasClean = wasClean
    }
}

/// The turn lifecycle within a running process.
///
/// There is no permission phase: sessions always run with
/// `--dangerously-skip-permissions`, so a turn is never blocked on approval.
public enum ClaudeTurnPhase: Sendable, Equatable {
    case idle
    /// A queued input was written; awaiting authoritative turn evidence.
    case dispatching(inputID: UUID)
    /// A turn is streaming.
    case active(inputID: UUID?)
    /// An interrupt control was sent; awaiting the terminal `result`.
    case interrupting
    /// A write succeeded but the process ended before authoritative evidence;
    /// delivery is unknowable and the input must not be auto-resent.
    case uncertain(inputID: UUID)
}

/// The combined session state machine with generation-tagged transitions.
public struct ClaudeSessionStateMachine: Sendable, Equatable {
    public private(set) var processPhase: ClaudeProcessPhase = .dormant
    public private(set) var turnPhase: ClaudeTurnPhase = .idle
    private var nextGeneration: UInt64 = 0

    public init() {}

    /// Starts a new spawn, returning its generation.
    public mutating func beginSpawn() -> UInt64 {
        nextGeneration += 1
        processPhase = .spawning(generation: nextGeneration)
        turnPhase = .idle
        return nextGeneration
    }

    /// Marks the process as spawned and handshaking (awaiting `system.init`).
    /// Ignored for stale generations.
    public mutating func processStarted(generation: UInt64) {
        guard processPhase.generation == generation else { return }
        processPhase = .handshaking(generation: generation)
    }

    /// Applies the `system.init` handshake. Ignored for stale generations.
    public mutating func initialized(generation: UInt64) {
        guard processPhase.generation == generation else { return }
        processPhase = .running(generation: generation)
    }

    /// Begins teardown. Ignored for stale generations.
    public mutating func beginStopping(generation: UInt64) {
        guard processPhase.generation == generation else { return }
        processPhase = .stopping(generation: generation)
    }

    /// Finishes the process exactly once per generation. Returns `false` when
    /// the generation was stale or already finished.
    @discardableResult
    public mutating func finishProcess(generation: UInt64, exit: ClaudeProcessExit) -> Bool {
        guard processPhase.generation == generation else { return false }
        processPhase = .exited(exit)
        switch turnPhase {
        case .dispatching(let inputID), .active(.some(let inputID)):
            turnPhase = .uncertain(inputID: inputID)
        case .active(nil), .interrupting:
            turnPhase = .idle
        case .idle, .uncertain:
            break
        }
        return true
    }

    /// Records a pre-spawn failure (e.g. launcher ENOENT).
    public mutating func failSpawn(generation: UInt64, message: String) {
        guard processPhase.generation == generation else { return }
        processPhase = .failed(message: message)
        turnPhase = .idle
    }

    /// A queued input was written to stdin.
    public mutating func beginDispatch(inputID: UUID) {
        turnPhase = .dispatching(inputID: inputID)
    }

    /// Authoritative turn evidence arrived (replayed user line or streaming).
    public mutating func turnStarted() {
        switch turnPhase {
        case .dispatching(let inputID):
            turnPhase = .active(inputID: inputID)
        case .idle:
            turnPhase = .active(inputID: nil)
        case .active, .interrupting, .uncertain:
            break
        }
    }

    /// An interrupt control was dispatched.
    public mutating func beginInterrupt() {
        turnPhase = .interrupting
    }

    /// The authoritative terminal `result` line arrived; turn is over.
    public mutating func turnFinished() {
        turnPhase = .idle
    }
}
