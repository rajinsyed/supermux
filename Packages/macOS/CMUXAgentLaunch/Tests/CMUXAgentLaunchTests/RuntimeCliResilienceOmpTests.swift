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
}
// SUPERMUX:end runtime-cli-resilience-omp-regressions
