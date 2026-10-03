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

    /// Two checkouts of one origin on the other Mac make the origin ambiguous
    /// (the Mac-side merge rule refuses it): the copy with the same name and
    /// path is that Mac's project, whatever order that Mac lists them in.
    @Test func anAmbiguousOriginPicksTheCheckoutWithTheSameNameAndPath() {
        let origin = "git@github.com:me/app.git"
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [
                    project("a-1", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                ]),
                Source(mac: macBook, supportsWorktrees: true, projects: [
                    project("b-review", origin: origin, name: "app-review", rootPath: "/Users/dev/code/app-review"),
                    project("b-app", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                ]),
            ]
        )

        #expect(options.map(\.projectID) == ["a-1", "b-app"])
    }

    /// With an ambiguous origin and no same-name-and-path copy, the phone
    /// cannot know which checkout the user means: that Mac is not offered,
    /// rather than creating under whichever copy it happens to list first.
    @Test func anAmbiguousOriginWithoutAnExactCopyIsNotOffered() {
        let origin = "git@github.com:me/app.git"
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [
                    project("a-1", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                ]),
                Source(mac: macBook, supportsWorktrees: true, projects: [
                    project("b-review", origin: origin, name: "app-review", rootPath: "/Users/dev/code/app-review"),
                    project("b-main", origin: origin, name: "app-main", rootPath: "/Users/dev/code/app-main"),
                ]),
            ]
        )

        #expect(options.map(\.pairingID) == [studio.pairingID])
    }

    /// The own Mac holding two checkouts of the origin is just as ambiguous:
    /// the Mac-side merge rule matches by origin only when it is unique on
    /// BOTH Macs, so only a same-name-and-path copy may stand in.
    @Test func anOriginSharedByTwoOwnCheckoutsMatchesOnlyByNameAndPath() {
        let origin = "git@github.com:me/app.git"
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-review",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [
                    project("a-app", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                    project("a-review", origin: origin, name: "app-review", rootPath: "/Users/dev/code/app-review"),
                ]),
                Source(mac: macBook, supportsWorktrees: true, projects: [
                    project("b-app", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                ]),
            ]
        )

        #expect(options.map(\.pairingID) == [studio.pairingID])
    }

    /// The Mac sidebar claims every unique-origin match before any
    /// name-and-path match, so an origin-less copy at the same path that the
    /// other Mac happens to list FIRST must not win over the real clone.
    @Test func aUniqueOriginMatchWinsOverAnEarlierNameAndPathMatch() {
        let origin = "git@github.com:me/app.git"
        let options = SupermuxNewWorktreeMacOptions.options(
            forProjectID: "a-1",
            onPairingID: studio.pairingID,
            sources: [
                Source(mac: studio, supportsWorktrees: true, projects: [
                    project("a-1", origin: origin, name: "app", rootPath: "/Users/dev/code/app"),
                ]),
                Source(mac: macBook, supportsWorktrees: true, projects: [
                    project("b-copy", origin: nil, name: "app", rootPath: "/Users/dev/code/app"),
                    project("b-dev", origin: origin, name: "app-dev", rootPath: "/Users/dev/src/app-dev"),
                ]),
            ]
        )

        #expect(options.map(\.projectID) == ["a-1", "b-dev"])
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

    // MARK: Which reconnect closes the sheet

    /// Only the Mac the sheet creates on holds stores: another Mac merely
    /// offered in the picker re-resolves when picked, so its reconnect (lid
    /// closed, network change) must not throw away the user's typed prompt.
    @Test func aReconnectOfAMacOnlyOfferedInThePickerKeepsTheSheet() async throws {
        let (model, running) = try await sameRepositoryModel()
        var sessions = running
        defer { sessions.forEach { $0.cancel() } }
        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        #expect(model.newWorktreePresentation != nil)

        sessions[1] = try await reconnect(macBook, on: model, replacing: sessions[1])

        #expect(model.newWorktreePresentation != nil)
    }

    /// Once the picker retargeted the create, that Mac's stores are the live
    /// ones: its reconnect must close the sheet.
    @Test func aReconnectOfTheMacTheSheetRetargetedToClosesIt() async throws {
        let (model, running) = try await sameRepositoryModel()
        var sessions = running
        defer { sessions.forEach { $0.cancel() } }
        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        let bookOption = try #require(model.newWorktreePresentation?.options.last)
        _ = try await model.prepareNewWorktreeTarget(bookOption)

        sessions[1] = try await reconnect(macBook, on: model, replacing: sessions[1])

        #expect(model.newWorktreePresentation == nil)
    }

    /// After a retarget the row's own Mac holds nothing the create uses, so
    /// its reconnect leaves the sheet alone.
    @Test func afterARetargetTheRowsOwnMacReconnectingKeepsTheSheet() async throws {
        let (model, running) = try await sameRepositoryModel()
        var sessions = running
        defer { sessions.forEach { $0.cancel() } }
        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        let bookOption = try #require(model.newWorktreePresentation?.options.last)
        _ = try await model.prepareNewWorktreeTarget(bookOption)

        sessions[0] = try await reconnect(studio, on: model, replacing: sessions[0])

        #expect(model.newWorktreePresentation != nil)
    }

    /// A retarget still fetching branches when its Mac reconnects must fail
    /// in the picker, not hand the sheet stores bound to the dead client.
    @Test func aRetargetWhoseMacReconnectsMidFetchFails() async throws {
        let bookClient = FakeSupermuxMacClient()
        let (model, running) = try await sameRepositoryModel(bookClient: bookClient)
        var sessions = running
        defer { sessions.forEach { $0.cancel() } }
        await model.requestNewWorktree(model.snapshot.rows[0].id)?.value
        let bookOption = try #require(model.newWorktreePresentation?.options.last)
        bookClient.worktreesListShouldHoldBranchFetches = true
        let retarget = Task { try await model.prepareNewWorktreeTarget(bookOption) }
        try await wait.until {
            bookClient.recordedWireCalls.contains { $0.params["include_branches"] as? Bool == true }
        }

        sessions[1] = try await reconnect(macBook, on: model, replacing: sessions[1])
        bookClient.resumeAllWorktreesList()

        await #expect(throws: SupermuxMacUnavailableError.self) { try await retarget.value }
    }

    /// Studio and the MacBook, both with the same repository, sessions running.
    private func sameRepositoryModel(
        bookClient: FakeSupermuxMacClient = FakeSupermuxMacClient()
    ) async throws -> (SupermuxProjectsSectionModel, [Task<Void, Never>]) {
        let studioClient = FakeSupermuxMacClient()
        studioClient.listResponse = SupermuxProjectsListResponse(projects: [project("a-1", origin: "git@github.com:me/supermux.git")])
        bookClient.listResponse = SupermuxProjectsListResponse(projects: [project("b-1", origin: "https://github.com/me/supermux.git")])
        return try await runningModel(studioClient: studioClient, bookClient: bookClient)
    }

    /// Replaces one Mac's connection (a new client identity), the way a
    /// reconnect reaches the section, and waits until the new session loaded.
    private func reconnect(
        _ mac: SupermuxMacInfo,
        on model: SupermuxProjectsSectionModel,
        replacing old: Task<Void, Never>
    ) async throws -> Task<Void, Never> {
        let generation = try #require(model.session(forPairingID: mac.pairingID)?.generation)
        old.cancel()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(
            projects: model.session(forPairingID: mac.pairingID)?.store?.projects ?? []
        )
        let replacement = Task {
            await model.runSession(
                mac: mac,
                client: client,
                hostCapabilities: [
                    SupermuxMobileCapability.projectsV1.rawValue,
                    SupermuxMobileCapability.worktreesV1.rawValue,
                ],
                connectionID: UUID().uuidString
            )
        }
        try await wait.until { model.session(forPairingID: mac.pairingID)?.generation != generation }
        return replacement
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
