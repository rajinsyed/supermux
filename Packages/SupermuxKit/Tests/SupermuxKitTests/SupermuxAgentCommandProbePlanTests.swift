import Foundation
import Testing
@testable import SupermuxKit

/// The probe plan runs the user's command through their interactive login
/// shell so aliases resolve, and appends Claude's stream-json flags.
struct SupermuxAgentCommandProbePlanTests {
    @Test func planRunsCommandThroughInteractiveLoginShell() {
        let plan = SupermuxAgentCommandProbePlan.plan(
            command: " cc ",
            shellPath: "/bin/zsh",
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/proj/"),
            environment: ["HOME": "/Users/x"]
        )
        #expect(plan.executableURL.path == "/bin/zsh")
        #expect(plan.arguments == [
            "-lic", "cc \"$@\"", "cc",
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
        ])
        #expect(plan.workingDirectoryURL.path == "/tmp/proj")
        #expect(plan.environment["PWD"] == "/tmp/proj")
        #expect(plan.environment["HOME"] == "/Users/x")
    }

    @Test func shellPathFallsBackToZsh() {
        #expect(SupermuxAgentCommandProbePlan.shellPath(environment: [:]) == "/bin/zsh")
        #expect(SupermuxAgentCommandProbePlan.shellPath(environment: ["SHELL": " "]) == "/bin/zsh")
        #expect(SupermuxAgentCommandProbePlan.shellPath(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
    }

    /// An alias defined only in the rc file must reach the probe: `-i` sources
    /// it, `-l` the profile, and `"$@"` forwards the flags verbatim.
    @Test func aliasInRcFileResolvesAndReceivesFlags() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-probe-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "alias fakeclaude='printf \"%s|\"'\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
        )
        let plan = SupermuxAgentCommandProbePlan.plan(
            command: "fakeclaude",
            shellPath: "/bin/zsh",
            workingDirectoryURL: home,
            environment: ["ZDOTDIR": home.path, "HOME": home.path, "PATH": "/usr/bin:/bin"]
        )
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectoryURL
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text == "-p|--input-format|stream-json|--output-format|stream-json|--verbose|--permission-prompt-tool|stdio|")
    }
}
