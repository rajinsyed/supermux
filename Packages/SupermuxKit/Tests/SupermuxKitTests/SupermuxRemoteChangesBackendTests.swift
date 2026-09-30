import Foundation
import Testing

import SupermuxKit

/// Failure modes of the Changes panel's remote backend (a mirror of a
/// workspace on another Mac), written before the backend itself. Each test
/// names one way the remote path could silently do the wrong thing: act on
/// the wrong workspace or repository, drop files, blank the panel on a
/// transient error, swallow a failed mutation, or leak a watch lease.
@MainActor
@Suite struct SupermuxRemoteChangesBackendTests {
    private static let remoteID = "AAAAAAAA-0000-4000-8000-000000000001"

    // MARK: - Status

    @Test func statusMapsEveryWireKindAndKeepsUnknownKinds() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.status", with: Self.status(
            root: "/remote/repo",
            staged: [["path": "a.txt", "kind": "added"], ["path": "new.txt", "old_path": "old.txt", "kind": "renamed"]],
            unstaged: [["path": "b.txt", "kind": "modified"], ["path": "c.txt", "kind": "something_new"]],
            untracked: [["path": "u.txt", "kind": "untracked"]]
        ))
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        let snapshot = await backend.status(repoPath: "/remote/repo")

        #expect(snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(snapshot.staged.map(\.kind) == [.added, .renamed])
        #expect(snapshot.staged.last?.oldPath == "old.txt")
        // An unknown future kind must still list the file, never drop it.
        #expect(snapshot.unstaged.map(\.path) == ["b.txt", "c.txt"])
        #expect(snapshot.unstaged.last?.kind == .modified)
        #expect(snapshot.untracked.map(\.kind) == [.untracked])
    }

    @Test func statusOfNonRepositoryIsNotARepository() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.status", with: ["is_repository": false, "root": "/remote/plain"])
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        #expect(await backend.status(repoPath: "/remote/plain") == .notARepository)
    }

    @Test func transientStatusFailureKeepsTheLastSnapshot() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)
        transport.fail("mobile.supermux.changes.status")
        #expect(await backend.status(repoPath: "/r") == .notARepository)

        transport.respond("mobile.supermux.changes.status", with: Self.status(
            root: "/r", unstaged: [["path": "b.txt", "kind": "modified"]]
        ))
        let good = await backend.status(repoPath: "/r")
        transport.fail("mobile.supermux.changes.status")
        // A dropped reply must not blank the panel.
        #expect(await backend.status(repoPath: "/r") == good)
    }

    // MARK: - Identity and stale-view guard

    @Test func everyCallIsKeyedByTheRemoteWorkspaceID() async throws {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/r"))
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        _ = await backend.status(repoPath: "/r")
        try await backend.stage(repoPath: "/r", paths: ["x"])
        try await backend.unstage(repoPath: "/r", paths: ["x"])
        _ = await backend.fileDiff(repoPath: "/r", path: "x", oldPath: nil, staged: false)

        #expect(!transport.calls.isEmpty)
        for call in transport.calls {
            #expect(call.params["workspace_id"] as? String == Self.remoteID, "\(call.method)")
        }
    }

    @Test func mutationsPinTheRootTheLastStatusReported() async throws {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        // Before any status, the caller's directory is the only root known.
        try await backend.stage(repoPath: "/shown", paths: ["x"])
        #expect(transport.calls.last?.params["expected_root"] as? String == "/shown")

        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/host/root"))
        _ = await backend.status(repoPath: "/shown")
        try await backend.stage(repoPath: "/shown", paths: ["x"])
        #expect(transport.calls.last?.params["expected_root"] as? String == "/host/root")
    }

    // MARK: - Mutations

    @Test func stageAndUnstageSendPathsOrAll() async throws {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        try await backend.stage(repoPath: "/r", paths: ["a", "b"])
        #expect(transport.calls.last?.method == "mobile.supermux.changes.stage")
        #expect(transport.calls.last?.params["paths"] as? [String] == ["a", "b"])
        try await backend.stageAll(repoPath: "/r")
        #expect(transport.calls.last?.params["all"] as? Bool == true)
        try await backend.unstageAll(repoPath: "/r")
        #expect(transport.calls.last?.method == "mobile.supermux.changes.unstage")
        #expect(transport.calls.last?.params["all"] as? Bool == true)
    }

    @Test func aRejectedMutationThrows() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.fail("mobile.supermux.changes.stage")
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        await #expect(throws: (any Error).self) {
            try await backend.stage(repoPath: "/r", paths: ["a"])
        }
    }

    @Test func discardAllSendsEveryCurrentChangeAndNothingWhenClean() async throws {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.status", with: Self.status(
            root: "/r",
            staged: [["path": "s", "kind": "added"]],
            unstaged: [["path": "m", "kind": "modified"]],
            untracked: [["path": "u", "kind": "untracked"]]
        ))
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        try await backend.discardAll(repoPath: "/r")
        let discard = transport.calls.last { $0.method == "mobile.supermux.changes.discard" }
        #expect(Set(discard?.params["paths"] as? [String] ?? []) == ["s", "m", "u"])

        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/r"))
        let before = transport.calls.filter { $0.method == "mobile.supermux.changes.discard" }.count
        try await backend.discardAll(repoPath: "/r")
        #expect(transport.calls.filter { $0.method == "mobile.supermux.changes.discard" }.count == before)
    }

    @Test func networkMutationsGetTheLongDeadline() async throws {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        try await backend.push(repoPath: "/r", hasUpstream: false)
        try await backend.pull(repoPath: "/r")
        for call in transport.calls {
            #expect((call.timeout ?? .zero) >= .seconds(130), "\(call.method)")
        }
    }

    // MARK: - Diff

    @Test func fileDiffMapsBinaryTextAndFailure() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        transport.respond("mobile.supermux.changes.diff", with: ["path": "a", "diff_text": "@@ -1 +1 @@\n-a\n+b\n", "truncated": true])
        let text = await backend.fileDiff(repoPath: "/r", path: "a", oldPath: nil, staged: true)
        #expect(text.text?.contains("+b") == true)
        #expect(text.truncated)
        #expect(transport.calls.last?.params["staged"] as? Bool == true)

        transport.respond("mobile.supermux.changes.diff", with: ["path": "img", "is_binary": true])
        #expect(await backend.fileDiff(repoPath: "/r", path: "img", oldPath: nil, staged: false).isBinary)

        transport.fail("mobile.supermux.changes.diff")
        let failed = await backend.fileDiff(repoPath: "/r", path: "a", oldPath: nil, staged: false)
        #expect(!failed.isBinary && failed.text == nil)
    }

    // MARK: - History

    @Test func historyFeedsUnpushedAndIncoming() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.history", with: [
            "commits": [
                Self.commit("c3", pushed: false), Self.commit("c2", pushed: false), Self.commit("c1", pushed: true),
            ],
            "incoming": [Self.commit("i2", pushed: true), Self.commit("i1", pushed: true)],
        ])
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        #expect(await backend.unpushedCommits(repoPath: "/r", hasUpstream: true, limit: 10).map(\.hash) == ["c3", "c2"])
        #expect(await backend.unpushedCommits(repoPath: "/r", hasUpstream: true, limit: 1).map(\.hash) == ["c3"])
        #expect(await backend.unpushedCountWithoutUpstream(repoPath: "/r") == 2)
        #expect(await backend.incomingCommits(repoPath: "/r", limit: 1).map(\.hash) == ["i2"])
    }

    @Test func countAndFeedReadsNeverWaitOnAHostFetch() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.history", with: [
            "commits": [Self.commit("c1", pushed: false)], "incoming": [],
        ])
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        _ = await backend.unpushedCountWithoutUpstream(repoPath: "/r")
        _ = await backend.unpushedCommits(repoPath: "/r", hasUpstream: true, limit: 5)
        _ = await backend.incomingCommits(repoPath: "/r", limit: 5)
        let reads = transport.calls.filter { $0.method == "mobile.supermux.changes.history" }
        // Like the local engine, counts come from the last fetch: a refresh on
        // a branch without an upstream must not run `git fetch` over there.
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0.params["fetch"] as? Bool == false })

        // Only the panel's Fetch (and its auto-fetch) asks the host to fetch.
        #expect(await backend.fetch(repoPath: "/r"))
        #expect(transport.calls.last?.method == "mobile.supermux.changes.history")
        #expect(transport.calls.last?.params["fetch"] as? Bool != false)
    }

    // MARK: - Change signals

    @Test func changeSignalsLeaseTheWatcherYieldOnEventsAndReleaseOnCancel() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        let consumer = Task { @MainActor () -> Int in
            var count = 0
            for await _ in backend.changeSignals(repoPath: "/r") {
                count += 1
                if count == 2 { break }
            }
            return count
        }
        await pollUntil { transport.calls.contains { $0.method == "mobile.supermux.changes.watch" && $0.params["enable"] as? Bool == true } }
        transport.emit(.changed)
        transport.emit(.reconnected)
        #expect(await consumer.value == 2)
        await pollUntil { transport.calls.contains { $0.method == "mobile.supermux.changes.watch" && $0.params["enable"] as? Bool == false } }
        let enables = transport.calls.filter { $0.method == "mobile.supermux.changes.watch" && $0.params["enable"] as? Bool == true }
        // A reconnect re-arms the lease (the host forgot it with the link).
        #expect(enables.count >= 2)
        #expect(enables.allSatisfy { $0.params["client_id"] as? String != nil })
    }

    // MARK: - AI commit staleness input

    @Test func uncommittedFingerprintTracksTheStatus() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)

        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/r"))
        #expect(await backend.uncommittedDiff(repoPath: "/r").isEmpty)

        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/r", unstaged: [["path": "a", "kind": "modified"]]))
        let first = await backend.uncommittedDiff(repoPath: "/r")
        transport.respond("mobile.supermux.changes.status", with: Self.status(root: "/r", unstaged: [["path": "b", "kind": "modified"]]))
        let second = await backend.uncommittedDiff(repoPath: "/r")
        #expect(!first.isEmpty && first != second)
    }

    @Test func remoteCommitMessengerAsksTheHostAndStopsOfferingAIAfterUnavailable() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        let backend = SupermuxRemoteChangesBackend(transport: transport)
        let messenger = SupermuxRemoteCommitMessenger(backend: backend)

        transport.respond("mobile.supermux.changes.generate_commit_message", with: ["message": "feat: remote"])
        #expect(await messenger.isConfigured())
        #expect(await messenger.generateMessage(forDiff: "ignored") == "feat: remote")

        transport.fail("mobile.supermux.changes.generate_commit_message", code: "ai_unavailable")
        #expect(await messenger.generateMessage(forDiff: "ignored") == nil)
        #expect(await messenger.isConfigured() == false)
    }

    // MARK: - Through the model

    @Test func theChangesModelListsAndStagesARemoteChange() async {
        let transport = FakeRemoteChangesTransport(remoteWorkspaceID: Self.remoteID)
        transport.respond("mobile.supermux.changes.status", with: Self.status(
            root: "/r", unstaged: [["path": "README.md", "kind": "modified"]]
        ))
        let model = SupermuxChangesModel(backend: SupermuxRemoteChangesBackend(transport: transport))
        model.setDirectory("/r")
        await pollUntil { model.snapshot.unstaged.map(\.path) == ["README.md"] }
        #expect(model.snapshot.unstaged.map(\.path) == ["README.md"])

        transport.respond("mobile.supermux.changes.status", with: Self.status(
            root: "/r", staged: [["path": "README.md", "kind": "modified"]]
        ))
        await model.stage(model.snapshot.unstaged[0])
        #expect(transport.calls.contains { $0.method == "mobile.supermux.changes.stage" })
        #expect(model.snapshot.staged.map(\.path) == ["README.md"])
        #expect(model.lastError == nil)

        let patch = await model.fileDiffPatch(for: model.snapshot.staged[0], staged: true)
        #expect(patch == nil || patch?.isRemote == true)
    }

    // MARK: - Fixtures

    private static func status(
        root: String,
        staged: [[String: Any]] = [],
        unstaged: [[String: Any]] = [],
        untracked: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "workspace_id": remoteID, "is_repository": true, "branch": "main",
            "ahead": 0, "behind": 0, "staged": staged, "unstaged": unstaged,
            "untracked": untracked, "stash_count": 0, "root": root,
        ]
    }

    private static func commit(_ sha: String, pushed: Bool) -> [String: Any] {
        ["sha": sha, "short_sha": sha, "author": "a", "relative_date": "now", "subject": sha, "is_pushed": pushed]
    }

    private func pollUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Scripted stand-in for the device link: canned replies per method, recorded
