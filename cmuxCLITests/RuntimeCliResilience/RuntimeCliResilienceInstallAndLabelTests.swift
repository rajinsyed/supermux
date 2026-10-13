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
                     timeout: TimeInterval? = nil,
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
            do {
                try process.run()
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }
                }
            } catch { continuation.resume(throwing: error) }
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

    // SUPERMUX:begin runtime-cli-resilience-muse-review-regressions
    private var museOriginalSettings: Data {
        Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo user-owned"}]}]},"existing":"keep"}"#.utf8)
    }

    private func museCommands(in settings: URL) throws -> [String] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        return hooks.values.flatMap { $0 }.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    @Test(arguments: [false, true])
    func museMatchingNonExecutableScriptRequiresSuccessfulChmod(immutable: Bool) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".config/muse/settings.json")
        let environment = ["CMUX_SOCKET_PATH": "/tmp/runtime-muse-review.sock"]
        let seeded = try await run(["hooks", "muse", "install", "--yes"], home: home, environment: environment)
        try #require(seeded.0 == 0, "\(seeded.1)")
        let command = try #require(museCommands(in: settings).first)
        let path = try #require(command.split(separator: "'").first).description
        let contents = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        if immutable {
            try #require(Darwin.chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        }
        defer { _ = Darwin.chflags(path, 0) }
        #expect(!FileManager.default.isExecutableFile(atPath: path))
        if immutable {
            errno = 0
            let chmodResult = Darwin.chmod(path, 0o755)
            let chmodErrno = errno
            #expect(chmodResult == -1 && chmodErrno == EPERM, "Immutable fixture must actually reject chmod")
        }
        try museOriginalSettings.write(to: settings)
        let (status, output) = try await run(["hooks", "muse", "install", "--yes"], home: home, environment: environment)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == contents, "Reuse identical content-addressed script")
        if immutable {
            #expect(status != 0, "Install accepted an unexecutable immutable script: \(output)")
            #expect(output.contains("Cannot write Muse hook script"), "\(output)")
            #expect(try Data(contentsOf: settings) == museOriginalSettings)
        } else {
            #expect(status == 0, "\(output)")
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(try museCommands(in: settings).contains("echo user-owned"))
        }
    }

    @Test(arguments: ["none", "repeat-write", "unwritable", "unexecutable"])
    func museLateMaterializationFailureKeepsSettings(failure: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".config/muse/settings.json")
        let scripts = home.appendingPathComponent(".cmux/hooks/muse")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try museOriginalSettings.write(to: settings)
        let ready = home.appendingPathComponent("read-ready")
        let release = home.appendingPathComponent("read-release")
        let attempts = home.appendingPathComponent("repeat-materialization-attempts")
        try #require(Darwin.mkfifo(ready.path, 0o600) == 0)
        try #require(Darwin.mkfifo(release.path, 0o600) == 0)
        let interpose = try #require(ProcessInfo.processInfo.environment["CMUX_MUSE_REVIEW_INTERPOSE"])
        // The OS read gate pauses the real CLI after preflight and before the final hook builder.
        // Both FIFO ends are held read-write so no open blocks; the readiness wait is bounded.
        // On failure, release and join the CLI before closing the writer so it cannot miss the byte.
        let reader = Darwin.open(ready.path, O_RDWR)
        let writer = Darwin.open(release.path, O_RDWR)
        defer {
            if writer >= 0 { Darwin.close(writer) }
            if reader >= 0 { Darwin.close(reader) }
        }
        try #require(reader >= 0 && writer >= 0)
        let installation = Task {
            defer {
                var marker = UInt8(ascii: "x")
                let sentinel = Darwin.open(ready.path, O_WRONLY | O_NONBLOCK)
                if sentinel >= 0 {
                    _ = Darwin.write(sentinel, &marker, 1)
                    Darwin.close(sentinel)
                }
            }
            return try await run(["hooks", "muse", "install", "--yes"], home: home, timeout: 20, environment: [
                "DYLD_INSERT_LIBRARIES": interpose,
                "CMUX_MUSE_REVIEW_READY": ready.path,
                "CMUX_MUSE_REVIEW_RELEASE": release.path,
                "CMUX_MUSE_REVIEW_ATTEMPTS": attempts.path,
                "CMUX_MUSE_REVIEW_BLOCK_REPEAT": failure == "repeat-write" ? "1" : "0"
            ])
        }
        let finishGate = Task.detached {
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            try #require(Darwin.poll(&descriptor, 1, 10_000) == 1, "CLI never reached the settings read gate")
            var byte: UInt8 = 0
            try #require(Darwin.read(reader, &byte, 1) == 1 && byte == UInt8(ascii: "g"))
            let paths = try FileManager.default.contentsOfDirectory(at: scripts, includingPropertiesForKeys: nil)
            try #require(paths.count == 5, "All six events materialized (two share notification)")
            for path in paths {
                #expect(FileManager.default.isExecutableFile(atPath: path.path))
                #expect(try String(contentsOf: path, encoding: .utf8).hasPrefix("#!/bin/sh\n"))
            }
            let locked = try #require(paths.first)
            defer { _ = Darwin.chflags(locked.path, 0) }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.path) }
            if failure == "unwritable" {
                for path in paths { try FileManager.default.removeItem(at: path) }
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scripts.path)
            } else if failure == "unexecutable" {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
                try #require(Darwin.chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
            }
            try #require(Darwin.write(writer, &byte, 1) == 1)
            _ = try await installation.value
        }
        do {
            try await finishGate.value
        } catch {
            var releaseByte = UInt8(ascii: "g")
            _ = Darwin.write(writer, &releaseByte, 1)
            _ = try? await installation.value
            throw error
        }
        let (status, output) = try await installation.value
        if failure == "repeat-write" {
            #expect(!FileManager.default.fileExists(atPath: attempts.path), "Install must not rematerialize while pruning user-owned hook entries")
        }
        if failure == "none" || failure == "repeat-write" {
            #expect(status == 0, "\(output)")
            let commands = try museCommands(in: settings)
            #expect(commands.count == 7)
            #expect(commands.contains("echo user-owned"))
            #expect(commands.filter { $0.contains("cmux-muse-hook-v1") }.allSatisfy { $0.hasPrefix("'\(scripts.path)/") })
            for command in commands where command.hasPrefix("'\(scripts.path)/") {
                let path = try #require(command.split(separator: "'").first).description
                #expect(FileManager.default.isExecutableFile(atPath: path))
            }
        } else {
            #expect(status != 0, "Late failure accepted: \(output)")
            #expect(output.contains("Cannot write Muse hook script"), "\(output)")
            #expect(try Data(contentsOf: settings) == museOriginalSettings, "Failed install must not persist inline or unexecutable commands")
        }
    }
    // SUPERMUX:end runtime-cli-resilience-muse-review-regressions

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
