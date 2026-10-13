// SUPERMUX:begin runtime-ssh-tmux-regressions
#if RUNTIME_SSH_TMUX_HARNESS
import Foundation
import Testing

struct RuntimeSshTmuxTests {
    private func withFixture(_ body: (LocalTmuxSessionRegistry, LocalTmuxSessionIdentityResolver, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-tmux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-tmux")
        let script = """
        #!/bin/sh
        root="$(dirname "$0")"
        case "$3" in
          has-session) test -f "$root/live"; exit $? ;;
          display-message) cat "$root/observed"; exit $? ;;
          set-option) exit 0 ;;
          *) exit 2 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = LocalTmuxSessionRegistry(rootURL: directory.appendingPathComponent("state"))
        let resolver = LocalTmuxSessionIdentityResolver(
            registry: registry,
            builder: LocalTmuxCommandBuilder(tmuxPath: executable.path, socketPath: registry.serverSocketURL.path),
            runner: LocalTmuxProcessRunner(executablePath: executable.path)
        )
        try body(registry, resolver, directory)
    }

    private func binding(serverID: UUID = UUID(), created: UInt64 = 1) -> LocalTmuxSessionBinding {
        LocalTmuxSessionBinding(sessionID: LocalTmuxSessionIdentity("$0")!, serverID: serverID, sessionCreated: created)
    }

    private func observe(_ binding: LocalTmuxSessionBinding, in directory: URL) throws {
        try "work\t\(binding.sessionID.rawValue)\t\(binding.serverID.uuidString)\t\(binding.sessionCreated)\n"
            .write(to: directory.appendingPathComponent("observed"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("live"))
    }

    @Test func serverRestartCanReuseSessionID() throws {
        try withFixture { registry, resolver, directory in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            let replacement = binding()
            try observe(replacement, in: directory)
            let live = try resolver.rebindStopped(record, to: .init(name: "work", binding: replacement))
            #expect(live.record.id == record.id)
            #expect(live.binding == replacement)
            #expect(try registry.load().first?.tmuxBinding == replacement)
        }
    }

    @Test func recreationCanReuseSessionIDInSameServer() throws {
        try withFixture { registry, resolver, directory in
            let old = binding()
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: old, socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            let replacement = binding(serverID: old.serverID, created: old.sessionCreated + 1)
            try observe(replacement, in: directory)
            #expect(try resolver.rebindStopped(record, to: .init(name: "work", binding: replacement)).binding == replacement)
        }
    }

    @Test func identicalIncarnationIsStillLive() throws {
        try withFixture { registry, resolver, directory in
            let old = binding()
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: old, socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            try observe(old, in: directory)
            #expect(throws: CLIError.self) {
                try resolver.rebindStopped(record, to: .init(name: "work", binding: binding()))
            }
            #expect(try registry.load() == [record])
        }
    }

    @Test func staleRebindPreservesCurrentWorkspaceAndInvalidatesOldSurface() throws {
        try withFixture { registry, resolver, _ in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp",
                                               workspaceID: "W1", workspaceTitle: "T1", surfaceID: "S1")
            try registry.upsert(record)
            let initial = try #require(registry.load().first)
            // Deterministic interleaving after initial load, not a scheduling delay.
            let beforeRebind = {
                try registry.recordAttachment(id: record.id, workspaceID: "W2", workspaceTitle: "T2", surfaceID: "S2")
            }
            #expect(try beforeRebind())
            let replacement = binding()
            let live = try resolver.rebindStopped(initial, to: .init(name: "work", binding: replacement))
            #expect(live.record.workspaceID == "W2")
            #expect(live.record.workspaceTitle == "T2")
            #expect(live.record.surfaceID == nil)
            #expect(try registry.load() == [live.record])
        }
    }

    @Test func staleRebindCannotOverwriteUnexpectedBinding() throws {
        try withFixture { registry, resolver, _ in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            var concurrent = record
            concurrent.tmuxBinding = binding()
            try registry.upsert(concurrent)
            #expect(throws: (any Error).self) {
                try resolver.rebindStopped(record, to: .init(name: "work", binding: binding()))
            }
            #expect(try registry.load() == [concurrent])
        }
    }

    @Test func staleRebindCannotResurrectRemovedOwner() throws {
        try withFixture { registry, resolver, _ in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            _ = try registry.remove(id: record.id)
            #expect(throws: (any Error).self) {
                try resolver.rebindStopped(record, to: .init(name: "work", binding: binding()))
            }
            #expect(try registry.load().isEmpty)
        }
    }

    @Test func duplicateNameAndBindingOwnersAreRejected() throws {
        try withFixture { registry, resolver, _ in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            let owner = LocalTmuxSessionRecord(name: "other", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            try registry.upsert(owner)
            #expect(throws: (any Error).self) {
                try resolver.rebindStopped(record, to: .init(name: "other", binding: binding()))
            }
            #expect(throws: (any Error).self) {
                try resolver.rebindStopped(record, to: .init(name: "work", binding: owner.tmuxBinding!))
            }
            #expect(try registry.load().count == 2)
        }
    }

    @Test func unchangedBindingKeepsCurrentAttachment() throws {
        try withFixture { registry, resolver, _ in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            #expect(try registry.recordAttachment(id: record.id, workspaceID: "W2", workspaceTitle: "T2", surfaceID: "S2"))
            let live = try resolver.bind(record, to: .init(name: "work", binding: record.tmuxBinding!))
            #expect(live.record.surfaceID == "S2")
            #expect(live.record.workspaceID == "W2")
            #expect(try registry.load() == [live.record])
        }
    }

    @Test func corruptObservedBindingFailsClosed() throws {
        try withFixture { registry, resolver, directory in
            let record = LocalTmuxSessionRecord(name: "work", tmuxBinding: binding(), socketPath: "socket", cwd: "/tmp")
            try registry.upsert(record)
            try Data().write(to: directory.appendingPathComponent("live"))
            try "work\t$0\tbogus\t1\n".write(to: directory.appendingPathComponent("observed"), atomically: true, encoding: .utf8)
            #expect(throws: CLIError.self) {
                try resolver.rebindStopped(record, to: .init(name: "work", binding: binding()))
            }
            #expect(try registry.load() == [record])
        }
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-regressions
