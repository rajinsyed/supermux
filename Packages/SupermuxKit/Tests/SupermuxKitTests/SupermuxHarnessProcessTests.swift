import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessOutputLineBufferTests {
    @Test func splitsCompleteLinesAcrossArbitraryChunksAndFlushesTrailingText() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        #expect(buffer.append(Data("one\ntw".utf8)) == [.line("one\n")])
        #expect(buffer.bufferedByteCount == 2)
        #expect(buffer.append(Data("o\nthree".utf8)) == [.line("two\n")])
        #expect(buffer.flush() == [.line("three")])
        #expect(buffer.flush().isEmpty)
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test func preservesCRLFAndEmptyLines() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        #expect(buffer.append(Data("one\r\n\ntwo\n".utf8)) == [
            .line("one\r\n"),
            .line("\n"),
            .line("two\n"),
        ])
        #expect(buffer.flush().isEmpty)
    }

    @Test func oversizedPhysicalLineIsDiscardedUntilItsRealDelimiterThenRecovers() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        let maximum = SupermuxHarnessOutputLineBuffer.maximumBufferedBytes
        let valid = #"{"type":"keep_alive","recovered":true}"# + "\n"

        #expect(buffer.append(Data(repeating: 0x61, count: maximum)).isEmpty)
        #expect(buffer.bufferedByteCount <= maximum)
        #expect(buffer.append(Data(repeating: 0x62, count: 7)).isEmpty)
        #expect(buffer.bufferedByteCount <= maximum)
        #expect(buffer.append(Data(("\n" + valid).utf8)) == [
            .overflow(discardedByteCount: maximum + 7),
            .line(valid),
        ])
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test func endOfFileReportsOneOverflowWithoutInventingAPartialLine() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        let maximum = SupermuxHarnessOutputLineBuffer.maximumBufferedBytes

        #expect(buffer.append(Data(repeating: 0x62, count: maximum + 3)).isEmpty)
        #expect(buffer.bufferedByteCount <= maximum)
        #expect(buffer.flush() == [.overflow(discardedByteCount: maximum + 3)])
        #expect(buffer.flush().isEmpty)
    }

    @Test func preservesMultibyteUTF8SplitAcrossChunks() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        let bytes = Array("😀".utf8)
        #expect(buffer.append(Data(bytes.prefix(2))).isEmpty)
        #expect(buffer.append(Data(bytes.dropFirst(2)) + Data([0x0A])) == [.line("😀\n")])
    }

    @Test func invalidUTF8UsesReplacementDecodingInsteadOfDroppingBytes() {
        var buffer = SupermuxHarnessOutputLineBuffer()
        #expect(buffer.append(Data([0xFF, 0x0A])) == [.line("�\n")])
    }
}

