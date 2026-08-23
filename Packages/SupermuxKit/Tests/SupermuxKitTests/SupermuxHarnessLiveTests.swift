import Foundation
import Testing

@testable import SupermuxKit

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SUPERMUX_HARNESS_LIVE_TEST"] == "1")
)
@MainActor
struct SupermuxHarnessLiveTests {
    private enum LiveTestError: Error, CustomStringConvertible {
        case claudeExecutableNotFound
        case processExitedBeforeExpectedFrame(Int32)

        var description: String {
            switch self {
            case .claudeExecutableNotFound:
                "No real Claude executable was found after rejecting cmux wrapper shims."
            case .processExitedBeforeExpectedFrame(let status):
                "Claude exited with status \(status) before the expected frame arrived."
            }
        }
    }

    @MainActor
    private final class Recorder {
        var router: SupermuxHarnessControlRouter?
        var stderr = ""
        private var queuedFrames: [SupermuxHarnessFrame] = []
        private var frameWaiters: [CheckedContinuation<SupermuxHarnessFrame, Never>] = []
        private var queuedExitStatuses: [Int32] = []
        private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

        func receive(_ line: SupermuxHarnessDecodedLine) {
            guard let frame = line.frame else { return }
            router?.consume(frame)
            if frameWaiters.isEmpty {
                queuedFrames.append(frame)
            } else {
                frameWaiters.removeFirst().resume(returning: frame)
            }
        }

        func receiveStderr(_ text: String) {
            stderr += text
        }

        func receiveLifecycle(_ event: SupermuxHarnessProcessLifecycleEvent) {
            guard case .exited(_, let status) = event else { return }
            if exitWaiters.isEmpty {
                queuedExitStatuses.append(status)
            } else {
                exitWaiters.removeFirst().resume(returning: status)
            }
        }

        func nextFrame() async throws -> SupermuxHarnessFrame {
            if !queuedFrames.isEmpty { return queuedFrames.removeFirst() }
            if let status = queuedExitStatuses.first {
                throw LiveTestError.processExitedBeforeExpectedFrame(status)
            }
            return await withCheckedContinuation { continuation in
                frameWaiters.append(continuation)
            }
        }

