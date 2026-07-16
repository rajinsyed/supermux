import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-04 for changes: store state transitions correctly on
/// stage/unstage/discard actions (exact §2 wire calls asserted against the
/// fake's recording), a `supermux.changes.updated` poke for THIS workspace
/// refetches the status, and the `expected_root` stale-view pin travels on
/// every mutation. The watch heartbeat/ordering/client-id tests live in
/// `SupermuxMobileChangesStoreWatchTests.swift` (file-length budget).
@MainActor
@Suite struct SupermuxMobileChangesStoreTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"

    private static let statusA = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main",
        upstreamBranch: "origin/main",
        ahead: 1,
        behind: 2,
        staged: [SupermuxChangedFileDTO(path: "staged.txt", kind: "added")],
        unstaged: [SupermuxChangedFileDTO(path: "src/app.swift", kind: "modified")],
        untracked: [SupermuxChangedFileDTO(path: "notes.md", kind: "untracked")],
        stashCount: 1
    )

    private static let statusB = SupermuxChangesStatusDTO(
        workspaceId: workspaceID,
        isRepository: true,
        branch: "main",
        staged: [
            SupermuxChangedFileDTO(path: "staged.txt", kind: "added"),
            SupermuxChangedFileDTO(path: "src/app.swift", kind: "modified"),
        ],
        unstaged: [],
        untracked: [SupermuxChangedFileDTO(path: "notes.md", kind: "untracked")]
    )

    private static let changesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.changesV1.rawValue]
    )

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = changesOnly,
        heartbeatSleep: ((Duration) async -> Void)? = nil
    ) -> SupermuxMobileChangesStore {
        SupermuxMobileChangesStore(
            client: fake,
            capabilities: capabilities,
            workspaceID: Self.workspaceID,
            idleSleep: { _ in await Task.yield() },
            heartbeatSleep: heartbeatSleep ?? { _ in
                // Park forever (until cancelled) so heartbeat-agnostic tests
                // observe exactly one initial watch call.
                try? await Task.sleep(for: .seconds(3600))
            }
        )
    }

    // MARK: Status sync + event-driven refetch

    @Test func syncsStatusThenRefetchesOnMatchingChangesUpdated() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.status == Self.statusA)
        // Subscribe-before-fetch, on exactly the changes topic.
        #expect(fake.subscribedTopicSets.first == [.changesUpdated])
        let eventsIndex = try #require(fake.callLog.firstIndex(of: "events"))
        let statusIndex = try #require(fake.callLog.firstIndex(of: "changesStatus"))
        #expect(eventsIndex < statusIndex)
        // §2 exact wire shape for the fetch.
        let statusCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.status" }
        )
        #expect(statusCall.params == ["workspace_id": Self.workspaceID] as NSDictionary)

        // A poke for THIS workspace refetches…
        fake.changesStatusResponse = Self.statusB
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: Self.workspaceID))
        try await TestWait().until { store.status == Self.statusB }
        #expect(fake.changesStatusCallCount == 2)
    }

    @Test func ignoresChangesUpdatedForOtherWorkspaces() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: "SOME-OTHER-WORKSPACE"))
        // Give the event a chance to (wrongly) trigger a refetch.
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusA)
    }

    @Test func fetchFailureSurfacesErrorAndNextEventRecovers() async throws {
        struct Boom: Error {}
        let fake = FakeSupermuxMacClient()
        fake.changesStatusError = Boom()
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.lastErrorDescription != nil }
        #expect(!store.hasLoaded)

        fake.changesStatusError = nil
        fake.changesStatusResponse = Self.statusA
        fake.emit(SupermuxMobileEvent(topic: .changesUpdated, workspaceID: Self.workspaceID))
        try await TestWait().until { store.hasLoaded }
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: Capability gate

    @Test func withoutChangesCapabilityTheStoreIsInert() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: ["workspace.groups.v1"])
        )
        #expect(!store.showsChanges)
        await store.run()
        #expect(fake.callLog.isEmpty)
        #expect(store.status == nil)
    }

    // MARK: UI-04 — stage/unstage/discard state transitions + exact wire shapes

    @Test func stageSendsTheExactStageWireCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.stage(paths: ["src/app.swift"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.stage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/app.swift"],
        ] as NSDictionary)
        // The store refetches right after the mutation so the sections move
        // without waiting for the Mac's poke.
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusB)
        #expect(!store.isMutating)
    }

    @Test func stageAllSendsAllTrue() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.stageAll()
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.stage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "all": true,
        ] as NSDictionary)
    }

    @Test func unstageSendsTheExactUnstageWireCall() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        let store = makeStore(fake: fake)

        await store.unstage(paths: ["staged.txt"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.unstage")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["staged.txt"],
        ] as NSDictionary)
        #expect(store.status == Self.statusA)
    }

    @Test func discardSendsTheExactDiscardWireCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusB
        let store = makeStore(fake: fake)

        await store.discard(paths: ["src/app.swift"])
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.discard")
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/app.swift"],
        ] as NSDictionary)
        #expect(fake.changesStatusCallCount == 1)
        #expect(store.status == Self.statusB)
    }

    @Test func mutationFailureSurfacesErrorAndUnblocksFurtherActions() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStageError = MobileShellConnectionError.rpcError(
            "not_found", "Unknown path"
        )
        let store = makeStore(fake: fake)

        await store.stage(paths: ["ghost.txt"])
        #expect(store.lastErrorDescription != nil)
        #expect(!store.isMutating)
        // No refetch after a failed mutation.
        #expect(fake.changesStatusCallCount == 0)

        // The next successful action clears the error.
        fake.changesStageError = nil
        fake.changesStatusResponse = Self.statusA
        await store.stage(paths: ["notes.md"])
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: Stale-view mutation pin (expected_root)

    @Test func mutationsOmitExpectedRootBeforeAnyStatusArrives() async throws {
        // No status has ever been decoded (or the Mac is old and omits
        // `root`): the pin must be OMITTED, not sent as null/empty —
        // otherwise an old Mac's handler would reject valid mutations.
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA // no root
        let store = makeStore(fake: fake)

        await store.stage(paths: ["src/app.swift"])
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/app.swift"],
        ] as NSDictionary)

        // The refetched status ALSO carried no root (old Mac) — the next
        // mutation still omits the pin.
        await store.unstage(paths: ["staged.txt"])
        let unstageCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.unstage" }
        )
        #expect(unstageCall.params == [
            "workspace_id": Self.workspaceID,
            "paths": ["staged.txt"],
        ] as NSDictionary)
    }

    @Test func mutationsCarryTheStatusReportedRootAsExpectedRoot() async throws {
        let root = "/Users/dev/repo"
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = SupermuxChangesStatusDTO(
            workspaceId: Self.workspaceID,
            isRepository: true,
            branch: "main",
            root: root
        )
        let store = makeStore(fake: fake)
        // The first mutation's refetch captures the root; every subsequent
        // mutation pins against it.
        await store.stage(paths: ["a.txt"])

        await store.unstage(paths: ["b.txt"])
        let unstageCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.unstage" }
        )
        #expect(unstageCall.params == [
            "workspace_id": Self.workspaceID,
            "paths": ["b.txt"],
            "expected_root": root,
        ] as NSDictionary)

        await store.discard(paths: ["c.txt"])
        let discardCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.discard" }
        )
        #expect(discardCall.params == [
            "workspace_id": Self.workspaceID,
            "paths": ["c.txt"],
            "expected_root": root,
        ] as NSDictionary)

        store.commitMessage = "feat: pinned commit"
        await store.commit()
        let commitCall = try #require(
            fake.recordedWireCalls.first { $0.method == "mobile.supermux.changes.commit" }
        )
        #expect(commitCall.params == [
            "workspace_id": Self.workspaceID,
            "message": "feat: pinned commit",
            "expected_root": root,
        ] as NSDictionary)
    }

    @Test func staleRootRejectionSurfacesTheErrorAndRefetchesTheStatus() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = SupermuxChangesStatusDTO(
            workspaceId: Self.workspaceID,
            isRepository: true,
            branch: "main",
            root: "/Users/dev/new-repo"
        )
        fake.changesStageError = MobileShellConnectionError.rpcError(
            "stale_root", "Workspace directory changed; refresh and retry"
        )
        let store = makeStore(fake: fake)

        await store.stage(paths: ["a.txt"])
        // Never a silent no-op: the message surfaces AND the stale view
        // refetches (which also re-captures the fresh root for a retry).
        #expect(store.lastErrorDescription != nil)
        #expect(fake.changesStatusCallCount == 1, "a stale_root rejection must trigger a status refetch")
        #expect(store.status?.root == "/Users/dev/new-repo")
        #expect(!store.isMutating)

        // The retry pins against the refreshed root.
        fake.changesStageError = nil
        await store.stage(paths: ["a.txt"])
        let retryCall = try #require(
            fake.recordedWireCalls.last { $0.method == "mobile.supermux.changes.stage" }
        )
        #expect(retryCall.params == [
            "workspace_id": Self.workspaceID,
            "paths": ["a.txt"],
            "expected_root": "/Users/dev/new-repo",
        ] as NSDictionary)
    }

    // MARK: Diff fetch

    @Test func loadDiffSendsTheExactDiffWireCallAndReturnsTheFixture() async throws {
        let fake = FakeSupermuxMacClient()
        let fixture = SupermuxDiffDTO(
            path: "src/app.swift",
            isBinary: false,
            diffText: "@@ -1 +1 @@\n-old\n+new",
            truncated: false
        )
        fake.changesDiffResponse = fixture
        let store = makeStore(fake: fake)

        let unstagedDiff = try await store.loadDiff(path: "src/app.swift", staged: false)
        #expect(unstagedDiff == fixture)
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.changes.diff")
        // `staged` is omitted when false (the Mac defaults it to false).
        #expect(fake.recordedWireCalls[0].params == [
            "workspace_id": Self.workspaceID,
            "path": "src/app.swift",
        ] as NSDictionary)

        _ = try await store.loadDiff(path: "staged.txt", staged: true)
        #expect(fake.recordedWireCalls[1].params == [
            "workspace_id": Self.workspaceID,
            "path": "staged.txt",
            "staged": true,
        ] as NSDictionary)
    }

    // MARK: Request-generation race guard (#5)

    @Test func aStaleStatusResponseNeverOverwritesAFresherOne() async throws {
        let fake = FakeSupermuxMacClient()
        fake.changesStatusResponse = Self.statusA
        // Hold the very next `changesStatus` call — this becomes `run()`'s
        // initial (OLDER) refetch.
        fake.changesStatusShouldHoldNextCall = true
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }
        try await TestWait().until { fake.changesStatusGate.hasParked }

        // A concurrent mutation's refetch (e.g. a stage the user made while
        // the older request was still in flight) is NOT held and lands
        // first, with FRESHER content.
        fake.changesStatusResponse = Self.statusB
        await store.stage(paths: ["src/app.swift"])
        #expect(store.status == Self.statusB)

        // The older, held request finally resolves with its (now stale)
        // snapshot — it must never overwrite the fresher response that
        // already landed.
        fake.changesStatusGate.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.status == Self.statusB)
    }

    // MARK: Response wire decoding (snake_case + unknown-field tolerance)

    @Test func watchAndAckResponsesDecodeFromWireJSON() throws {
        let watchJSON = Data(#"{"watching":true,"ttl_seconds":120,"future_field":1}"#.utf8)
        let watch = try JSONDecoder().decode(SupermuxChangesWatchResponse.self, from: watchJSON)
        #expect(watch.watching == true)
        #expect(watch.ttlSeconds == 120)

        let ackJSON = Data(#"{"ok":true,"future_field":"x"}"#.utf8)
        let ack = try JSONDecoder().decode(SupermuxChangesAckResponse.self, from: ackJSON)
        #expect(ack.ok == true)
    }
}
