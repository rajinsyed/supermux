import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Supermux ccx resume launcher")
struct SupermuxCCXResumeLauncherTests {
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let launcherPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/bin/ccx")

    @Test("Structured Claude restore resumes through an opted-in ccx launcher")
    func structuredRestoreUsesCCXLauncher() throws {
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/work",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                executablePath: "/opt/claude",
                arguments: [
                    "/opt/claude",
                    "--settings",
                    "/Users/example/.ccx/models.json",
                    "--agents",
                    #"{"sol":{"model":"gpt-5.6-sol"}}"#,
                    "--append-system-prompt",
                    "ccx runtime prompt",
                    "--dangerously-skip-permissions",
                ],
                workingDirectory: "/tmp/work",
                environment: [
                    AgentLaunchEnvironmentPolicy.claudeResumeLauncherEnvironmentKey: launcherPath,
                    "ANTHROPIC_AUTH_TOKEN": "secret-should-not-persist",
                ],
                capturedAt: nil,
                source: nil
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(
            AgentRestorePlanner(isExecutableFile: { $0 == self.launcherPath })
                .invocation(for: request, ambientEnvironment: [:])
        )

        #expect(invocation.arguments == [launcherPath, "--resume", sessionID])
        #expect(
            invocation.environment["CMUX_AGENT_RESTORE_LAUNCH"]
                == "claude:\(sessionID)"
        )
        #expect(
            invocation.environment["CMUX_CLAUDE_RESUME_LAUNCHER"]
                == launcherPath
        )
        #expect(invocation.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
    }

    @Test(
        "Invalid ccx launcher markers fall back to ordinary Claude resume",
        arguments: [
            "ccx",
            "/tmp/ccx",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/not-ccx"),
        ]
    )
    func invalidLauncherFallsBackToClaude(launcher: String) throws {
        let argv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: sessionID,
                executablePath: "/opt/claude",
                arguments: ["/opt/claude", "--model", "opus"],
                environment: [
                    AgentLaunchEnvironmentPolicy.claudeResumeLauncherEnvironmentKey: launcher,
                ]
            )
        )

        #expect(argv == ["claude", "--resume", sessionID, "--model", "opus"])
    }

    @Test("ccx launcher marker is isolated to Claude captures")
    func launcherMarkerIsClaudeOnly() {
        let environment = [
            AgentLaunchEnvironmentPolicy.claudeResumeLauncherEnvironmentKey: launcherPath,
        ]
        let policy = AgentLaunchEnvironmentPolicy()

        let claudeEnvironment = policy.selectedEnvironment(from: environment, kind: "claude")
        let codexEnvironment = policy.selectedEnvironment(from: environment, kind: "codex")

        #expect(
            claudeEnvironment[AgentLaunchEnvironmentPolicy.claudeResumeLauncherEnvironmentKey]
                == launcherPath
        )
        #expect(
            codexEnvironment[AgentLaunchEnvironmentPolicy.claudeResumeLauncherEnvironmentKey]
                == nil
        )
    }
}
