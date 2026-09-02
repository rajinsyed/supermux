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

/// The launch line is written into a just-spawned shell's pty while that tty
/// is still in canonical mode, and macOS discards canonical input beyond
/// MAX_CANON (1024 bytes). A prompt that would push the line past that limit
/// must travel through a file the line reads instead of inline.
struct SupermuxAgentLaunchLineTests {
    private static let longPrompt: String = {
        let piece = "Fix the 'login' redirect → it's broken\n\t$HOME \"quoted\" \\ back 日本語 😀 100% done; "
        return String(repeating: piece, count: 20)
    }()

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-agent-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func shortPromptsStayInline() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: "Fix it", shell: .posix, promptFileDirectory: directory
        )
        #expect(launch.line == "claude -- $'Fix it'")
        #expect(launch.promptFile == nil)
    }

    @Test func longPromptsMoveToAFileSoTheInputLineFitsThePty() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = SupermuxAgentLaunchCommand.launchLine(
            command: "cc", model: "opus", effort: "high", prompt: Self.longPrompt, shell: .posix, promptFileDirectory: directory
        )
        let file = try #require(launch.promptFile)
        #expect(file.contents == Self.longPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(file.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(launch.line.utf8.count + 1 <= SupermuxAgentLaunchCommand.maxInputUTF8Length)
        #expect(launch.line.hasPrefix("cc --model 'opus' --effort 'high' -- "))
        #expect(!launch.line.contains("\n"))
    }

    /// The preview (before anything is written) and the real launch must agree,
    /// so the file location is a pure function of the prompt.
    @Test func promptFileLocationIsDeterministic() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: Self.longPrompt, shell: .posix, promptFileDirectory: directory
        )
        let second = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: Self.longPrompt, shell: .posix, promptFileDirectory: directory
        )
        #expect(first == second)
        let other = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: Self.longPrompt + " more", shell: .posix, promptFileDirectory: directory
        )
        #expect(other.promptFile?.url != first.promptFile?.url)
    }

    /// zsh must hand Claude the exact prompt when it reads the file.
    @Test func fileBackedPromptRoundTripsThroughZsh() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = SupermuxAgentLaunchCommand.launchLine(
            command: "printf '%s'", model: nil, effort: nil, prompt: Self.longPrompt, shell: .posix, promptFileDirectory: directory
        )
        let file = try #require(launch.promptFile)
        try SupermuxAgentPromptFileStore.write(file)
        // Drop the `--` terminator: printf has no options here.
        let script = launch.line.replacingOccurrences(of: "printf '%s' -- ", with: "printf '%s' ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == file.contents)
    }

    @Test func fishReadsThePromptFileAsOneArgument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: Self.longPrompt, shell: .fish, promptFileDirectory: directory
        )
        let file = try #require(launch.promptFile)
        #expect(launch.line == "claude -- (command cat -- \(SupermuxShellQuoting.fishQuoted(file.url.path)) | string collect)")
    }

    /// A user alias like `cat=bat` must not get between the shell and the file.
    @Test func posixLineReadsTheFileWithTheRealCat() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = SupermuxAgentLaunchCommand.launchLine(
            command: "claude", model: nil, effort: nil, prompt: Self.longPrompt, shell: .posix, promptFileDirectory: directory
        )
        let file = try #require(launch.promptFile)
        #expect(launch.line == "claude -- \"$(command cat -- \(SupermuxShellQuoting.singleQuoted(file.url.path)))\"")
    }

    @Test func promptFileStoreWritesPrivatelyAndPrunesOldFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let stale = directory.appendingPathComponent("stale.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        // Only stale `.txt` prompt files are pruned: not other files, not directories.
        let otherFile = directory.appendingPathComponent("notes.md")
        try "keep".write(to: otherFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: otherFile.path)
        let subdirectory = directory.appendingPathComponent("nested.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: subdirectory.path)
        let file = SupermuxAgentPromptFile(url: directory.appendingPathComponent("fresh.txt"), contents: "hi")
        try SupermuxAgentPromptFileStore.write(file)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "hi")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(FileManager.default.fileExists(atPath: subdirectory.path))
    }
}
