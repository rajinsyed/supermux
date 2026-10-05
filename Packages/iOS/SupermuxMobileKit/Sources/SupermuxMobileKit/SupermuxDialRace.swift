/// Races a direct dial against the automatic one, direct first.
///
/// The direct leg starts at once. The fallback starts after ``headStart``, or
/// as soon as the direct leg fails, whichever is first. The first success
/// wins. A leg that succeeds after the race is decided goes to `discard`
/// (closed before anything uses it), so the Mac admits exactly one
/// connection. A direct leg still pending at ``directDeadline`` counts as
/// failed for deciding the race, but a late success still wins if the
/// fallback has not.
///
/// With no fallback the race is one direct attempt bounded by
/// ``directDeadline``: the route prober's handshake.
public struct SupermuxDialRace: Sendable {
    /// The direct leg's default head start.
    public static let defaultHeadStart: Duration = .milliseconds(250)
    /// The direct leg's default deadline.
    public static let defaultDirectDeadline: Duration = .milliseconds(1500)

    /// The race failed with nothing more specific to report.
    public enum Failure: Error, Equatable, Sendable {
        /// The direct leg was still pending at the deadline and there was no
        /// fallback.
        case directTimedOut
    }

    /// How long the direct leg runs alone.
    public let headStart: Duration
    /// How long the direct leg may take before it counts as failed.
    public let directDeadline: Duration

    /// Creates a race.
    /// - Parameters:
    ///   - headStart: How long the direct leg runs alone.
    ///   - directDeadline: How long the direct leg may take.
    public init(headStart: Duration = Self.defaultHeadStart, directDeadline: Duration = Self.defaultDirectDeadline) {
        self.headStart = headStart
        self.directDeadline = directDeadline
    }

    /// Runs the race.
    /// - Parameters:
    ///   - direct: The direct dial.
    ///   - fallback: The automatic dial, or nil for a direct attempt only.
    ///   - discard: Closes a connection that lost the race.
    /// - Returns: The winning connection and the lane it used.
    /// - Throws: The fallback's error when both legs fail, the direct leg's
    ///   error (or ``Failure/directTimedOut``) when there is no fallback, and
    ///   `CancellationError` when the caller is cancelled.
    public func run<Value: Sendable>(
        direct: @escaping @Sendable () async throws -> Value,
        fallback: (@Sendable () async throws -> Value)?,
        discard: @escaping @Sendable (Value) async -> Void
    ) async throws -> (value: Value, lane: SupermuxDialLane) {
        let referee = SupermuxDialRaceReferee<Value>(fallback: fallback, discard: discard)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await referee.start(
                        continuation, direct: direct, headStart: headStart, directDeadline: directDeadline)
                }
            }
        } onCancel: {
            Task { await referee.cancel() }
        }
    }
}

/// Decides one ``SupermuxDialRace``. The legs run as unstructured tasks so
/// the race returns as soon as it is decided; a leg that finishes later is
/// discarded here. The tasks inherit this actor's isolation; each leg's dial
/// runs off it.
private actor SupermuxDialRaceReferee<Value: Sendable> {
    private enum Leg {
        case notStarted, running, failed(any Error)
    }

    private let fallbackDial: (@Sendable () async throws -> Value)?
    private let discard: @Sendable (Value) async -> Void
    private var continuation: CheckedContinuation<(value: Value, lane: SupermuxDialLane), any Error>?
    private var decided = false
    private var directLeg = Leg.notStarted
    private var fallbackLeg = Leg.notStarted
    private var tasks: [Task<Void, Never>] = []

    init(fallback: (@Sendable () async throws -> Value)?, discard: @escaping @Sendable (Value) async -> Void) {
        fallbackDial = fallback
        self.discard = discard
    }

    func start(
        _ continuation: CheckedContinuation<(value: Value, lane: SupermuxDialLane), any Error>,
        direct: @escaping @Sendable () async throws -> Value,
        headStart: Duration,
        directDeadline: Duration
    ) {
        guard !decided else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        directLeg = .running
        tasks.append(Task {
            do {
                let value = try await direct()
                await self.succeeded(value, lane: .direct)
            } catch {
                self.directFailed(error)
            }
        })
        tasks.append(Task {
            try? await Task.sleep(for: directDeadline)
            guard !Task.isCancelled else { return }
            self.directFailed(SupermuxDialRace.Failure.directTimedOut)
        })
        if fallbackDial != nil {
            tasks.append(Task {
                try? await Task.sleep(for: headStart)
                guard !Task.isCancelled else { return }
                self.startFallback()
            })
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func startFallback() {
        guard !decided, case .notStarted = fallbackLeg, let fallbackDial else { return }
        fallbackLeg = .running
        tasks.append(Task {
            do {
                let value = try await fallbackDial()
                await self.succeeded(value, lane: .automatic)
            } catch {
                self.fallbackFailed(error)
            }
        })
    }

    private func succeeded(_ value: Value, lane: SupermuxDialLane) async {
        guard !decided else {
            await discard(value)
            return
        }
        finish(.success((value, lane)))
    }

    private func directFailed(_ error: any Error) {
        guard !decided, case .running = directLeg else { return }
        directLeg = .failed(error)
        switch fallbackLeg {
        case .notStarted where fallbackDial != nil:
            startFallback()
        case .notStarted:
            finish(.failure(error))
        case let .failed(fallbackError):
            finish(.failure(fallbackError))
        case .running:
            break
        }
    }

    private func fallbackFailed(_ error: any Error) {
        guard !decided else { return }
        fallbackLeg = .failed(error)
        if case .failed = directLeg { finish(.failure(error)) }
    }

    private func finish(_ result: Result<(value: Value, lane: SupermuxDialLane), any Error>) {
        guard !decided else { return }
        decided = true
        // The losing leg is cancelled; if it still produces a connection,
        // `succeeded` discards it.
        for task in tasks { task.cancel() }
        tasks.removeAll()
        continuation?.resume(with: result)
        continuation = nil
    }
}