        func nextExitStatus() async -> Int32 {
            if !queuedExitStatuses.isEmpty { return queuedExitStatuses.removeFirst() }
            return await withCheckedContinuation { continuation in
                exitWaiters.append(continuation)
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func realClaudeSupportsInitializePromptInterruptAndReuse() async throws {
        let executable = try resolveRealClaudeExecutable()
        #expect(!isCmuxClaudeShim(executable))
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-harness-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let recorder = Recorder()
        let session = SupermuxHarnessProcessSession(
            protocolLineSink: { recorder.receive($0) },
            stderrSink: { recorder.receiveStderr($0) },
            lifecycleSink: { recorder.receiveLifecycle($0) }
        )
        let router = SupermuxHarnessControlRouter(
            sender: { frame in try await session.send(frame) }
        )
        recorder.router = router
        let plan = SupermuxHarnessLaunchPlan(
            executableURL: executable,
            workingDirectoryURL: workingDirectory,
            environment: sanitizedLiveEnvironment(executable: executable),
            options: SupermuxHarnessLaunchOptions(model: "haiku")
        )
        _ = try session.start(plan: plan)
        defer { session.close() }

        let initialization = try await router.issue(.initialize)
        #expect(initialization.rawValue["commands"] is [Any])
        #expect(initialization.rawValue["models"] is [Any])
        #expect(initialization.string(forKey: "current_permission_mode") != nil)

        let encoder = SupermuxHarnessProtocolEncoder()
        try await session.send(encoder.userMessage(
            text: "Reply with exactly LIVE_OK and no other text. Do not use tools.",
            uuid: UUID().uuidString
        ))
        let firstTurn = try await collectTurn(recorder: recorder)
        #expect(firstTurn.sawInitialization)
        #expect(firstTurn.sawAssistant)
        #expect(firstTurn.result.subtype == .success)
        #expect(firstTurn.result.result?.contains("LIVE_OK") == true)

        try await session.send(encoder.userMessage(
            text: "Write a detailed 5000-word essay about sorting algorithms. Begin immediately and do not use tools.",
            uuid: UUID().uuidString
        ))
        var sawActiveRequest = false
        while !sawActiveRequest {
            let frame = try await recorder.nextFrame()
            switch frame {
            case .system(let system) where system.subtype == .status:
                sawActiveRequest = system.rawObject.string(forKey: "status") == "requesting"
            case .streamEvent(let stream) where stream.eventType == .messageStart:
                sawActiveRequest = true
            case .result(let result):
                Issue.record("The interrupt turn completed before it could be interrupted: \(String(describing: result.result))")
                return
            default:
                break
            }
        }

        let interruptReceipt = try await router.issue(.interrupt(cancelQueued: true))
        #expect(interruptReceipt.rawValue["still_queued"] is [Any])
        let interrupted = try await collectResult(recorder: recorder)
        #expect(interrupted.subtype == .errorDuringExecution)
        #expect(interrupted.isError)
        #expect(["aborted_streaming", "aborted_tools"].contains(interrupted.terminalReason ?? ""))

        try await session.send(encoder.userMessage(
            text: "Reply with exactly LIVE_AFTER_INTERRUPT and no other text. Do not use tools.",
            uuid: UUID().uuidString
        ))
        let recovery = try await collectTurn(recorder: recorder)
        #expect(recovery.sawAssistant)
        #expect(recovery.result.subtype == .success)
        #expect(recovery.result.result?.contains("LIVE_AFTER_INTERRUPT") == true)

        try await session.closeInput()
        #expect(await recorder.nextExitStatus() == 0)
        await router.close(denialMessage: "Live test ended")
        #expect(recorder.stderr.isEmpty || !recorder.stderr.contains("Error:"))
    }

    private func collectTurn(
        recorder: Recorder
    ) async throws -> (
        sawInitialization: Bool,
        sawAssistant: Bool,
        result: SupermuxHarnessResultFrame
    ) {
        var sawInitialization = false
        var sawAssistant = false
        while true {
            switch try await recorder.nextFrame() {
            case .system(let frame):
                sawInitialization = sawInitialization || frame.subtype == .initialize
            case .assistant:
                sawAssistant = true
            case .result(let result):
                return (sawInitialization, sawAssistant, result)
            default:
                break
            }
        }
    }

    private func collectResult(recorder: Recorder) async throws -> SupermuxHarnessResultFrame {
        while true {
            if case .result(let result) = try await recorder.nextFrame() {
                return result
            }
        }
    }

    private func resolveRealClaudeExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("claude", isDirectory: false)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate.path),
                  !isCmuxClaudeShim(candidate) else {
                continue
            }
            return candidate
        }
        throw LiveTestError.claudeExecutableNotFound
    }

    private func isCmuxClaudeShim(_ executable: URL) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let path = executable.standardizedFileURL.path
        if let configured = environment["CMUX_CLAUDE_WRAPPER_SHIM"],
           path == URL(fileURLWithPath: configured).standardizedFileURL.path {
            return true
        }
        let roots: [String?] = [
            environment["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"],
            URL(fileURLWithPath: environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-cli-shims", isDirectory: true).standardizedFileURL.path,
            "/tmp/cmux-cli-shims",
        ]
        if roots.compactMap({ $0 }).contains(where: { root in
            path.hasPrefix(URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path + "/")
        }) {
            return true
        }
        guard let data = FileManager.default.contents(atPath: path),
              let prefix = String(data: data.prefix(512), encoding: .utf8) else {
            return false
        }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    private func sanitizedLiveEnvironment(executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where
            key == "CLAUDECODE"
                || key == "CLAUDE_PID"
                || key.hasPrefix("CLAUDE_CODE_")
                || key.hasPrefix("CMUX_CLAUDE_")
                || key.hasPrefix("CMUX_AGENT_")
                || key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        let executableDirectory = executable.deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = inheritedPath.isEmpty
            ? executableDirectory
            : "\(executableDirectory):\(inheritedPath)"
        return environment
    }
}
