import Foundation

/// Correlates outbound control requests with their `control_response` lines.
///
/// Transport-agnostic: the owner injects a write callback and feeds every
/// decoded stream line through ``handleLine(_:)``. Only OUTBOUND controls are
/// multiplexed — inbound `control_request` lines are surfaced as diagnostics
/// and never answered (permissions are always skipped in this harness).
///
/// Invariants:
/// - a pending continuation is registered before the line is written;
/// - a continuation is removed from the map before it is resumed, so it can
///   never resume twice;
/// - `failAll` resumes every pending continuation exactly once (process exit);
/// - late or unknown response IDs are diagnosed and ignored.
public actor ClaudeControlMultiplexer {
    /// Deadlines per request class, injectable for tests.
    public struct Timeouts: Sendable {
        public var ordinary: Duration
        public var cold: Duration
        public var interrupt: Duration

        public init(
            ordinary: Duration = .seconds(12),
            cold: Duration = .seconds(30),
            interrupt: Duration = .seconds(5)
        ) {
            self.ordinary = ordinary
            self.cold = cold
            self.interrupt = interrupt
        }

        func deadline(for control: ClaudeOutboundControl) -> Duration {
            switch control {
            case .initialize, .getBinaryVersion, .listModels: return cold
            case .interrupt: return interrupt
            default: return ordinary
            }
        }
    }

    private struct Pending {
        let subtype: String
        let continuation: CheckedContinuation<ClaudeControlResponseEnvelope, any Error>
        let timeoutTask: Task<Void, Never>
    }

    public typealias WriteLine = @Sendable (Data) async throws -> Void
    public typealias DiagnosticSink = @Sendable (ClaudeHarnessDiagnostic) -> Void

    private let writeLine: WriteLine
    private let diagnostic: DiagnosticSink
    private let timeouts: Timeouts
    private let clock: ContinuousClock
    private let requestPrefix: String
    private var counter: UInt64 = 0
    private var pending: [String: Pending] = [:]
    private var failed = false

    /// Creates a multiplexer bound to one process generation.
    ///
    /// - Parameters:
    ///   - requestPrefix: Unique per process spawn (session UUID + nonce) so
    ///     IDs never collide across restarts or copied logs.
    ///   - writeLine: Writes one complete line (newline appended by the transport).
    ///   - diagnostic: Receives non-fatal protocol observations.
    public init(
        requestPrefix: String,
        timeouts: Timeouts = Timeouts(),
        clock: ContinuousClock = ContinuousClock(),
        writeLine: @escaping WriteLine,
        diagnostic: @escaping DiagnosticSink = { _ in }
    ) {
        self.requestPrefix = requestPrefix
        self.timeouts = timeouts
        self.clock = clock
        self.writeLine = writeLine
        self.diagnostic = diagnostic
    }

    /// Sends one control and suspends until its response, timeout, failure, or
    /// caller cancellation (cancelling the awaiting task resumes it with
    /// `CancellationError` and drops the pending entry immediately).
    public func send(
        _ control: ClaudeOutboundControl
    ) async throws -> ClaudeControlResponseEnvelope {
        if failed {
            throw ClaudeControlError.processExited(subtype: control.subtype)
        }
        counter += 1
        let requestID = "\(requestPrefix)-\(counter)"
        let deadline = timeouts.deadline(for: control)

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ClaudeControlResponseEnvelope, any Error>) in
                // A task cancelled before registration must not leave a
                // pending entry the onCancel hop can never find.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [clock] in
                    try? await clock.sleep(for: deadline)
                    guard !Task.isCancelled else { return }
                    self.timeOut(requestID: requestID)
                }
                pending[requestID] = Pending(
                    subtype: control.subtype,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task {
                    do {
                        try await self.writeLine(control.encodedLine(requestID: requestID))
                    } catch {
                        self.failWrite(requestID: requestID, message: "\(error)")
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPending(requestID: requestID) }
        }
        if response.isSuccess {
            return response
        }
        throw ClaudeControlError.rejected(
            subtype: control.subtype,
            message: response.errorMessage
        )
    }

    /// Feeds one decoded stream line; returns `true` when the line was a
    /// control response consumed by a pending request.
    @discardableResult
    public func handleLine(_ line: ClaudeStreamLine) -> Bool {
        switch line {
        case .controlResponse(let envelope):
            guard let requestID = envelope.requestID,
                  let entry = pending.removeValue(forKey: requestID) else {
                if case .controlResponse(let env) = line {
                    diagnostic(.unmatchedControlResponse(requestID: env.requestID))
                }
                return false
            }
            entry.timeoutTask.cancel()
            entry.continuation.resume(returning: envelope)
            return true
        case .controlRequest(let request):
            diagnostic(.inboundControlRequestIgnored(
                subtype: request.subtype,
                requestID: request.requestID
            ))
            return false
        default:
            return false
        }
    }

    /// Fails every pending request exactly once; subsequent sends fail fast.
    public func failAll() {
        failed = true
        let entries = pending
        pending.removeAll()
        for (_, entry) in entries {
            entry.timeoutTask.cancel()
            entry.continuation.resume(
                throwing: ClaudeControlError.processExited(subtype: entry.subtype)
            )
        }
    }

    /// The number of requests still awaiting a response.
    public var pendingCount: Int { pending.count }

    private func cancelPending(requestID: String) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.timeoutTask.cancel()
        entry.continuation.resume(throwing: CancellationError())
    }

    private func timeOut(requestID: String) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.continuation.resume(
            throwing: ClaudeControlError.timedOut(subtype: entry.subtype)
        )
    }

    private func failWrite(requestID: String, message: String) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.timeoutTask.cancel()
        entry.continuation.resume(
            throwing: ClaudeControlError.writeFailed(subtype: entry.subtype, message: message)
        )
    }
}
