import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The project-detail route's lifecycle (m6-f2): the pushed detail must stay
/// valid across store refetches and across the navigation push itself.
///
/// Field bug this pins: on iPhone, pushing the detail covers the shell's
/// `List` (the NavigationStack root), so SwiftUI cancels the section
/// driver's structured `.task` — `runSession` used to tear the session down
/// unconditionally in its `defer`, blanking `detailRow` and swapping the
/// just-pushed detail for the "no longer available" placeholder about a
/// second after it appeared. Resolution is by STABLE project id against the
/// live snapshot; the placeholder is reserved for a project genuinely
/// deleted from a loaded projects list.
@MainActor
@Suite struct SupermuxProjectDetailRouteTests {
    private let wait = TestWait()

    private static let projectsCapability = SupermuxMobileCapability.projectsV1.rawValue

    private func fixtureProject(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "Alpha"
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: name,
            rootPath: "/Users/dev/alpha",
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            hasCustomIcon: false
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxProjectDetailRouteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Starts a session against `client` and waits for the first load.
    private func startSession(
        _ model: SupermuxProjectsSectionModel,
        client: FakeSupermuxMacClient
    ) async throws -> Task<Void, Never> {
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        try await wait.until { model.snapshot.hasLoaded }
        return session
    }

    // MARK: Live resolution across refetches

    @Test func pushedDetailStaysValidAndLiveAcrossAProjectsRefetch() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)
        defer { session.cancel() }

        model.openProjectDetail(project.id)
        #expect(model.detailRow?.id == project.id)

        // A refetch (projects.updated poke) with the project still present
        // must keep the destination valid — and feed it the FRESH data.
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(name: "Alpha Renamed")]
        )
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await wait.until { model.detailRow?.name == "Alpha Renamed" }
        #expect(model.detailProjectID == project.id)
    }

    @Test func placeholderShowsOnlyWhenTheProjectIsGenuinelyDeleted() async throws {
        let alpha = fixtureProject()
        let beta = fixtureProject(id: "22222222-2222-2222-2222-222222222222", name: "Beta")
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [alpha, beta])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)
        defer { session.cancel() }

        model.openProjectDetail(alpha.id)
        #expect(model.detailRow?.id == alpha.id)

        // Alpha deleted mac-side: the loaded list no longer contains it, so
        // the destination resolves nil (the localized placeholder).
        client.listResponse = SupermuxProjectsListResponse(projects: [beta])
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await wait.until { model.detailRow == nil }
        #expect(model.detailProjectID == alpha.id)
    }

    // MARK: The navigation push cancels the driver's task

    @Test func pushCancellationKeepsTheSessionAndTheDetailAlive() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)

        model.openProjectDetail(project.id)
        #expect(model.detailRow?.id == project.id)

        // The push covers the list; SwiftUI cancels the driver's `.task`.
        session.cancel()
        await session.value

        // The session must survive the push (the connection is still alive):
        // the detail keeps resolving from the live store — never the
        // "no longer available" placeholder.
        #expect(model.store != nil)
        #expect(model.detailRow?.id == project.id)
        #expect(model.snapshot.isVisible)
    }

    @Test func cancellationWithoutAPushedDetailStillTearsDown() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)

        session.cancel()
        await session.value

        #expect(model.store == nil)
        #expect(!model.snapshot.isVisible)
    }

    @Test func replacementSessionAfterAPushSwapsTheStoreWholesale() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)

        model.openProjectDetail(project.id)
        session.cancel()
        await session.value
        let survivingStore = try #require(model.store)

        // Popping back re-runs the driver's `.task`: the fresh session
        // replaces the surviving one wholesale and the detail keeps
        // resolving against the new store's data.
        let client2 = FakeSupermuxMacClient()
        client2.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(name: "Alpha v2")]
        )
        let session2 = try await startSession(model, client: client2)
        defer { session2.cancel() }
        try await wait.until { model.detailRow?.name == "Alpha v2" }
        #expect(model.store !== survivingStore)
    }

    // MARK: Disconnect while pushed

    @Test func endSessionWhileDetailIsPushedFallsBackToTheLastKnownRow() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client)
        defer { session.cancel() }

        model.openProjectDetail(project.id)
        model.endSession()

        // A hard disconnect hides the section, but the pushed detail keeps
        // its last-known row instead of flashing the placeholder.
        #expect(model.store == nil)
        #expect(model.detailRow?.id == project.id)

        model.dismissProjectDetail()
        #expect(model.detailRow == nil)
    }
}
