import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Spawn-argument construction and the tool-name humanizer table.
struct SpawnArgumentsAndHumanizerTests {
    private let claude = ClaudeLauncher(
        kind: .claude, executablePath: "/usr/local/bin/claude", displayName: "Claude Code"
    )
    private let ccx = ClaudeLauncher(
        kind: .ccx, executablePath: "/Users/u/.local/bin/ccx", displayName: "ccx"
    )
    private let custom = ClaudeLauncher(
        kind: .custom, executablePath: "/opt/bin/my-claude", displayName: "my-claude"
    )

    @Test func freshSessionArgumentsForPlainClaude() {
        let args = ClaudeSpawnArguments(
            identity: .new(sessionID: "11111111-2222-3333-4444-555555555555"),
            model: "claude-fable-5",
            effort: "high"
        ).arguments(for: claude)
        #expect(args == [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--replay-user-messages",
            "--dangerously-skip-permissions",
            "--session-id", "11111111-2222-3333-4444-555555555555",
            "--model", "claude-fable-5",
            "--effort", "high",
        ])
    }

    @Test func ccxNeverGetsSkipPermissionsTwice() {
        let args = ClaudeSpawnArguments(
            identity: .new(sessionID: "s")
        ).arguments(for: ccx)
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test func customLauncherGetsSkipPermissions() {
        let args = ClaudeSpawnArguments(
            identity: .new(sessionID: "s")
        ).arguments(for: custom)
        #expect(args.contains("--dangerously-skip-permissions"))
    }

    @Test func noPermissionFlagsAreEverPassed() {
        for launcher in [claude, ccx, custom] {
            let args = ClaudeSpawnArguments(
                identity: .new(sessionID: "s"), model: "m", effort: "low"
            ).arguments(for: launcher)
            #expect(!args.contains("--permission-prompt-tool"))
            #expect(!args.contains("--permission-mode"))
        }
    }

    @Test func resumeUsesResumeFlagWithoutSessionID() {
        let args = ClaudeSpawnArguments(
            identity: .resume(sessionID: "prov-123")
        ).arguments(for: claude)
        #expect(args.contains("--resume"))
        #expect(args.contains("prov-123"))
        #expect(!args.contains("--session-id"))
    }

    @Test func launcherRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(ccx)
        let decoded = try JSONDecoder().decode(ClaudeLauncher.self, from: data)
        #expect(decoded == ccx)
    }

    /// Every tool observed in the captured `system.init.tools` lists has a
    /// curated humanizer entry (MCP tools use the derived fallback).
    @Test func humanizerCoversAllFixtureTools() throws {
        let fixture = try FixtureSupport.decode("tool-turn.jsonl")
        let tools = try #require(fixture.initializations.first).tools
        for tool in tools where !tool.hasPrefix("mcp__") {
            #expect(
                ClaudeToolHumanizer.table[tool] != nil,
                "missing humanizer entry for \(tool)"
            )
        }
    }

    @Test func humanizerCoreLabels() {
        #expect(ClaudeToolHumanizer.labels(for: "Read").running == "Reading file")
        #expect(ClaudeToolHumanizer.labels(for: "Bash").running == "Running command")
        #expect(ClaudeToolHumanizer.labels(for: "Bash").done == "Ran command")
        #expect(ClaudeToolHumanizer.labels(for: "TodoWrite").running == "Updating to-dos")
        #expect(ClaudeToolHumanizer.labels(for: "Task").running == "Running agent")
        #expect(ClaudeToolHumanizer.labels(for: "WebSearch").running == "Searching the web")
    }

    @Test func humanizerMCPFallback() {
        let labels = ClaudeToolHumanizer.labels(for: "mcp__codex__codex-reply")
        #expect(labels.running == "Running codex: codex-reply")
        let plain = ClaudeToolHumanizer.labels(for: "SomeNewTool")
        #expect(plain.running == "Running SomeNewTool")
    }
}
