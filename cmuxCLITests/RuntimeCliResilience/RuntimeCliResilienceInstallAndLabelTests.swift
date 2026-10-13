// SUPERMUX:begin runtime-cli-resilience-cli-regressions
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct RuntimeCliResilienceInstallAndLabelTests {
    private func temporaryHome(_ suffix: String = "") throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-cli-\(UUID().uuidString)\(suffix)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func run(_ arguments: [String], home: URL, terminalInput: String? = nil,
                     environment additions: [String: String] = [:]) async throws -> (Int32, String) {
        let binary = try #require(ProcessInfo.processInfo.environment["CMUX_CLI_PATH"])
        let output = home.appendingPathComponent("test-output")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
                           "CFFIXED_USER_HOME": home.path, "SHELL": "/bin/sh", "CMUX_CLI_SENTRY_DISABLED": "1",
                           "CMUX_SOCKET_PATH": "/tmp/runtime-cli-\(UUID().uuidString).sock"]
        environment.merge(additions) { _, new in new }
        if let terminalInput {
            let done = home.appendingPathComponent("terminal-done").path
            environment["CMUX_TEST_TERMINAL_INPUT"] = terminalInput
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", #"done="$1"; shift; mkfifo "$done" || exit 125; { printf '%s' "$CMUX_TEST_TERMINAL_INPUT"; read _ < "$done"; } | { /usr/bin/script -q /dev/null "$@"; status=$?; echo > "$done"; exit "$status"; }"#, "sh", done, binary] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
    }

    @Test(arguments: ["directory", "write", "quote", "backslash"])
    func museInstallRejectsFailedMaterializationWithoutChangingSettings(failure: String) async throws {
        let home = try temporaryHome(failure == "quote" ? "'quote" : failure == "backslash" ? "\\backslash" : "")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".config/muse/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"hooks":{},"existing":"keep"}"#
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let hooks = home.appendingPathComponent(".cmux/hooks/muse")
        if failure == "directory" {
            try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
            try "blocking file".write(to: hooks.deletingLastPathComponent(), atomically: true, encoding: .utf8)
        } else if failure == "write" {
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hooks.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.path) }
        let (status, output) = try await run(["hooks", "muse", "install", "--yes"], home: home)
        #expect(status != 0, "Install succeeded: \(output)")
        #expect(output.lowercased().contains("muse") && output.lowercased().contains("hook"), "\(output)")
        #expect(output.contains(hooks.path), "Error must identify the target: \(output)")
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    }

    @Test func museNormalInstallKeepsPortableScripts() async throws {
        let home = try temporaryHome(" with spaces")
        defer { try? FileManager.default.removeItem(at: home) }
        let (status, output) = try await run(["hooks", "muse", "install", "--yes"], home: home)
        #expect(status == 0, "\(output)")
        let data = try Data(contentsOf: home.appendingPathComponent(".config/muse/settings.json"))
        let settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        #expect(!hooks.isEmpty)
        for entries in hooks.values {
            for entry in entries {
                let nested = try #require(entry["hooks"] as? [[String: Any]])
                let command = try #require(nested.first?["command"] as? String)
                #expect(command.hasPrefix("'\(home.path)/.cmux/hooks/muse/"))
                #expect(command.contains("cmux-muse-hook-v1"))
                let path = try #require(command.split(separator: "'").first).description
                #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("#!/bin/sh\n"))
                #expect(FileManager.default.isExecutableFile(atPath: path))
            }
        }
    }

    @Test(arguments: ["short", "ascii64", "ascii65", "emoji64", "emoji65", "explicit", "typed"])
    func oauthDefaultLabelMatchesServerUTF16Boundary(shape: String) async throws {
        let email: String
        switch shape {
        case "ascii64": email = String(repeating: "a", count: 52) + "@example.com"
        case "ascii65", "explicit": email = String(repeating: "a", count: 53) + "@example.com"
        case "emoji64": email = String(repeating: "😀", count: 32)
        case "emoji65": email = String(repeating: "😀", count: 32) + "x"
        default: email = "dev@example.com"
        }
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": email]])
        try config.write(to: home.appendingPathComponent(".claude.json"))
        let socketPath = "/tmp/runtime-cli-\(UUID().uuidString).sock"
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener); unlink(socketPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8CString.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)
        let server = Task.detached { () throws -> String in
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { Darwin.close(client) }
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1 {
                if byte == 10 { break }
                bytes.append(byte)
            }
            let request = String(decoding: bytes, as: UTF8.self)
            let json = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            #expect(json["method"] as? String == "coderouter.claude_upstream.add")
            let response = try JSONSerialization.data(withJSONObject: ["id": json["id"] ?? "", "ok": true, "result": ["teamId": "team_fixture", "account": ["id": "account_fixture"], "accountsTotal": 1]]) + Data([10])
            try #require(response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } == response.count)
            return request
        }
        var arguments = ["--socket", socketPath, "--json", "coderouter", "claude", "add", "oauth-token", "--team", "team_fixture"]
        if shape == "explicit" { arguments += ["--label", "work"] }
        let (status, output) = try await run(arguments, home: home, terminalInput: shape == "typed" ? "work\n" : "\n",
            environment: ["CLAUDE_CONFIG_DIR": "", "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-runtime-test-not-a-secret"])
        #expect(status == 0, "\(output)")
        let request = try await server.value
        let json = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["visibility"] as? String == "team")
        #expect(params["teamId"] as? String == "team_fixture")
        if shape == "explicit" || shape == "typed" {
            #expect(params["label"] as? String == "work")
        } else if email.utf16.count <= 64 {
            #expect(params["label"] as? String == email)
            #expect(output.contains("Label (Enter for \(email))"))
        } else {
            #expect(params["label"] == nil)
            #expect(!output.contains("Enter for"))
        }
        #expect(!output.contains("sk-ant-oat01-runtime-test-not-a-secret"))
    }
}
// SUPERMUX:end runtime-cli-resilience-cli-regressions