/// calls, and a manual event feed.
@MainActor
final class FakeRemoteChangesTransport: SupermuxRemoteChangesTransport {
    struct Call {
        let method: String
        let params: [String: Any]
        let timeout: Duration?
    }

    struct Rejected: Error {
        let code: String
    }

    let remoteWorkspaceID: String
    private(set) var calls: [Call] = []
    private var replies: [String: [String: Any]] = [:]
    private var failures: [String: String] = [:]
    private var continuations: [AsyncStream<SupermuxRemoteChangesEvent>.Continuation] = []

    init(remoteWorkspaceID: String) {
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    func respond(_ method: String, with reply: [String: Any]) {
        failures[method] = nil
        replies[method] = reply
    }

    func fail(_ method: String, code: String = "unavailable") {
        failures[method] = code
    }

    func emit(_ event: SupermuxRemoteChangesEvent) {
        for continuation in continuations { continuation.yield(event) }
    }

    func request(_ method: String, params: [String: Any], timeout: Duration?) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params, timeout: timeout))
        if let code = failures[method] { throw Rejected(code: code) }
        return replies[method] ?? ["ok": true]
    }

    func errorCode(_ error: any Error) -> String? {
        (error as? Rejected)?.code
    }

    func events() -> AsyncStream<SupermuxRemoteChangesEvent> {
        AsyncStream { continuation in continuations.append(continuation) }
    }
}
