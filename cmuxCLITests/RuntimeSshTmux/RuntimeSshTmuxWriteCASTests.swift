// SUPERMUX:begin runtime-ssh-tmux-write-cas-regressions
#if RUNTIME_SSH_TMUX_HARNESS
import Foundation
import Testing

struct RuntimeSshTmuxWriteCASTests {
    private func withFixture(_ body: (LocalTmuxSessionRegistry, LocalTmuxSessionIdentityResolver) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmux-cas-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = LocalTmuxSessionRegistry(rootURL: directory)
        let builder = LocalTmuxCommandBuilder(tmuxPath: "/usr/bin/false", socketPath: registry.serverSocketURL.path)
        try body(registry, LocalTmuxSessionIdentityResolver(
            registry: registry, builder: builder, runner: LocalTmuxProcessRunner(executablePath: builder.tmuxPath)
        ))
    }

    private func binding() -> LocalTmuxSessionBinding {
        LocalTmuxSessionBinding(sessionID: LocalTmuxSessionIdentity("$0")!, serverID: UUID(), sessionCreated: 1)
    }

    private func record(binding: LocalTmuxSessionBinding? = nil) -> LocalTmuxSessionRecord {
        LocalTmuxSessionRecord(name: "work", tmuxBinding: binding, socketPath: "old-socket", cwd: "/old",
                               workspaceID: "W-A", workspaceTitle: "Title A", surfaceID: "S-A")
    }

