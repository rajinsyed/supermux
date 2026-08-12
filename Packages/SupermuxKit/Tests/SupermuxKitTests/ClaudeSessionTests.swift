import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// Session actor behavior against a scripted fake process runner.
struct ClaudeSessionTests {
    // MARK: - Fake process

    /// A controllable fake child process.
    final class FakeProcess: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spawnedPath: String?
        private(set) var spawnedArguments: [String] = []
        private(set) var spawnedWorkingDirectory: String?
        private(set) var stdinWrites: [Data] = []
        private var stdinWriteAttempts = 0
        private(set) var stdinClosed = false
        private(set) var terminated = false
        private(set) var killed = false
        var exitsOnStdinClose = true
        /// When true, every stdin write throws.
        var failStdinWrites = false
        private var continuation: AsyncStream<ClaudeProcessEvent>.Continuation?

        func handle(
            path: String,
            arguments: [String],
            workingDirectory: String?
        ) -> ClaudeProcessHandle {
            lock.lock()
            spawnedPath = path
            spawnedArguments = arguments
            spawnedWorkingDirectory = workingDirectory
            lock.unlock()
            let (events, continuation) = AsyncStream<ClaudeProcessEvent>.makeStream()
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            return ClaudeProcessHandle(
                events: events,
                writeStdin: { [weak self] data in
                    guard let self else { return }
                    self.lock.lock()
                    self.stdinWriteAttempts += 1
                    let fails = self.failStdinWrites
                    if !fails { self.stdinWrites.append(data) }
                    self.lock.unlock()
                    if fails { throw ClaudeSpawnError(message: "EPIPE") }
                },
                closeStdin: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.stdinClosed = true
                    let autoExit = self.exitsOnStdinClose
                    self.lock.unlock()
                    // A well-behaved child exits on stdin EOF.
                    if autoExit { self.exit(status: 0) }
                },
                terminate: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.terminated = true
                    self.lock.unlock()
                },
                kill: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.killed = true
                    self.lock.unlock()
                }
            )
        }

        func emitLine(_ json: String) {
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            continuation?.yield(.stdoutLine(Data(json.utf8)))
        }

        func exit(status: Int32) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.yield(.exited(status: status))
            continuation?.finish()
        }

        func writtenLines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return stdinWrites.map { String(decoding: $0, as: UTF8.self) }
        }

        func writeAttempts() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return stdinWriteAttempts
        }
    }

    /// Records every persisted snapshot in order.
    final class PersistenceSink: ClaudeSessionPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ClaudeSessionPersistenceSnapshot] = []

        func persist(_ snapshot: ClaudeSessionPersistenceSnapshot) async {
            lock.withLock { items.append(snapshot) }
        }

        func snapshots() -> [ClaudeSessionPersistenceSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    struct FakeRunner: ClaudeProcessRunning {
        let process: FakeProcess
        let spawnError: ClaudeSpawnError?

        init(process: FakeProcess, spawnError: ClaudeSpawnError? = nil) {
            self.process = process
            self.spawnError = spawnError
        }

        func run(
            executablePath: String,
            arguments: [String],
            workingDirectory: String?,
            environment: [String: String]?
        ) throws -> ClaudeProcessHandle {
            if let spawnError { throw spawnError }
            return process.handle(
                path: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }
    }

    // MARK: - Helpers

    private func makeSession(
        launcherKind: ClaudeLauncher.Kind = .claude,
        identity: ClaudeSpawnArguments.SessionIdentity = .new(sessionID: "prov-uuid"),
        model: String? = nil,
        spawnError: ClaudeSpawnError? = nil,
        coldControlTimeout: Duration = .seconds(2)
    ) -> (ClaudeSession, FakeProcess) {
        let process = FakeProcess()
        let launcher = ClaudeLauncher(
            kind: launcherKind,
            executablePath: launcherKind == .ccx ? "/fake/ccx" : "/fake/claude",
            displayName: "fake"
        )
        let configuration = ClaudeSessionConfiguration(
            launcher: launcher,
            workingDirectory: "/tmp",
            identity: identity,
            model: model
        )
        let session = ClaudeSession(
            configuration: configuration,
            runner: FakeRunner(process: process, spawnError: spawnError),
            controlTimeouts: .init(
                ordinary: .seconds(2), cold: coldControlTimeout, interrupt: .seconds(2)
            )
        )
        return (session, process)
    }

    private func initLine(sessionID: String = "prov-uuid") -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(sessionID)","cwd":"/tmp","tools":["Bash"],"model":"haiku","permissionMode":"bypassPermissions","capabilities":[]}"#
    }

    private func resultLine(sessionID: String = "prov-uuid") -> String {
        #"{"type":"result","subtype":"success","is_error":false,"session_id":"\#(sessionID)","terminal_reason":"completed","num_turns":1}"#
    }

    private func answerInitialize(
        _ process: FakeProcess,
        payload: String = #"{"commands":[{"name":"help","description":"Help","argumentHint":""}],"agents":[],"output_style":"default","available_output_styles":["default"],"models":[{"value":"haiku","resolvedModel":"claude-haiku-4-5","displayName":"Haiku","description":"Fast","supportsEffort":true,"supportedEffortLevels":["low","high"],"supportsAdaptiveThinking":true,"supportsFastMode":false,"supportsAutoMode":false}],"account":{"tokenSource":"oauth","apiProvider":"firstParty"},"pid":42,"current_permission_mode":"bypassPermissions","fast_mode_state":"off"}"#
    ) async throws {
        #expect(await waitUntil {
            process.writtenLines().contains { $0.contains(#""subtype":"initialize""#) }
        })
        let line = try #require(process.writtenLines().first {
            $0.contains(#""subtype":"initialize""#)
        })
        let object = try JSONDecoder().decode(ClaudeJSONValue.self, from: Data(line.utf8))
        let requestID = try #require(object["request_id"]?.stringValue)
        process.emitLine(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":\#(payload)}}"#
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - Spawn arguments

    @Test func spawnArgumentsForPlainClaudeIncludeSkipPermissions() async throws {
        let (session, process) = makeSession(model: "claude-fable-5")
        try await session.start()
        let args = process.spawnedArguments
        #expect(process.spawnedPath == "/fake/claude")
        #expect(args.contains("--dangerously-skip-permissions"))
        #expect(args.contains("-p"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--replay-user-messages"))
        #expect(args.contains("--verbose"))
        #expect(!args.contains("--permission-prompt-tool"))
        let sessionIndex = try #require(args.firstIndex(of: "--session-id"))
        #expect(args[args.index(after: sessionIndex)] == "prov-uuid")
        let modelIndex = try #require(args.firstIndex(of: "--model"))
        #expect(args[args.index(after: modelIndex)] == "claude-fable-5")
        await session.terminate()
    }

    @Test func spawnArgumentsForCcxOmitSkipPermissions() async throws {
        let (session, process) = makeSession(launcherKind: .ccx)
        try await session.start()
        #expect(!process.spawnedArguments.contains("--dangerously-skip-permissions"))
        await session.terminate()
    }

    @Test func resumeSpawnUsesResumeFlag() async throws {
        let (session, process) = makeSession(identity: .resume(sessionID: "old-session"))
        try await session.start()
        let args = process.spawnedArguments
        #expect(args.contains("--resume"))
        #expect(args.contains("old-session"))
        #expect(!args.contains("--session-id"))
        await session.terminate()
    }

    @Test func spawnFailureSurfacesAsFailedPhase() async {
        let (session, _) = makeSession(spawnError: ClaudeSpawnError(message: "ENOENT"))
        await #expect(throws: ClaudeSpawnError.self) {
            try await session.start()
        }
        let phase = await session.processPhase
        guard case .failed(let message) = phase else {
            Issue.record("expected failed phase, got \(phase)")
            return
        }
        #expect(message.contains("ENOENT"))
    }

    // MARK: - Turn lifecycle

    @Test func initializeControlStartsAndDispatchesQueuedInputWithoutSystemInit() async throws {
        let (session, process) = makeSession()
        await session.enqueue(text: "hello")
        try await session.start()

        try await answerInitialize(process)

        #expect(await waitUntil {
            if case .running = await session.processPhase { return true }
            return false
        })
        #expect(await waitUntil {
            process.writtenLines().contains { line in
                line.contains(#""role":"user""#) && line.contains("hello")
            }
        })
        let initialization = try #require(await session.systemInitialization)
        #expect(initialization.slashCommands == ["help"])
        #expect(initialization.model == "haiku")
        await session.terminate()
    }

    @Test func initializeTimeoutFallsBackToFirstDispatchThenSystemInitCompletesHandshake() async throws {
        let (session, process) = makeSession(coldControlTimeout: .milliseconds(25))
        await session.enqueue(text: "fallback")
        try await session.start()

        #expect(await waitUntil {
            process.writtenLines().contains { line in
                line.contains(#""role":"user""#) && line.contains("fallback")
            }
        })
        guard case .handshaking = await session.processPhase else {
            Issue.record("expected fallback dispatch while handshaking")
            return
        }

        process.emitLine(initLine())
        #expect(await waitUntil {
            if case .running = await session.processPhase { return true }
            return false
        })
        #expect(await session.claudeSessionID == "prov-uuid")
        await session.terminate()
    }

    @Test func initThenTurnThenResult() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.claudeSessionID == "prov-uuid" })
        guard case .running = await session.processPhase else {
            Issue.record("expected running after init")
            return
        }

        await session.enqueue(text: "hello")
        // The prompt line is written to stdin.
        #expect(await waitUntil { !process.writtenLines().isEmpty })
        let written = process.writtenLines()[0]
        #expect(written.contains(#""role":"user""#))
        #expect(written.contains("hello"))
        #expect(written.hasSuffix("\n"))

        // The replayed user line acknowledges the dispatch.
        process.emitLine(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"session_id":"prov-uuid","isReplay":true}"#)
        #expect(await waitUntil {
            await session.queuedInputs.allSatisfy { $0.state == .acknowledged }
        })

        process.emitLine(resultLine())
        #expect(await waitUntil {
            if case .idle = await session.turnPhase { return true }
            return false
        })
        let result = try #require(await session.latestResult)
        #expect(result.subtype == "success")
        await session.terminate()
    }

    @Test func queuedInputWaitsForResultBeforeDispatch() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        await session.enqueue(text: "first")
        #expect(await waitUntil { process.writtenLines().count == 1 })
        await session.enqueue(text: "second")
        // No dispatch of the second input while the first turn is open.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(process.writtenLines().count == 1)

        // First turn ends → second dispatches.
        process.emitLine(resultLine())
        #expect(await waitUntil { process.writtenLines().count == 2 })
        #expect(process.writtenLines()[1].contains("second"))
        await session.terminate()
    }

    @Test func crashMidTurnMarksUncertainAndPausesQueue() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        await session.enqueue(text: "doomed")
        #expect(await waitUntil { !process.writtenLines().isEmpty })
        await session.enqueue(text: "survivor")

        process.exit(status: 1)
        #expect(await waitUntil {
            if case .exited = await session.processPhase { return true }
            return false
        })

        let inputs = await session.queuedInputs
        #expect(inputs.first { $0.text == "doomed" }?.state == .uncertain)
        #expect(inputs.first { $0.text == "survivor" }?.state == .queued)
        // Queue is paused: nothing further was transmitted.
        #expect(process.writtenLines().count == 1)
    }

    @Test func interruptSendsControlAndAwaitsResult() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        await session.enqueue(text: "long task")
        #expect(await waitUntil { !process.writtenLines().isEmpty })

        let interruptTask = Task { try await session.interrupt() }
        #expect(await waitUntil {
            process.writtenLines().contains { $0.contains(#""subtype":"interrupt""#) }
        })
        // Extract the request ID and acknowledge.
        let line = try #require(process.writtenLines().first {
            $0.contains(#""subtype":"interrupt""#)
        })
        let object = try JSONDecoder().decode(ClaudeJSONValue.self, from: Data(line.utf8))
        let requestID = try #require(object["request_id"]?.stringValue)
        process.emitLine(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":{"still_queued":[]}}}"#)
        try await interruptTask.value

        // The ack alone does not finish the turn.
        guard case .interrupting = await session.turnPhase else {
            Issue.record("expected interrupting until result")
            return
        }
        // The observed interrupt terminal result (error_during_execution).
        process.emitLine(#"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","stop_reason":null,"session_id":"prov-uuid"}"#)
        #expect(await waitUntil {
            if case .idle = await session.turnPhase { return true }
            return false
        })
        await session.terminate()
    }

    @Test func inboundControlRequestIsIgnoredWithDiagnostic() async throws {
        let (session, process) = makeSession()
        let changes = await session.changes()
        try await session.start()
        process.emitLine(initLine())
        process.emitLine(#"{"type":"control_request","request_id":"prov-1","request":{"subtype":"can_use_tool","tool_name":"Write"}}"#)

        var sawDiagnostic = false
        for await change in changes {
            if case .diagnostic(.inboundControlRequestIgnored(let subtype, let id)) = change {
                #expect(subtype == "can_use_tool")
                #expect(id == "prov-1")
                sawDiagnostic = true
                break
            }
        }
        #expect(sawDiagnostic)
        // Nothing was written back: no answer path exists.
        #expect(process.writtenLines().isEmpty)
        await session.terminate()
    }

    @Test func launcherBannerBecomesDiagnosticNotFailure() async throws {
        let (session, process) = makeSession(launcherKind: .ccx)
        let changes = await session.changes()
        try await session.start()
        process.emitLine("\u{1B}[2mccx → model via proxy\u{1B}[0m")
        process.emitLine(initLine())

        var sawNotice = false
        for await change in changes {
            if case .diagnostic(.launcherNotice(let text)) = change {
                #expect(text.contains("ccx"))
                sawNotice = true
                break
            }
        }
        #expect(sawNotice)
        #expect(await waitUntil { await session.systemInitialization != nil })
        await session.terminate()
    }

    // MARK: - Teardown

    @Test func teardownIsExactlyOnce() async throws {
        let (session, process) = makeSession()
        let changes = await session.changes()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        process.exit(status: 0)
        #expect(await waitUntil {
            if case .exited = await session.processPhase { return true }
            return false
        })

        // Drain buffered changes; the stream stays open, so poll with a bound.
        let drainTask = Task { () -> Int in
            var endedCount = 0
            for await change in changes {
                if case .processEnded = change { endedCount += 1 }
            }
            return endedCount
        }
        try? await Task.sleep(for: .milliseconds(100))
        drainTask.cancel()
        #expect(await drainTask.value == 1)

        // Controls after exit fail fast.
        await #expect(throws: ClaudeControlError.processExited(subtype: "list_models")) {
            _ = try await session.sendControl(.listModels)
        }
    }

    // MARK: - Resume identity

    @Test func resumeMismatchRejectsTheProcessAndKeepsIdentity() async throws {
        let (session, process) = makeSession(identity: .resume(sessionID: "expected-session"))
        let changes = await session.changes()
        try await session.start()
        process.emitLine(initLine(sessionID: "different-session"))

        var sawMismatch = false
        for await change in changes {
            if case .diagnostic(.resumeSessionMismatch(let expected, let observed)) = change {
                #expect(expected == "expected-session")
                #expect(observed == "different-session")
                sawMismatch = true
                break
            }
        }
        #expect(sawMismatch)
        // The mismatched identity is never adopted and the process never runs.
        #expect(await session.claudeSessionID == nil)
        let phase = await session.processPhase
        guard case .failed = phase else {
            Issue.record("expected failed phase, got \(phase)")
            return
        }
        // Teardown began with stdin close.
        #expect(await waitUntil { process.stdinClosed })
    }

    // MARK: - Dispatch failure

    @Test func stdinWriteFailurePausesTheQueue() async throws {
        let (session, process) = makeSession()
        process.failStdinWrites = true
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        await session.enqueue(text: "first")
        #expect(await waitUntil {
            await session.queuedInputs.first?.state == .uncertain
        })

        // A second enqueue must NOT produce another stdin write attempt.
        await session.enqueue(text: "second")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(process.writeAttempts() == 1)
        #expect(await session.queuedInputs.first { $0.text == "second" }?.state == .queued)

        // Explicit resume re-enables dispatch.
        process.failStdinWrites = false
        await session.resumeQueue()
        #expect(await waitUntil { process.writeAttempts() == 2 })
    }

    // MARK: - Persistence

    @Test func sessionPersistsIdentityAndQueueStates() async throws {
        let sink = PersistenceSink()
        let process = FakeProcess()
        let configuration = ClaudeSessionConfiguration(
            launcher: ClaudeLauncher(
                kind: .claude, executablePath: "/fake/claude", displayName: "fake"
            ),
            workingDirectory: "/tmp",
            identity: .new(sessionID: "prov-uuid")
        )
        let session = ClaudeSession(
            configuration: configuration,
            runner: FakeRunner(process: process),
            persistence: sink
        )
        try await session.start()
        process.emitLine(initLine())
        // The provider session ID is persisted at init.
        #expect(await waitUntil {
            sink.snapshots().contains { $0.providerSessionID == "prov-uuid" }
        })

        await session.enqueue(text: "hello")
        #expect(await waitUntil { !process.writtenLines().isEmpty })
        // Persist-before-write: some persisted snapshot recorded the entry as
        // dispatching before the stdin write happened.
        #expect(sink.snapshots().contains { snapshot in
            snapshot.queueEntries.contains { $0.state == .dispatching }
        })

        // A crash persists the uncertain state.
        process.exit(status: 1)
        #expect(await waitUntil {
            sink.snapshots().last?.queueEntries.first?.state == .uncertain
        })
        #expect(sink.snapshots().last?.redactedStderrTail != nil
            || process.writtenLines().count == 1)
    }

    // MARK: - Transcript retention

    @Test func transcriptLinesAreRetainedWithMonotonicSeq() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })
        process.emitLine(resultLine())
        #expect(await waitUntil { await session.latestSeq == 2 })

        let lines = await session.transcriptLines
        #expect(lines.map(\.seq) == [1, 2])
        let tail = await session.transcriptTail(afterSeq: 1)
        #expect(tail.count == 1)
        guard case .result = tail.first?.line else {
            Issue.record("expected result line in tail")
            return
        }
        await session.terminate()
    }

    // MARK: - Queue restoration

    @Test func restoreQueueSeedsPersistedEntriesAndDispatches() async throws {
        let (session, process) = makeSession()
        try await session.start()
        let entries = [
            ClaudeQueuedInput(text: "unsent", state: .queued),
            ClaudeQueuedInput(text: "in flight when app died", state: .dispatching),
            ClaudeQueuedInput(text: "already delivered", state: .acknowledged),
            ClaudeQueuedInput(text: "lost", state: .uncertain),
        ]
        await session.restoreQueue(entries: entries)

        let restored = await session.queuedInputs
        #expect(restored.count == 3)
        #expect(restored.first { $0.text == "unsent" }?.state == .queued)
        // dispatching at restore time means the write outcome is unknown.
        #expect(
            restored.first { $0.text == "in flight when app died" }?.state == .uncertain
        )
        #expect(restored.first { $0.text == "lost" }?.state == .uncertain)
        // Terminal entries are dropped, and nothing auto-resends.
        #expect(!restored.contains { $0.text == "already delivered" })

        // Once the process initializes, only the queued entry dispatches.
        process.emitLine(initLine())
        #expect(await waitUntil { process.writtenLines().count == 1 })
        #expect(process.writtenLines()[0].contains("unsent"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(process.writtenLines().count == 1)
        await session.terminate()
    }

    @Test func restoreQueueIsNoOpWhenSessionAlreadyHasEntries() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })
        await session.enqueue(text: "live")
        await session.restoreQueue(entries: [ClaudeQueuedInput(text: "stale")])
        let entries = await session.queuedInputs
        #expect(entries.map(\.text) == ["live"])
        await session.terminate()
    }

    // MARK: - App shutdown

    @Test func terminateForAppShutdownSignalsSynchronously() async throws {
        let (session, process) = makeSession()
        process.exitsOnStdinClose = false
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        // Synchronous: no await between the call and the assertions.
        session.terminateForAppShutdown()
        #expect(process.stdinClosed)
        #expect(process.terminated)
        // Idempotent: a second call cannot double-signal.
        session.terminateForAppShutdown()
        process.exit(status: 0)
    }

    @Test func terminateEscalatesStdinCloseFirst() async throws {
        let (session, process) = makeSession()
        try await session.start()
        process.emitLine(initLine())
        #expect(await waitUntil { await session.systemInitialization != nil })

        let terminateTask = Task { await session.terminate() }
        #expect(await waitUntil { process.stdinClosed })
        // The child obeys EOF and exits before the SIGTERM deadline.
        process.exit(status: 0)
        await terminateTask.value
        #expect(!process.killed)
    }
}