@Suite(.serialized)
struct SupermuxHarnessInputWriterTests {
    @Test func serializesWritesAndCloseProducesEOF() async throws {
        let pipe = Pipe()
        let writer = SupermuxHarnessInputWriter(fileHandle: pipe.fileHandleForWriting)
        try await writer.write(Data("first".utf8))
        try await writer.write(Data("second".utf8))
        await writer.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == "firstsecond")
    }

    @Test func acceptsPolicyValidAttachmentFramesLargerThanOneMiB() async throws {
        let rawImage = Data(repeating: 0, count: SupermuxHarnessAttachmentPolicy.maximumImageBytes)
        let image = SupermuxHarnessImage(
            mediaType: "image/png",
            dataBase64: rawImage.base64EncodedString()
        )
        let frame = try SupermuxHarnessProtocolEncoder().userMessage(
            text: "",
            images: [image, image],
            uuid: UUID().uuidString
        )
        #expect(frame.lineData.count > 1024 * 1024)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-input-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: fileURL)
        let writer = SupermuxHarnessInputWriter(fileHandle: handle)

        try await writer.write(frame.lineData)
        await writer.close()

        let written = try Data(contentsOf: fileURL)
        #expect(written == frame.lineData)
    }

    @Test func rejectsSingleWriteLargerThanQueueCapacity() async {
        let pipe = Pipe()
        let writer = SupermuxHarnessInputWriter(fileHandle: pipe.fileHandleForWriting)
        let data = Data(repeating: 0, count: 4 * 1024 * 1024 + 1)
        do {
            try await writer.write(data)
            Issue.record("Expected queue-cap error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .inputQueueFull)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        await writer.close()
    }

    @Test func closeFailsSubsequentNonemptyWrites() async {
        let pipe = Pipe()
        let writer = SupermuxHarnessInputWriter(fileHandle: pipe.fileHandleForWriting)
        await writer.close()
        do {
            try await writer.write(Data("late".utf8))
            Issue.record("Expected closed-input error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .inputClosed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func writeFailureClosesWriterForLaterWrites() async throws {
        let pipe = Pipe()
        let writer = SupermuxHarnessInputWriter(fileHandle: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        do {
            try await writer.write(Data("first".utf8))
            Issue.record("Expected file-handle write failure")
        } catch {}
        do {
            try await writer.write(Data("second".utf8))
            Issue.record("Expected closed-input error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .inputClosed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite(.serialized) @MainActor
struct SupermuxHarnessProcessSessionTests {
    @MainActor
    private final class Recorder {
        var protocolLines: [SupermuxHarnessDecodedLine] = []
        var stderrLines: [String] = []
        var outputDiagnostics: [SupermuxHarnessOutputDiagnostic] = []
        var lifecycleEvents: [SupermuxHarnessProcessLifecycleEvent] = []
        var timeline: [String] = []
        private var protocolQueue: [SupermuxHarnessDecodedLine] = []
        private var protocolWaiters: [CheckedContinuation<SupermuxHarnessDecodedLine, Never>] = []
        private var exitQueue: [SupermuxHarnessProcessLifecycleEvent] = []
        private var exitWaiters: [CheckedContinuation<SupermuxHarnessProcessLifecycleEvent, Never>] = []

        func receiveProtocol(_ line: SupermuxHarnessDecodedLine) {
            protocolLines.append(line)
            timeline.append("stdout")
            if protocolWaiters.isEmpty {
                protocolQueue.append(line)
            } else {
                protocolWaiters.removeFirst().resume(returning: line)
            }
        }

        func receiveStderr(_ line: String) {
            stderrLines.append(line)
            timeline.append("stderr")
        }

        func receiveOutputDiagnostic(_ diagnostic: SupermuxHarnessOutputDiagnostic) {
            outputDiagnostics.append(diagnostic)
            timeline.append("overflow")
        }

        func receiveLifecycle(_ event: SupermuxHarnessProcessLifecycleEvent) {
            lifecycleEvents.append(event)
            switch event {
            case .started:
                timeline.append("started")
            case .exited:
                timeline.append("exited")
                if exitWaiters.isEmpty {
                    exitQueue.append(event)
                } else {
                    exitWaiters.removeFirst().resume(returning: event)
                }
            }
        }

        func nextProtocolLine() async -> SupermuxHarnessDecodedLine {
            if !protocolQueue.isEmpty { return protocolQueue.removeFirst() }
            return await withCheckedContinuation { continuation in
                protocolWaiters.append(continuation)
            }
        }

        func nextExit() async -> SupermuxHarnessProcessLifecycleEvent {
            if !exitQueue.isEmpty { return exitQueue.removeFirst() }
            return await withCheckedContinuation { continuation in
                exitWaiters.append(continuation)
            }
        }
    }

    @MainActor
    private final class ProtocolSinkGate {
        private(set) var receivedCount = 0
        private var firstWasReceived = false
        private var firstReceivedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func receive(_ line: SupermuxHarnessDecodedLine) async {
            _ = line
            receivedCount += 1
            guard receivedCount == 1 else { return }
            firstWasReceived = true
            let waiters = firstReceivedWaiters
            firstReceivedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilFirstReceived() async {
            if firstWasReceived { return }
            await withCheckedContinuation { continuation in
                firstReceivedWaiters.append(continuation)
            }
        }

        func releaseFirst() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    @Test func oneProcessHandlesMultipleTurnsAndExitsOnlyAfterBothStreamsDrain() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let script = #"""
        IFS= read -r first || exit 90
        printf '{"type":"keep_alive","turn":1}\n'
        printf 'err-one\n' >&2
        IFS= read -r second || exit 91
        printf '{"type":"keep_alive","turn":2}\n'
        printf 'err-two' >&2
        exit 7
        """#
        let started = try session.start(plan: shellPlan(script))
        #expect(session.isRunning)
        #expect(session.activeRunID == started.runID)
        #expect(started.processID > 0)

        let encoder = SupermuxHarnessProtocolEncoder()
        try await session.send(encoder.userMessage(text: "first", uuid: "one"))
        let first = await recorder.nextProtocolLine()
        #expect(first.object.integer(forKey: "turn") == 1)
        try await session.send(encoder.userMessage(text: "second", uuid: "two"))
        let second = await recorder.nextProtocolLine()
        #expect(second.object.integer(forKey: "turn") == 2)
        let exit = await recorder.nextExit()

        #expect(exit == .exited(runID: started.runID, status: 7))
        #expect(recorder.lifecycleEvents.first == .started(runID: started.runID, processID: started.processID))
        #expect(recorder.stderrLines == ["err-one\n", "err-two"])
        #expect(recorder.timeline.first == "started")
        #expect(recorder.timeline.last == "exited")
        #expect(!session.isRunning)
        #expect(session.activeRunID == nil)
    }

    @Test func protocolReadingWaitsForTheAsyncSinkBeforeDeliveringTheNextLine() async throws {
        let recorder = Recorder()
        let gate = ProtocolSinkGate()
        let session = SupermuxHarnessProcessSession(
            protocolLineSink: { line in await gate.receive(line) },
            stderrSink: { recorder.receiveStderr($0) },
            lifecycleSink: { recorder.receiveLifecycle($0) }
        )
        let script = #"""
        printf '{"type":"keep_alive","value":1}\n'
        printf '{"type":"keep_alive","value":2}\n'
        """#
        _ = try session.start(plan: shellPlan(script))
        defer { session.close() }

        await gate.waitUntilFirstReceived()
        #expect(gate.receivedCount == 1)
        #expect(session.isRunning)

        gate.releaseFirst()
        _ = await recorder.nextExit()
        #expect(gate.receivedCount == 2)
        #expect(!session.isRunning)
    }

    @Test func stdoutForwardsUnknownValidJSONDropsMalformedLinesAndFlushesTrailingJSON() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let script = #"""
        printf 'not-json\n'
        printf '{"type":"future_frame","value":1}\n'
        printf '{"type":"keep_alive","value":2}'
        printf 'stderr-tail' >&2
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextExit()

        #expect(recorder.protocolLines.count == 2)
        #expect(recorder.protocolLines[0].frame == nil)
        #expect(recorder.protocolLines[0].object.integer(forKey: "value") == 1)
        #expect(recorder.protocolLines[0].rawLine.hasSuffix("\n"))
        guard case .keepAlive = recorder.protocolLines[1].frame else {
            Issue.record("Expected trailing keep-alive")
            return
        }
        #expect(recorder.protocolLines[1].object.integer(forKey: "value") == 2)
        #expect(!recorder.protocolLines[1].rawLine.hasSuffix("\n"))
        #expect(recorder.stderrLines == ["stderr-tail"])
        #expect(recorder.lifecycleEvents.last == .exited(runID: started.runID, status: 0))
    }

    @Test func oversizedStdoutNeverReachesDecoderAndNextPhysicalLineStillDecodes() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let maximum = SupermuxHarnessOutputLineBuffer.maximumBufferedBytes
        let script = #"""
        dd if=/dev/zero bs=1048576 count=1 2>/dev/null
        printf '123456789\n'
        printf '{"type":"keep_alive","recovered":true}\n'
        """#

        let started = try session.start(plan: shellPlan(script))
        let recovered = await recorder.nextProtocolLine()
        let exit = await recorder.nextExit()

        #expect(recovered.object.bool(forKey: "recovered") == true)
        #expect(recorder.protocolLines.count == 1)
        #expect(recorder.outputDiagnostics == [
            SupermuxHarnessOutputDiagnostic(stream: .stdout, discardedByteCount: maximum + 9),
        ])
        #expect(recorder.timeline.last == "exited")
        #expect(exit == .exited(runID: started.runID, status: 0))
    }

    @Test func closeInputGracefullyEndsProcessAndRetainsSessionUntilExit() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let script = #"""
        while IFS= read -r line; do :; done
        printf '{"type":"result","subtype":"success","is_error":false,"result":"eof"}\n'
        """#
        let started = try session.start(plan: shellPlan(script))
        try await session.send(
            SupermuxHarnessProtocolEncoder().userMessage(text: "turn", uuid: "one")
        )
        try await session.closeInput()
        #expect(session.isRunning)
        let resultLine = await recorder.nextProtocolLine()
        guard case .result(let result) = resultLine.frame else {
            Issue.record("Expected result after stdin EOF")
            return
        }
        #expect(result.result == "eof")
        #expect(await recorder.nextExit() == .exited(runID: started.runID, status: 0))
        #expect(!session.isRunning)
    }

    @Test func startRejectsSecondProcessAndAllowsReuseAfterFirstExits() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let waitingScript = #"""
        printf '{"type":"keep_alive","ready":true}\n'
        while IFS= read -r line; do :; done
        """#
        _ = try session.start(plan: shellPlan(waitingScript))
        _ = await recorder.nextProtocolLine()
        do {
            _ = try session.start(plan: shellPlan("exit 0"))
            Issue.record("Expected already-running error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .alreadyRunning)
        }
        try await session.closeInput()
        _ = await recorder.nextExit()

        let second = try session.start(plan: shellPlan("exit 4"))
        #expect(await recorder.nextExit() == .exited(runID: second.runID, status: 4))
    }

    @Test func runBoundWritesCannotReachAReplacementProcess() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let first = try session.start(plan: shellPlan("exit 0"))
        _ = await recorder.nextExit()

        let replacementScript = #"""
        printf '{"type":"keep_alive","ready":true}\n'
        IFS= read -r line || exit 90
        printf '{"type":"keep_alive","received":true}\n'
        """#
        let replacement = try session.start(plan: shellPlan(replacementScript))
        _ = await recorder.nextProtocolLine()
        let frame = try SupermuxHarnessProtocolEncoder().userMessage(text: "next", uuid: "next")

        do {
            try await session.send(frame, forRunID: first.runID)
            Issue.record("Expected stale run write rejection")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .notRunning)
        }
        try await session.send(frame, forRunID: replacement.runID)
        let received = await recorder.nextProtocolLine()
        #expect(received.object.bool(forKey: "received") == true)
        #expect(await recorder.nextExit() == .exited(runID: replacement.runID, status: 0))
    }

    @Test func failedLaunchCleansStateAndDoesNotEmitStarted() throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder)
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/definitely/missing/supermux-harness"),
            arguments: [],
            environment: ProcessInfo.processInfo.environment,
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )
        #expect(throws: (any Error).self) {
            _ = try session.start(plan: plan)
        }
        #expect(!session.isRunning)
        #expect(session.activeRunID == nil)
        #expect(recorder.lifecycleEvents.isEmpty)
    }

    @Test func terminateEscalatesFromIgnoredSIGTERMToSIGKILL() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 0.05)
        let script = #"""
        trap '' TERM
        printf '{"type":"keep_alive","ready":true}\n'
        while :; do sleep 1; done
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()
        try session.terminate()
        let exit = await recorder.nextExit()
        #expect(exit == .exited(runID: started.runID, status: 9))
        #expect(!session.isRunning)
    }

    @Test func repeatingEscalationForceCompletesWhenDescendantKeepsPipesOpen() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 0.05)
        let script = #"""
        trap '' TERM
        sleep 1 &
        printf '{"type":"keep_alive","ready":true}\n'
        wait
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()
        try session.terminate()
        let exit = await recorder.nextExit()
        #expect(exit == .exited(runID: started.runID, status: 9))
        #expect(recorder.timeline.last == "exited")
    }

    @Test func closeRetainsEscalationUntilAnIgnoringProcessIsKilled() async throws {
        let recorder = Recorder()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-survived-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let quotedMarker = marker.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        trap '' TERM
        printf '{"type":"keep_alive","ready":true}\\n'
        sleep 0.3
        printf survived > '\(quotedMarker)'
        """

        var session: SupermuxHarnessProcessSession? = makeSession(
            recorder: recorder,
            escalationInterval: 0.05
        )
        weak var releasedSession = session
        let started = try #require(try session?.start(plan: shellPlan(script)))
        _ = await recorder.nextProtocolLine()
        session?.close()
        session = nil

        let exit = await recorder.nextExit()
        #expect(exit == .exited(runID: started.runID, status: 9))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(releasedSession == nil)
    }

    @Test func processExitWaitsForDescendantHeldPipesToReachEOF() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 0.02)
        let script = #"""
        (
          sleep 0.15
          printf '{"type":"keep_alive","late":true}\n'
          printf 'late-err' >&2
        ) &
        trap 'exit 0' TERM
        printf '{"type":"keep_alive","ready":true}\n'
        while :; do sleep 1; done
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()
        session.close()

        let exit = await recorder.nextExit()

        #expect(recorder.protocolLines.last?.object.bool(forKey: "late") == true)
        #expect(recorder.stderrLines.last == "late-err")
        #expect(recorder.timeline.last == "exited")
        #expect(exit == .exited(runID: started.runID, status: 9))
    }

    @Test func terminateAndWaitReturnsOnlyAfterExitedLifecycleAndBothStreamsDrain() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 5)
        let script = #"""
        trap 'printf '\''{"type":"keep_alive","shutdown":true}\n'\''; printf '\''shutdown-err'\'' >&2; exit 0' TERM
        printf '{"type":"keep_alive","ready":true}\n'
        while :; do sleep 0.02; done
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()

        let status = try await session.terminateAndWait(timeout: 1)

        #expect(status == 0)
        #expect(recorder.protocolLines.last?.object.bool(forKey: "shutdown") == true)
        #expect(recorder.stderrLines.last == "shutdown-err")
        #expect(recorder.timeline.last == "exited")
        #expect(recorder.lifecycleEvents.last == .exited(runID: started.runID, status: 0))
        #expect(!session.isRunning)
    }

    @Test func terminateAndWaitHardKillsAfterItsDeadline() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 5)
        let script = #"""
        trap '' TERM
        printf '{"type":"keep_alive","ready":true}\n'
        while :; do sleep 1; done
        """#
        let started = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()

        let status = try await session.terminateAndWait(timeout: 0.03)

        #expect(status == 9)
        #expect(recorder.lifecycleEvents.last == .exited(runID: started.runID, status: 9))
        #expect(!session.isRunning)
    }

    @Test func awaitedTerminationOrdersOldExitBeforeReplacementStart() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 5)
        let first = try session.start(plan: shellPlan(#"""
        trap 'exit 0' TERM
        printf '{"type":"keep_alive","oldReady":true}\n'
        while :; do sleep 0.02; done
        """#))
        _ = await recorder.nextProtocolLine()

        #expect(try await session.terminateAndWait(timeout: 1) == 0)
        let second = try session.start(plan: shellPlan("exit 0"))
        _ = await recorder.nextExit()

        let oldExit = recorder.lifecycleEvents.firstIndex(of: .exited(runID: first.runID, status: 0))
        let replacementStart = recorder.lifecycleEvents.firstIndex(
            of: .started(runID: second.runID, processID: second.processID)
        )
        #expect(oldExit != nil)
        #expect(replacementStart != nil)
        if let oldExit, let replacementStart {
            #expect(oldExit < replacementStart)
        }
    }

    @Test func closeIsIdempotentAndMissingProcessOperationsFail() async throws {
        let recorder = Recorder()
        let session = makeSession(recorder: recorder, escalationInterval: 0.05)
        session.close()
        do {
            try await session.send(
                SupermuxHarnessProtocolEncoder().userMessage(text: "late", uuid: "late")
            )
            Issue.record("Expected not-running send error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .notRunning)
        }
        do {
            try await session.closeInput()
            Issue.record("Expected not-running close-input error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .notRunning)
        }
        do {
            try session.terminate()
            Issue.record("Expected not-running terminate error")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .notRunning)
        }

        let script = #"""
        trap '' TERM
        printf '{"type":"keep_alive","ready":true}\n'
        while :; do sleep 1; done
        """#
        _ = try session.start(plan: shellPlan(script))
        _ = await recorder.nextProtocolLine()
        session.close()
        do {
            try await session.send(
                SupermuxHarnessProtocolEncoder().userMessage(text: "late", uuid: "late")
            )
            Issue.record("Expected terminating input to be closed")
        } catch let error as SupermuxHarnessProcessError {
            #expect(error == .inputClosed)
        }
        session.close()
        _ = await recorder.nextExit()
        #expect(!session.isRunning)
    }

    private func makeSession(
        recorder: Recorder,
        escalationInterval: TimeInterval = 3
    ) -> SupermuxHarnessProcessSession {
        SupermuxHarnessProcessSession(
            terminationEscalationInterval: escalationInterval,
            protocolLineSink: { recorder.receiveProtocol($0) },
            stderrSink: { recorder.receiveStderr($0) },
            lifecycleSink: { recorder.receiveLifecycle($0) },
            outputDiagnosticSink: { recorder.receiveOutputDiagnostic($0) }
        )
    }

    private func shellPlan(_ script: String) -> SupermuxHarnessLaunchPlan {
        SupermuxHarnessLaunchPlan(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )
    }
}
