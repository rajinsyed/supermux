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
        #expect(line == "cc --model 'opus[1m]' --effort 'high' -- $'Fix the login redirect'")
    }

    @Test func omitsBlankModelAndEffort() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: " claude ",
            model: "  ",
            effort: nil,
            prompt: "do it"
        )
        #expect(line == "claude -- $'do it'")
    }

    @Test func multiLinePromptStaysOnOneLine() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: "ccx",
            model: nil,
            effort: nil,
            prompt: "Line one\nLine 'two'\tdone\\"
        )
        #expect(!line.contains("\n"))
        #expect(line == "ccx -- $'Line one\\nLine \\'two\\'\\tdone\\\\'")
    }

    /// A prompt that starts with `-` is text, not a flag: the `--` terminator
    /// keeps Claude from parsing it as an option.
    @Test func promptStartingWithADashIsNotParsedAsAnOption() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: "claude",
            model: nil,
            effort: nil,
            prompt: "-v should mean verbose"
        )
        #expect(line == "claude -- $'-v should mean verbose'")
    }

    /// fish has no `$'…'`: the prompt is single-quoted with fish escapes and
    /// newlines travel as unquoted `\n` between the quoted runs.
    @Test func fishShellGetsFishQuoting() {
        let line = SupermuxAgentLaunchCommand.shellLine(
            command: "cc",
            model: "opus",
            effort: nil,
            prompt: "Line one\nit's \\ done",
            shell: .fish
        )
        #expect(line == "cc --model 'opus' -- 'Line one'\\n'it\\'s \\\\ done'")
        #expect(!line.contains("\n"))
    }

    @Test func shellFlavorIsDetectedFromTheShellPath() {
        #expect(SupermuxShellFlavor.detect(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(SupermuxShellFlavor.detect(shellPath: "/bin/zsh") == .posix)
        #expect(SupermuxShellFlavor.detect(shellPath: "/bin/bash") == .posix)
        #expect(SupermuxShellFlavor.detect(shellPath: "") == .posix)
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
