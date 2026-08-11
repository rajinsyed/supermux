public import Foundation
public import SupermuxClaudeHarness

/// The per-session process/protocol actor.
///
/// Owns one Claude child process at a time (generation-tagged), the control
/// multiplexer, the harness input queue, and the state machine. Every session
/// runs with `--dangerously-skip-permissions` (added by the harness for
/// claude/custom launchers, provided by ccx itself) — there is no permission
/// answering path; inbound `control_request` lines surface as diagnostics.
public actor ClaudeSession {
    public let configuration: ClaudeSessionConfiguration

    private let runner: any ClaudeProcessRunning
    private let persistence: (any ClaudeSessionPersisting)?
    private let controlTimeouts: ClaudeControlMultiplexer.Timeouts
    private let terminateGrace: Duration

    /// Default bound on retained transcript lines (oldest dropped first).
    public static let defaultMaxTranscriptLines = 5000

    private let maxTranscriptLines: Int
    private var machine = ClaudeSessionStateMachine()
    private var queue = ClaudeInputQueue()
    private var accumulator = ClaudeStreamAccumulator()
    private var transcript: [ClaudeTranscriptLine] = []
    private var nextSeq: UInt64 = 0
    private var handle: ClaudeProcessHandle?
    private var multiplexer: ClaudeControlMultiplexer?
    private var eventTask: Task<Void, Never>?
    private var stderrRing = ClaudeStderrRing()
    private var providerSessionID: String?
    private var rejectedGeneration: UInt64?
    private var initialization: ClaudeSystemInitialization?
    private var lastResult: ClaudeResult?
    private var lastRedactedStderrTail: String?
    private var subscribers: [UUID: AsyncStream<ClaudeSessionChange>.Continuation] = [:]

    public init(
        configuration: ClaudeSessionConfiguration,
        runner: any ClaudeProcessRunning = ClaudeProcessRunner(),
        persistence: (any ClaudeSessionPersisting)? = nil,
        controlTimeouts: ClaudeControlMultiplexer.Timeouts = .init(),
        terminateGrace: Duration = .seconds(3),
        maxTranscriptLines: Int = ClaudeSession.defaultMaxTranscriptLines
    ) {
        self.configuration = configuration
        self.runner = runner
        self.persistence = persistence
        self.controlTimeouts = controlTimeouts
        self.terminateGrace = terminateGrace
        self.maxTranscriptLines = maxTranscriptLines
    }

    // MARK: - Observation

    /// A stream of session changes; finishes when the session is removed.
    public func changes() -> AsyncStream<ClaudeSessionChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ClaudeSessionChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeSubscriber(id) }
        }
        return stream
    }

    public var processPhase: ClaudeProcessPhase { machine.processPhase }
    public var turnPhase: ClaudeTurnPhase { machine.turnPhase }
    public var queuedInputs: [ClaudeQueuedInput] { queue.entries }
    public var claudeSessionID: String? { providerSessionID }
    public var systemInitialization: ClaudeSystemInitialization? { initialization }
    public var latestResult: ClaudeResult? { lastResult }
    public var stderrTail: String { stderrRing.text }
    /// The reconciled in-flight/completed assistant messages, for view backfill.
    public var accumulatedMessages: [ClaudeStreamAccumulator.Message] {
        accumulator.messages
    }

    /// The bounded retained transcript, for backfill when a view or observer
    /// subscribes after lines already streamed.
    public var transcriptLines: [ClaudeTranscriptLine] { transcript }

    /// The sequence number of the most recent retained line (0 when none).
    public var latestSeq: UInt64 { nextSeq }

    /// Retained lines after `seq`, for gap recovery (e.g. mobile resync).
    public func transcriptTail(afterSeq seq: UInt64) -> [ClaudeTranscriptLine] {
        transcript.filter { $0.seq > seq }
    }

    // MARK: - Lifecycle

    /// Spawns the child process for this session's configuration.
    public func start() throws {
        guard machine.processPhase.generation == nil else { return }
        let generation = machine.beginSpawn()
        emitState()

        let mux = ClaudeControlMultiplexer(
            requestPrefix: "smx-\(configuration.id.uuidString.lowercased())-\(UInt32.random(in: 0..<UInt32.max))",
            timeouts: controlTimeouts,
            writeLine: { [weak self] data in
                try await self?.writeLine(data)
            },
            diagnostic: { [weak self] diagnostic in
                Task { await self?.emit(.diagnostic(diagnostic)) }
            }
        )
        multiplexer = mux

        do {
            let handle = try runner.run(
                executablePath: configuration.launcher.executablePath,
                arguments: configuration.spawnArguments,
                workingDirectory: configuration.workingDirectory,
                environment: configuration.environment
            )
            self.handle = handle
            machine.processStarted(generation: generation)
            emitState()
            eventTask = Task { [weak self] in
                for await event in handle.events {
                    await self?.handleProcessEvent(event, generation: generation)
                }
            }
        } catch {
            machine.failSpawn(generation: generation, message: "\(error)")
            multiplexer = nil
            emitState()
            throw error
        }
    }

    // MARK: - Input queue

    /// Enqueues user input; dispatches immediately when the session is idle.
    public func enqueue(text: String) {
        let input = ClaudeQueuedInput(text: text)
        queue.enqueue(input)
        emit(.queueChanged(queue.entries))
        persistSnapshot()
        dispatchNextIfIdle()
    }

    /// Cancels a queued (undelivered) input.
    public func removeQueuedInput(id: UUID) {
        if queue.cancel(id: id) {
            emit(.queueChanged(queue.entries))
            persistSnapshot()
        }
    }

    /// Explicitly resumes queue dispatch after a process crash paused it.
    public func resumeQueue() {
        queue.resume()
        emit(.queueChanged(queue.entries))
        persistSnapshot()
        dispatchNextIfIdle()
    }

    // MARK: - Controls

    /// Sends one outbound control and returns its response envelope.
    public func sendControl(
        _ control: ClaudeOutboundControl
    ) async throws -> ClaudeControlResponseEnvelope {
        guard let multiplexer else {
            throw ClaudeControlError.processExited(subtype: control.subtype)
        }
        return try await multiplexer.send(control)
    }

    /// Interrupts the active turn via the `interrupt` control (5s ack).
    ///
    /// The turn stays `interrupting` until the authoritative terminal `result`
    /// arrives; queued inputs are preserved.
    public func interrupt() async throws {
        machine.beginInterrupt()
        emitState()
        _ = try await sendControl(.interrupt)
    }

    /// Graceful termination: stdin close → SIGTERM after grace → SIGKILL.
    public func terminate() async {
        guard let handle, let generation = machine.processPhase.generation else { return }
        machine.beginStopping(generation: generation)
        emitState()
        handle.closeStdin()
        let grace = terminateGrace
        let escalation = Task {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            handle.terminate()
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            handle.kill()
        }
        // Wait for the event task to observe the exit.
        await eventTask?.value
        escalation.cancel()
    }

    // MARK: - Process events

    private func handleProcessEvent(_ event: ClaudeProcessEvent, generation: UInt64) async {
        guard rejectedGeneration != generation else { return }
        guard machine.processPhase.generation == generation
            || machine.processPhase.generation == nil else { return }
        switch event {
        case .stdoutLine(let data):
            await handleStdoutLine(data, generation: generation)
        case .stdoutOversized(let byteCount):
            emit(.diagnostic(.oversizedLine(byteCount: byteCount)))
        case .stderr(let chunk):
            stderrRing.append(chunk)
        case .exited(let status):
            await finishProcess(
                generation: generation,
                exit: ClaudeProcessExit(status: status, wasClean: status == 0)
            )
        }
    }

    private func handleStdoutLine(_ data: Data, generation: UInt64) async {
        switch ClaudeLineClassifier.classify(data) {
        case .json(let value):
            let line = ClaudeStreamLine.decode(value)
            if let multiplexer, await multiplexer.handleLine(line) {
                return // consumed control response
            }
            apply(line, generation: generation)
        case .launcherNotice(let text):
            emit(.diagnostic(.launcherNotice(text)))
        case .malformedJSON(let text):
            emit(.diagnostic(.malformedLine(text)))
        case .tooLarge(let byteCount):
            emit(.diagnostic(.oversizedLine(byteCount: byteCount)))
        case .empty:
            break
        }
    }

    private func apply(_ line: ClaudeStreamLine, generation: UInt64) {
        for event in accumulator.consume(line) {
            if case .diagnostic(let diagnostic) = event {
                emit(.diagnostic(diagnostic))
            }
        }
        switch line {
        case .system(let event):
            if case .initialize(let initialization) = event {
                // A resumed process must confirm the persisted identity; a
                // mismatched process is never attached to this session.
                if case .resume(let expected) = configuration.identity,
                   let observed = initialization.sessionID,
                   observed != expected {
                    abortMismatchedResume(
                        expected: expected, observed: observed, generation: generation
                    )
                    return
                }
                self.initialization = initialization
                if let sessionID = initialization.sessionID {
                    providerSessionID = sessionID
                }
                machine.initialized(generation: generation)
                emitState()
                persistSnapshot()
            }
        case .user(let envelope):
            // The replayed user line is the acknowledgment of a dispatch.
            if envelope.toolUseResult == nil,
               case .dispatching(let inputID) = machine.turnPhase {
                queue.markAcknowledged(id: inputID)
                machine.turnStarted()
                emit(.queueChanged(queue.entries))
                emitState()
                persistSnapshot()
            }
        case .streamEvent:
            if case .dispatching = machine.turnPhase {
                // Streaming evidence also proves the turn started.
                machine.turnStarted()
                emitState()
            }
        case .result(let result):
            lastResult = result
            // A terminal result is authoritative evidence the dispatched input
            // reached the CLI, even if the replayed user line was missed.
            switch machine.turnPhase {
            case .dispatching(let inputID), .active(.some(let inputID)):
                queue.markAcknowledged(id: inputID)
                emit(.queueChanged(queue.entries))
            case .idle, .active(nil), .interrupting, .uncertain:
                break
            }
            machine.turnFinished()
            emitState()
            persistSnapshot()
        case .controlRequest(let request):
            // Inert by design: permissions are always skipped, nothing answers.
            emit(.diagnostic(.inboundControlRequestIgnored(
                subtype: request.subtype,
                requestID: request.requestID
            )))
        case .assistant, .controlResponse:
            break
        case .unknown(let rawType, _):
            emit(.diagnostic(.unknownLine(rawType: rawType)))
        }
        nextSeq += 1
        let transcriptLine = ClaudeTranscriptLine(seq: nextSeq, line: line)
        transcript.append(transcriptLine)
        if transcript.count > maxTranscriptLines {
            transcript.removeFirst(transcript.count - maxTranscriptLines)
        }
        emit(.line(transcriptLine))
        if case .result = line {
            dispatchNextIfIdle()
        }
    }

    /// A resumed process reported a different provider session ID. The
    /// process is rejected: the session surfaces an identity error, keeps its
    /// persisted identity, and shuts the mismatched child down without ever
    /// attaching its output to this session's transcript.
    private func abortMismatchedResume(
        expected: String, observed: String, generation: UInt64
    ) {
        emit(.diagnostic(.resumeSessionMismatch(expected: expected, observed: observed)))
        rejectedGeneration = generation
        machine.failSpawn(
            generation: generation,
            message: "resume session mismatch: expected \(expected), observed \(observed)"
        )
        queue.pauseForProcessEnd()
        if let multiplexer {
            let mux = multiplexer
            Task { await mux.failAll() }
        }
        multiplexer = nil
        if let handle {
            handle.closeStdin()
            let grace = terminateGrace
            Task {
                try? await Task.sleep(for: grace)
                handle.terminate()
                try? await Task.sleep(for: grace)
                handle.kill()
            }
        }
        handle = nil
        emitState()
        emit(.queueChanged(queue.entries))
        persistSnapshot()
    }

    /// Exactly-once teardown for one process generation:
    /// 1. stale/duplicate generations are ignored by the state machine;
    /// 2. all pending controls fail;
    /// 3. an active/dispatched input becomes uncertain (never auto-resent);
    /// 4. the queue pauses (preserved, not transmitted);
    /// 5. one terminal change is emitted with the redacted stderr tail.
    private func finishProcess(generation: UInt64, exit: ClaudeProcessExit) async {
        guard machine.finishProcess(generation: generation, exit: exit) else { return }
        if case .uncertain(let inputID) = machine.turnPhase {
            queue.markUncertain(id: inputID)
        }
        queue.pauseForProcessEnd()
        if let multiplexer {
            await multiplexer.failAll()
        }
        multiplexer = nil
        handle = nil
        let tail = stderrRing.isEmpty
            ? nil
            : ClaudeSecretRedactor.redact(stderrRing.text)
        if !exit.wasClean {
            lastRedactedStderrTail = tail
        }
        emitState()
        emit(.queueChanged(queue.entries))
        emit(.processEnded(exit: exit, stderrTail: exit.wasClean ? nil : tail))
        persistSnapshot()
    }

    // MARK: - Dispatch

    private func dispatchNextIfIdle() {
        guard case .idle = machine.turnPhase,
              case .running = machine.processPhase,
              let next = queue.nextForDispatch() else { return }
        queue.markDispatching(id: next.id)
        machine.beginDispatch(inputID: next.id)
        emit(.queueChanged(queue.entries))
        emitState()

        let payload = ClaudeJSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(next.text)])
                ]),
            ]),
        ])
        Task {
            // Invariant: the dispatching state is persisted BEFORE the stdin
            // write, so a crash between write and acknowledgment restores the
            // entry as uncertain rather than losing it.
            await self.persistSnapshotAndWait()
            do {
                let data = try JSONEncoder().encode(payload)
                try self.writeLine(data)
            } catch {
                self.failDispatch(inputID: next.id, message: "\(error)")
            }
        }
    }

    private func failDispatch(inputID: UUID, message: String) {
        queue.markUncertain(id: inputID)
        // A failed stdin write means the transport is broken or indeterminate:
        // pause the queue so no further prompt fans into it until the user
        // explicitly resumes.
        queue.pauseForProcessEnd()
        machine.turnFinished()
        emit(.diagnostic(.malformedLine("stdin write failed: \(message)")))
        emit(.queueChanged(queue.entries))
        emitState()
        persistSnapshot()
    }

    private func writeLine(_ data: Data) throws {
        guard let handle else {
            throw ClaudeSpawnError(message: "process is not running")
        }
        var framed = data
        framed.append(UInt8(ascii: "\n"))
        try handle.writeStdin(framed)
    }

    // MARK: - Persistence

    /// The current persistence-relevant state.
    private func persistenceSnapshot() -> ClaudeSessionPersistenceSnapshot {
        ClaudeSessionPersistenceSnapshot(
            sessionID: configuration.id,
            providerSessionID: providerSessionID,
            launcher: configuration.launcher,
            workingDirectory: configuration.workingDirectory,
            queueEntries: queue.entries,
            lastResult: lastResult,
            redactedStderrTail: lastRedactedStderrTail
        )
    }

    /// Fire-and-forget persistence for non-critical moments.
    private func persistSnapshot() {
        guard let persistence else { return }
        let snapshot = persistenceSnapshot()
        Task { await persistence.persist(snapshot) }
    }

    /// Awaited persistence for the persist-before-write invariant.
    private func persistSnapshotAndWait() async {
        guard let persistence else { return }
        await persistence.persist(persistenceSnapshot())
    }

    // MARK: - Emission

    private func emit(_ change: ClaudeSessionChange) {
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }

    private func emitState() {
        emit(.stateChanged(process: machine.processPhase, turn: machine.turnPhase))
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// Finishes all subscriber streams (registry removal).
    func finishSubscribers() {
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }
}
