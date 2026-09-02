import Foundation
import Testing
@testable import SupermuxKit

/// The shell line that starts Claude in a new worktree: model/effort flags
/// only when chosen, and a prompt quoted so it survives as ONE input line.
struct SupermuxAgentLaunchCommandTests {
    @Test func composesCommandModelEffortAndPrompt() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: "cc",
            model: "opus[1m]",
            effort: "high",
            prompt: "Fix the login redirect"
        )
        #expect(line == "cc --model 'opus[1m]' --effort 'high' $'Fix the login redirect'")
    }

    @Test func omitsBlankModelAndEffort() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: " claude ",
            model: "  ",
            effort: nil,
            prompt: "do it"
        )
        #expect(line == "claude $'do it'")
    }

    @Test func multiLinePromptStaysOnOneLine() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: "ccx",
            model: nil,
            effort: nil,
            prompt: "Line one\nLine 'two'\tdone\\"
        )
        #expect(!line.contains("\n"))
        #expect(line == "ccx $'Line one\\nLine \\'two\\'\\tdone\\\\'")
    }

    @Test func singleQuotingEscapesEmbeddedQuotes() {
        #expect(SupermuxShellQuoting.singleQuoted("it's") == "'it'\\''s'")
    }

    /// The quoted prompt must decode back to the original under ANSI-C rules,
    /// which is what zsh/bash do before handing it to Claude.
    @Test func ansiCQuotedPromptRoundTripsThroughTheShell() throws {
        let prompt = "Refactor 'auth' → tokens\n\tkeep $HOME literal \\ and \"quotes\""
        let quoted = SupermuxShellQuoting.ansiCQuoted(prompt)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf '%s' " + quoted]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == prompt)
    }
}
