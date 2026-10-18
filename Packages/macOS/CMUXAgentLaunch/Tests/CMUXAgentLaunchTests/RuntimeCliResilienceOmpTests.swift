// SUPERMUX:begin runtime-cli-resilience-omp-regressions
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct RuntimeCliResilienceOmpTests {
    @Test(arguments: ["node", "bun", "deno", "tsx", "ts-node"])
    func runtimeScriptPrefixSurvivesCaptureAndResume(runtime: String) throws {
        let executable = "/opt/runtime/\(runtime)"
        let script = "/opt/non-executable/oh-my-pi/cli.js"
        let captured = [executable, script, "--session", "old", "--model", "sonnet", "private prompt"]
        let sanitized = try #require(AgentLaunchSanitizer.sanitizedLaunchArguments(
            captured, launcher: "omp", fallbackKind: "omp"
        ))
        #expect(sanitized == [executable, script, "--model", "sonnet"])
        #expect(AgentResumeArgv().builtInKind(
            kind: "omp", sessionId: "new", executablePath: executable, arguments: sanitized
        ) == [executable, script, "--session", "new", "--model", "sonnet"])
    }

    @Test func executableOmpAndOtherProvidersKeepTheirLaunchShape() {
        #expect(AgentResumeArgv().builtInKind(
            kind: "omp", sessionId: "new", executablePath: "/opt/bin/omp",
            arguments: ["/opt/bin/omp", "--model", "sonnet"]
        ) == ["/opt/bin/omp", "--session", "new", "--model", "sonnet"])
        #expect(AgentResumeArgv().builtInKind(
            kind: "claude", sessionId: "new", executablePath: "/opt/bin/claude",
            arguments: ["/opt/bin/claude", "--model", "sonnet"]
        ) == ["claude", "--resume", "new", "--model", "sonnet"])
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(
            ["/opt/bin/node", "private prompt", "--model", "sonnet"], launcher: "omp", fallbackKind: "omp"
        ) == ["/opt/bin/node"])
    }

    @Test(arguments: ["--print", "--mode", "--export", "--no-session", "--prompt", "-p"])
    func runtimeScriptStillRejectsUnsafeAgentModes(option: String) {
        let argv = ["/opt/bin/node", "/opt/oh-my-pi/cli.js", option, "unsafe"]
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(argv, launcher: "omp", fallbackKind: "omp") == nil)
        #expect(AgentResumeArgv().builtInKind(kind: "omp", sessionId: "new", executablePath: argv[0], arguments: argv) == nil)
    }

    @Test func runtimeScriptDoesNotPersistCredentialsOrPrompt() {
        let argv = ["/opt/bin/node", "/opt/oh-my-pi/cli.js", "--api-key", "not-a-real-secret", "--model", "sonnet", "private prompt"]
        #expect(AgentLaunchSanitizer.sanitizedLaunchArguments(argv, launcher: "omp", fallbackKind: "omp")
            == [argv[0], argv[1], "--model", "sonnet"])
    }

    @Test func nonExecutableScriptRunsThroughRealCaptureSanitizeRestorePath() throws {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        lookup.arguments = ["node"]
        lookup.standardOutput = output
        try lookup.run()
        lookup.waitUntilExit()
        try #require(lookup.terminationStatus == 0, "Node is required for the runtime restore discriminator")
        let node = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-cli-omp-\(UUID().uuidString)/oh-my-pi")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let script = root.appendingPathComponent("cli.js")
        try #"require('node:fs').writeFileSync(process.env.OMP_RESTORE_CAPTURE, JSON.stringify(process.argv.slice(1)))"#
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        #expect(!FileManager.default.isExecutableFile(atPath: script.path))
        let sanitized = try #require(AgentLaunchSanitizer.sanitizedLaunchArguments(
            [node, script.path, "--model", "sonnet"], launcher: "omp", fallbackKind: "omp"
        ))
        let request = AgentRestoreRequest(mode: .resumeAgent, kind: "omp", checkpointID: "new", source: "agent-hook",
            workingDirectory: root.path, environment: [:], launchCommand: AgentLaunchCommand(
                launcher: "omp", executablePath: node, arguments: sanitized
            ), preparedArguments: nil, observedPermissionMode: nil)
        let marker = root.appendingPathComponent("restored-argv.json")
        let invocation = try #require(AgentRestorePlanner(isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) })
            .invocation(for: request, ambientEnvironment: ["PATH": "/usr/bin:/bin", "OMP_RESTORE_CAPTURE": marker.path]))
        #expect(invocation.arguments == [node, script.path, "--session", "new", "--model", "sonnet"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.arguments[0])
        process.arguments = Array(invocation.arguments.dropFirst())
        process.environment = invocation.environment
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Restored launcher failed to execute the non-executable script")
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String]
            == [script.path, "--session", "new", "--model", "sonnet"])
    }
}
// SUPERMUX:end runtime-cli-resilience-omp-regressions
