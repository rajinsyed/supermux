import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The New Worktree sheet's Mac picker: which Macs can host a worktree of the
/// chosen project (the same repository, matched by its git origin), in what
/// order, and that picking one really runs the create on THAT Mac. Written as
/// the list of ways the picker can go wrong.
@MainActor
@Suite struct SupermuxNewWorktreeMacPickerTests {
    private let wait = TestWait()
    private typealias Source = SupermuxNewWorktreeMacOptions.Source

    private let studio = SupermuxMacInfo(
        macDeviceID: "mac-studio", instanceTag: "default", displayName: "Studio",
        status: .connected, isForeground: true
    )
    private let macBook = SupermuxMacInfo(
        macDeviceID: "mac-book", instanceTag: "default", displayName: "MacBook",
        status: .connected, isForeground: false
    )
    private let mini = SupermuxMacInfo(
        macDeviceID: "mac-mini", instanceTag: "default", displayName: "Mini",
        status: .connected, isForeground: false
    )

    private func project(
        _ id: String,
        origin: String?,
        name: String = "supermux",
        rootPath: String = "/Users/dev/supermux"
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: id, name: name, rootPath: rootPath, gitRemoteURL: origin)
    }

    // MARK: Which Macs are offered

    @Test func theProjectsOwnMacComesFirstThenMatchingMacsInDisplayOrder() {
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "b-1",
            onPairingID: macBook.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [project("a-1", origin: "git@github.com:me/supermux.git")]),
                Source(mac: macBook, supportsWorktrees: true, projects: [project("b-1", origin: "https://github.com/me/supermux")]),
                Source(mac: mini, supportsWorktrees: true, projects: [project("c-1", origin: "ssh://git@github.com/me/supermux.git")]),
            ]
        )

        #expect(options.map(\.pairingID) == [macBook.pairingID, studio.pairingID, mini.pairingID])
        #expect(options.map(\.projectID) == ["b-1", "a-1", "c-1"])
        #expect(options.map(\.macName) == ["MacBook", "Studio", "Mini"])
    }

    @Test func aMacWithADifferentRepositoryIsNotOffered() {
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [project("a-1", origin: "git@github.com:me/supermux.git")]),
                Source(mac: macBook, supportsWorktrees: true, projects: [project("b-1", origin: "git@github.com:fork/supermux.git")]),
            ]
        )

        #expect(options.map(\.pairingID) == [studio.pairingID])
    }

    @Test func macsThatCannotCreateWorktreesOrAreNotConnectedAreNotOffered() {
        let offline = SupermuxMacInfo(
            macDeviceID: "mac-mini", instanceTag: "default", displayName: "Mini",
            status: .reconnecting, isForeground: false
        )
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [project("a-1", origin: "git@github.com:me/supermux.git")]),
                Source(mac: macBook, supportsWorktrees: false, projects: [project("b-1", origin: "git@github.com:me/supermux.git")]),
                Source(mac: offline, supportsWorktrees: true, projects: [project("c-1", origin: "git@github.com:me/supermux.git")]),
            ]
        )

        #expect(options.map(\.pairingID) == [studio.pairingID])
    }

    @Test func aRepositoryWithoutAnOriginMatchesOnlyByNameAndPath() {
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [project("a-1", origin: nil)]),
                Source(mac: macBook, supportsWorktrees: true, projects: [project("b-1", origin: nil)]),
                Source(mac: mini, supportsWorktrees: true, projects: [project("c-1", origin: nil, rootPath: "/Volumes/work/supermux")]),
            ]
        )

        #expect(options.map(\.pairingID) == [studio.pairingID, macBook.pairingID])
    }

    // MARK: Picking a Mac retargets the create

    @Test func theSheetOffersEveryConnectedMacWithTheSameRepository() async throws {
        let studioClient = FakeSupermuxMacClient()
        studioClient.listResponse = SupermuxProjectsListResponse(projects: [project("a-1", origin: "git@github.com:me/supermux.git")])
        let bookClient = FakeSupermuxMacClient()
        bookClient.listResponse = SupermuxProjectsListResponse(projects: [project("b-1", origin: "https://github.com/me/supermux.git")])
        let (model, sessions) = try await runningModel(studioClient: studioClient, bookClient: bookClient)
        defer { sessions.forEach { $0.cancel() } }

        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        let presentation = try #require(model.newWorktreePresentation)

        #expect(presentation.options.map(\.pairingID) == [studio.pairingID, macBook.pairingID])
    }

    @Test func pickingAnotherMacCreatesOnThatMacsProjectOverItsOwnClient() async throws {
        let studioClient = FakeSupermuxMacClient()
        studioClient.listResponse = SupermuxProjectsListResponse(projects: [project("a-1", origin: "git@github.com:me/supermux.git")])
        let bookClient = FakeSupermuxMacClient()
        bookClient.listResponse = SupermuxProjectsListResponse(projects: [project("b-1", origin: "https://github.com/me/supermux.git")])
        bookClient.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [], branches: ["main", "remote-only"])
        bookClient.worktreeCreateResponse = SupermuxWorktreeCreateResponse(workspaceId: "ws-on-book")
        let (model, sessions) = try await runningModel(studioClient: studioClient, bookClient: bookClient)
        defer { sessions.forEach { $0.cancel() } }
        let navigated = NavigationRecorder()
        model.updateWorkspaces([], selectWorkspace: { navigated.ids.append($0) }, resolveWorkspace: { remote, device, _ in
            "\(device ?? "?")/\(remote)"
        })
        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        let presentation = try #require(model.newWorktreePresentation)
        let bookOption = try #require(presentation.options.last)

        let target = try await model.prepareNewWorktreeTarget(bookOption)
        let workspaceID = try await target.store.createWorktree(
            workspaceName: "remote work", branchName: nil, baseBranch: nil, open: true
        ).workspaceId
        target.openWorkspace(try #require(workspaceID))

        #expect(target.store.branches == ["main", "remote-only"])
        let create = try #require(bookClient.recordedWireCalls.first { $0.method == "mobile.supermux.worktree.create" })
        #expect(create.params["project_id"] as? String == "b-1")
        #expect(!studioClient.callLog.contains("worktreeCreate"))
        try await wait.until { !navigated.ids.isEmpty }
        #expect(navigated.ids == ["mac-book/ws-on-book"])
    }

    private final class NavigationRecorder {
        var ids: [String] = []
    }

    private func runningModel(
        studioClient: FakeSupermuxMacClient,
        bookClient: FakeSupermuxMacClient
    ) async throws -> (SupermuxProjectsSectionModel, [Task<Void, Never>]) {
        let suiteName = "SupermuxNewWorktreeMacPickerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = SupermuxProjectsSectionModel(expansionDefaults: defaults)
        let capabilities: Set<String> = [
            SupermuxMobileCapability.projectsV1.rawValue,
            SupermuxMobileCapability.worktreesV1.rawValue,
        ]
        model.updateMacs([studio, macBook])
        let sessions = [
            Task { await model.runSession(mac: studio, client: studioClient, hostCapabilities: capabilities, connectionID: "studio") },
            Task { await model.runSession(mac: macBook, client: bookClient, hostCapabilities: capabilities, connectionID: "book") },
        ]
        try await wait.until { model.snapshot.rows.count == 2 }
        return (model, sessions)
    }
}