    @Test func discoveryFinalWriteCannotReplaceReboundOwner() throws {
        try withFixture { registry, resolver in
            let original = record(binding: binding())
            try registry.upsert(original)
            let discoveredA = try resolver.bind(original, to: .init(name: "renamed-A", binding: original.tmuxBinding!))
            let b = try registry.compareAndRebind(id: original.id, expectedBinding: discoveredA.binding,
                                                  name: "renamed-B", binding: binding())
            #expect(throws: (any Error).self) {
                try CMUXCLI().persistLocalTmuxLocation(record: discoveredA.record, registry: registry,
                                                       socketPath: "A-socket", cwd: "/A")
            }
            #expect(try registry.load() == [b])
        }
    }

    @Test func discoveryFinalWriteCannotResurrectRemovedOwner() throws {
        try withFixture { registry, resolver in
            let original = record(binding: binding())
            try registry.upsert(original)
            let discoveredA = try resolver.bind(original, to: .init(name: "work", binding: original.tmuxBinding!))
            _ = try registry.remove(id: original.id)
            #expect(throws: (any Error).self) {
                try CMUXCLI().persistLocalTmuxLocation(record: discoveredA.record, registry: registry,
                                                       socketPath: "A-socket", cwd: "/A")
            }
            #expect(try registry.load().isEmpty)
        }
    }

    @Test func discoveryLocationPreservesSameIncarnationAttachment() throws {
        try withFixture { registry, resolver in
            let original = record(binding: binding())
            try registry.upsert(original)
            let discoveredA = try resolver.bind(original, to: .init(name: "work", binding: original.tmuxBinding!))
            try attach(discoveredA.record, registry: registry, workspace: "W-current", surface: "S-current")
            _ = try registry.compareAndRebind(id: original.id, expectedBinding: original.tmuxBinding,
                                              name: "current-name", binding: original.tmuxBinding!)
            let updated = try CMUXCLI().persistLocalTmuxLocation(record: discoveredA.record, registry: registry,
                                                                 socketPath: "new-socket", cwd: nil)
            #expect(updated.name == "current-name")
            #expect(updated.workspaceID == "W-current")
            #expect(updated.workspaceTitle == "Title W-current")
            #expect(updated.surfaceID == "S-current")
            #expect(updated.cwd == "/old")
            #expect(updated.socketPath == "new-socket")
            #expect(try registry.load() == [updated])
        }
    }

    @Test func pendingLocationCannotOverwriteNewBinding() throws {
        try withFixture { registry, _ in
            let pending = record()
            try registry.upsert(pending)
            let bound = try registry.compareAndRebind(id: pending.id, expectedBinding: nil, name: "work", binding: binding())
            #expect(throws: (any Error).self) {
                try CMUXCLI().persistLocalTmuxLocation(record: pending, registry: registry, socketPath: "stale", cwd: "/stale")
            }
            #expect(try registry.load() == [bound])
        }
    }

    @Test func pendingLocationCannotResurrectRemovedOwner() throws {
        try withFixture { registry, _ in
            let pending = record()
            try registry.upsert(pending)
            _ = try registry.remove(id: pending.id)
            #expect(throws: (any Error).self) {
                try CMUXCLI().persistLocalTmuxLocation(record: pending, registry: registry, socketPath: "stale", cwd: nil)
            }
            #expect(try registry.load().isEmpty)
        }
    }

    @Test func unchangedPendingLocationStillUpdates() throws {
        try withFixture { registry, _ in
            let pending = record()
            try registry.upsert(pending)
            let updated = try CMUXCLI().persistLocalTmuxLocation(record: pending, registry: registry,
                                                                 socketPath: "current", cwd: "/current")
            #expect(updated.tmuxBinding == nil)
            #expect(updated.socketPath == "current")
            #expect(updated.cwd == "/current")
            #expect(updated.workspaceID == pending.workspaceID)
            #expect(try registry.load() == [updated])
        }
    }

    @Test func delayedAttachmentCannotOverwriteReboundAttachment() throws {
        try withFixture { registry, _ in
            let a = record(binding: binding())
            try registry.upsert(a)
            var expectedB: LocalTmuxSessionRecord?
            try attach(a, registry: registry, workspace: "W-A", surface: "S-late-A") {
                let b = try registry.compareAndRebind(id: a.id, expectedBinding: a.tmuxBinding,
                                                      name: "work-B", binding: binding())
                try attach(b, registry: registry, workspace: "W-B", surface: "S-B")
                let current: LocalTmuxSessionRecord = try #require(registry.load().first)
                expectedB = current
            }
            let b = try #require(expectedB)
            #expect(try registry.load() == [b])
            #expect(b.workspaceID == "W-B")
            #expect(b.workspaceTitle == "Title W-B")
            #expect(b.surfaceID == "S-B")
        }
    }

    @Test func delayedAttachmentCannotResurrectRemovedOwner() throws {
        try withFixture { registry, _ in
            let a = record(binding: binding())
            try registry.upsert(a)
            try attach(a, registry: registry, workspace: "W-A", surface: "S-late-A") {
                _ = try registry.remove(id: a.id)
            }
            #expect(try registry.load().isEmpty)
        }
    }

    @Test func sameBindingAttachmentPreservesCurrentRenameAndLocation() throws {
        try withFixture { registry, _ in
            let a = record(binding: binding())
            try registry.upsert(a)
            try attach(a, registry: registry, workspace: "W-current", surface: "S-current") {
                _ = try registry.compareAndRebind(id: a.id, expectedBinding: a.tmuxBinding,
                                                  name: "current-name", binding: a.tmuxBinding!)
                _ = try CMUXCLI().persistLocalTmuxLocation(record: registry.load()[0], registry: registry,
                                                           socketPath: "current-socket", cwd: "/current")
            }
            let current = try #require(registry.load().first)
            #expect(current.name == "current-name")
            #expect(current.socketPath == "current-socket")
            #expect(current.cwd == "/current")
            #expect(current.workspaceID == "W-current")
            #expect(current.surfaceID == "S-current")
        }
    }

    @Test func unboundPersistentAttachmentRetainsSharedProfileSemantics() throws {
        try withFixture { registry, _ in
            let unbound = record()
            try registry.upsert(unbound)
            try attach(unbound, registry: registry, workspace: "W-zellij", surface: "S-zellij", profile: .localZellij)
            let current = try #require(registry.load().first)
            #expect(current.tmuxBinding == nil)
            #expect(current.workspaceID == "W-zellij")
            #expect(current.surfaceID == "S-zellij")
        }
    }

    private func attach(_ record: LocalTmuxSessionRecord, registry: LocalTmuxSessionRegistry,
                        workspace: String, surface: String, profile: LocalSessionAttachProfile = .localTmux,
                        beforeReply: () throws -> Void = {}) throws {
        var surfaceCalls = 0
        // The callback is a synchronous gate: the replacement commits before
        // the delayed A reply is returned to the real attachment consumer.
        try withoutActuallyEscaping(beforeReply) { beforeReply in
            let client = SocketClient { method, params in
                switch method {
                case "window.list": return ["windows": [["id": "window"]]]
                case "workspace.list": return ["workspaces": [["id": workspace, "title": "Title " + workspace]]]
                case "surface.create":
                    surfaceCalls += 1
                    #expect(params["workspace_id"] as? String == workspace)
                    try beforeReply()
                    return ["workspace_id": workspace, "surface_id": surface]
                default: throw CLIError(message: "Unexpected fixture request: " + method)
                }
            }
            let request = LocalSessionAttachRequest(workspace: workspace, newClient: true)
            if profile.mode == "local-tmux", let binding = record.tmuxBinding {
                let invocation = try LocalTmuxInvocation.parse(["attach", "work", "--workspace", workspace, "--new-client"])
                try CMUXCLI().attachLocalTmuxSession(session: .init(record: record, binding: binding),
                    invocation: invocation, registry: registry,
                    builder: LocalTmuxCommandBuilder(tmuxPath: "/usr/bin/false", socketPath: "fixture-socket"),
                    client: client, jsonOutput: true, idFormat: .uuids)
            } else {
                try CMUXCLI().attachLocalPersistentSession(record: record, attachCommand: "fixture", socketPath: "fixture-socket",
                    request: request, profile: profile, registry: registry, client: client, jsonOutput: true, idFormat: .uuids)
            }
        }
        #expect(surfaceCalls == 1)
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-write-cas-regressions
