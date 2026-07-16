import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-05: against a fake client with a fixture tree, the file-browser store
/// navigates, creates, renames, duplicates, and trashes with the exact §2
/// wire calls (method + params NSDictionary-pinned via the fake's recording)
/// and refetches the CURRENT directory's listing after every mutation.
@MainActor
@Suite struct SupermuxMobileFileBrowserStoreTests {
    private static let workspaceID = "7B1D4C22-9F3A-4E0D-B7A1-5C6E8F0A2D33"
    private static let projectID = "11111111-1111-1111-1111-111111111111"

    private static let filesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.filesV1.rawValue]
    )

    /// The m5-f1 fixture shape: root with a directory + file, one nested level.
    private func seedFixtureTree(_ fake: FakeSupermuxMacClient) {
        fake.filesTree = [
            "": [
                SupermuxFileEntryDTO(name: "src", isDir: true, isSymlink: false),
                SupermuxFileEntryDTO(name: "notes.md", isDir: false, isSymlink: false, size: 12),
            ],
            "src": [
                SupermuxFileEntryDTO(name: "nested", isDir: true, isSymlink: false),
                SupermuxFileEntryDTO(name: "main.swift", isDir: false, isSymlink: false, size: 0),
            ],
            "src/nested": [],
        ]
    }

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = filesOnly,
        root: SupermuxFilesRoot = .workspace(id: workspaceID)
    ) -> SupermuxMobileFileBrowserStore {
        SupermuxMobileFileBrowserStore(client: fake, capabilities: capabilities, root: root)
    }

    /// The fake's recorded `files.*` wire calls, in call order.
    private func filesCalls(_ fake: FakeSupermuxMacClient) -> [(method: String, params: NSDictionary)] {
        fake.recordedWireCalls.filter { $0.method.hasPrefix("mobile.supermux.files.") }
    }

    // MARK: Navigation

    @Test func loadListsTheRootWithoutAPathParam() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)

        await store.load()

        #expect(store.hasLoaded)
        #expect(store.pathSegments.isEmpty)
        #expect(store.entries.map(\.name) == ["src", "notes.md"])
        let calls = filesCalls(fake)
        #expect(calls.map(\.method) == ["mobile.supermux.files.list"])
        #expect(calls[0].params == ["workspace_id": Self.workspaceID])
    }

    @Test func projectRootedStoreSendsProjectID() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake, root: .project(id: Self.projectID))

        await store.load()

        #expect(filesCalls(fake)[0].params == ["project_id": Self.projectID])
    }

    @Test func navigateIntoADirectoryListsItAndExtendsTheBreadcrumb() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        await store.navigate(into: "src")

        #expect(store.pathSegments == ["src"])
        #expect(store.currentPath == "src")
        #expect(store.entries.map(\.name) == ["nested", "main.swift"])
        let calls = filesCalls(fake)
        #expect(calls.last?.method == "mobile.supermux.files.list")
        #expect(calls.last?.params == ["workspace_id": Self.workspaceID, "path": "src"])
    }

    @Test func breadcrumbNavigationTruncatesToTheTappedDepth() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        await store.navigate(into: "src")
        await store.navigate(into: "nested")
        #expect(store.pathSegments == ["src", "nested"])

        await store.navigate(toDepth: 1)
        #expect(store.pathSegments == ["src"])
        #expect(store.entries.map(\.name) == ["nested", "main.swift"])

        await store.navigate(toDepth: 0)
        #expect(store.pathSegments.isEmpty)
        #expect(filesCalls(fake).last?.params == ["workspace_id": Self.workspaceID])
    }

    @Test func aFailedNavigationKeepsTheCurrentDirectoryAndSurfacesTheError() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        fake.filesListError = MobileShellConnectionError.rpcError(
            "not_found", "No such directory"
        )
        await store.navigate(into: "src")

        #expect(store.pathSegments.isEmpty, "a failed navigation must not commit the new path")
        #expect(store.entries.map(\.name) == ["src", "notes.md"])
        #expect(store.lastErrorDescription != nil)

        // The next successful refresh clears the error.
        fake.filesListError = nil
        await store.refresh()
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: Mutations refetch the listing (UI-05)

    @Test func createFileSendsTheExactCallAndRefetchesTheListing() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        await store.navigate(into: "src")

        try await store.createFile(named: "new.swift")

        let calls = filesCalls(fake).suffix(2)
        #expect(calls.map(\.method) == [
            "mobile.supermux.files.create",
            "mobile.supermux.files.list",
        ])
        #expect(calls.first?.params == [
            "workspace_id": Self.workspaceID,
            "path": "src/new.swift",
            "kind": "file",
        ])
        #expect(calls.last?.params == ["workspace_id": Self.workspaceID, "path": "src"])
        #expect(store.entries.map(\.name).contains("new.swift"), "the refetched listing shows the new file")
    }

    @Test func createFolderAtTheRootSendsARootRelativePath() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        try await store.createFolder(named: "Docs")

        let calls = filesCalls(fake).suffix(2)
        #expect(calls.first?.method == "mobile.supermux.files.create")
        #expect(calls.first?.params == [
            "workspace_id": Self.workspaceID,
            "path": "Docs",
            "kind": "folder",
        ])
        #expect(calls.last?.method == "mobile.supermux.files.list")
        #expect(store.entries.map(\.name).contains("Docs"))
    }

    @Test func renameSendsTheExactCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        await store.navigate(into: "src")

        try await store.rename(entryNamed: "main.swift", to: "renamed.swift")

        let calls = filesCalls(fake).suffix(2)
        #expect(calls.map(\.method) == [
            "mobile.supermux.files.rename",
            "mobile.supermux.files.list",
        ])
        #expect(calls.first?.params == [
            "workspace_id": Self.workspaceID,
            "path": "src/main.swift",
            "new_name": "renamed.swift",
        ])
        #expect(store.entries.map(\.name).contains("renamed.swift"))
        #expect(!store.entries.map(\.name).contains("main.swift"))
    }

    @Test func duplicateSendsTheExactCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        try await store.duplicate(entryNamed: "notes.md")

        let calls = filesCalls(fake).suffix(2)
        #expect(calls.map(\.method) == [
            "mobile.supermux.files.duplicate",
            "mobile.supermux.files.list",
        ])
        #expect(calls.first?.params == [
            "workspace_id": Self.workspaceID,
            "path": "notes.md",
        ])
        #expect(store.entries.count == 3, "the refetched listing shows the copy")
    }

    @Test func trashSendsOneBatchCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        await store.navigate(into: "src")

        try await store.trash(entryNames: ["nested", "main.swift"])

        let calls = filesCalls(fake).suffix(2)
        #expect(calls.map(\.method) == [
            "mobile.supermux.files.trash",
            "mobile.supermux.files.list",
        ])
        #expect(calls.first?.params == [
            "workspace_id": Self.workspaceID,
            "paths": ["src/nested", "src/main.swift"],
        ])
        #expect(store.entries.isEmpty, "the refetched listing no longer shows the trashed entries")
    }

    @Test func trashWithNoEntriesIsANoOp() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        let callCountAfterLoad = filesCalls(fake).count

        try await store.trash(entryNames: [])

        #expect(filesCalls(fake).count == callCountAfterLoad)
    }

    // MARK: Error paths

    @Test func aFailedMutationRethrowsAndDoesNotRefetch() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        fake.filesCreateError = MobileShellConnectionError.rpcError(
            "invalid_params", "Path escapes the resolved root"
        )
        await #expect(throws: (any Error).self) {
            try await store.createFile(named: "evil.txt")
        }

        let calls = filesCalls(fake)
        #expect(calls.last?.method == "mobile.supermux.files.create")
        #expect(store.isMutating == false)
    }

    @Test func anInvalidNameNeverReachesTheWire() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()
        let callCountAfterLoad = filesCalls(fake).count

        await #expect(throws: SupermuxInvalidFileNameError.self) {
            try await store.createFile(named: "a/b")
        }
        await #expect(throws: SupermuxInvalidFileNameError.self) {
            try await store.rename(entryNamed: "notes.md", to: "   ")
        }
        await #expect(throws: SupermuxInvalidFileNameError.self) {
            try await store.createFolder(named: "..")
        }

        #expect(filesCalls(fake).count == callCountAfterLoad)
    }

    @Test func namesAreTrimmedBeforeTheyTravel() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(fake: fake)
        await store.load()

        try await store.createFile(named: "  spaced.md ")

        #expect(filesCalls(fake).dropFirst().first?.params == [
            "workspace_id": Self.workspaceID,
            "path": "spaced.md",
            "kind": "file",
        ])
    }

    // MARK: Capability gate

    @Test func withoutTheFilesCapabilityTheStoreIsInert() async throws {
        let fake = FakeSupermuxMacClient()
        seedFixtureTree(fake)
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: ["workspace.groups.v1"])
        )

        #expect(!store.showsFileBrowser)
        await store.load()
        await store.refresh()
        await store.navigate(into: "src")
        await #expect(throws: SupermuxMacUnavailableError.self) {
            try await store.createFile(named: "new.swift")
        }
        await #expect(throws: SupermuxMacUnavailableError.self) {
            try await store.trash(entryNames: ["notes.md"])
        }

        #expect(fake.callLog.isEmpty, "no RPC may be issued without supermux.files.v1")
        #expect(!store.hasLoaded)
    }
}
