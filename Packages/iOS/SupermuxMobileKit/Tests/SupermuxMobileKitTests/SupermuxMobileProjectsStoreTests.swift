import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-01: the projects store syncs from a fake ``SupermuxMacCalling`` and
/// refetches on `supermux.projects.updated`; UI-02: without
/// `supermux.projects.v1` the section reports hidden and nothing is fetched.
@MainActor
@Suite struct SupermuxMobileProjectsStoreTests {
    private static let fixturesA: [SupermuxProjectDTO] = [
        SupermuxProjectDTO(
            id: "0A6E3E1B-8C1F-4E58-9C1D-2B5F0E7A9C11",
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            hasCustomIcon: true
        ),
        SupermuxProjectDTO(
            id: "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55",
            name: "Beta",
            rootPath: "/Users/dev/beta"
        ),
    ]

    private static let fixturesB: [SupermuxProjectDTO] = [
        SupermuxProjectDTO(
            id: "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF",
            name: "Gamma",
            rootPath: "/Users/dev/gamma"
        ),
    ]

    private static let projectsOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.projectsV1.rawValue]
    )

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = projectsOnly,
        iconCache: SupermuxProjectIconCache = SupermuxProjectIconCache()
    ) -> SupermuxMobileProjectsStore {
        SupermuxMobileProjectsStore(
            client: fake,
            capabilities: capabilities,
            iconCache: iconCache,
            idleSleep: { _ in await Task.yield() }
        )
    }

    // MARK: UI-01 — sync + event-driven refetch

    @Test func syncsFixturesThenRefetchesOnProjectsUpdated() async throws {
        let fake = FakeSupermuxMacClient()
        fake.listResponse = SupermuxProjectsListResponse(
            projects: Self.fixturesA,
            sectionCollapsed: false
        )
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.projects == Self.fixturesA)
        #expect(store.isSectionCollapsed == false)
        // Subscribe-before-fetch: an event emitted during the initial fetch
        // must buffer in the stream instead of being dropped.
        #expect(fake.callLog.prefix(2) == ["events", "projectsList"])
        #expect(fake.subscribedTopicSets.first == [.projectsUpdated])

        fake.listResponse = SupermuxProjectsListResponse(
            projects: Self.fixturesB,
            sectionCollapsed: true
        )
        fake.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await TestWait().until { store.projects == Self.fixturesB }
        #expect(store.isSectionCollapsed == true)
        #expect(fake.projectsListCallCount == 2)
    }

    @Test func syncsGlobalPresetsFromTheListResponseAndRefetchesOnEvent() async throws {
        let presetsA = [
            SupermuxTerminalPresetDTO(
                id: "44444444-4444-4444-4444-444444444444",
                name: "claude",
                command: "claude",
                iconSymbol: "sparkle",
                colorHex: "#f97316"
            ),
        ]
        let presetsB = presetsA + [
            SupermuxTerminalPresetDTO(
                id: "55555555-5555-5555-5555-555555555555",
                name: "codex",
                command: "codex"
            ),
        ]
        let fake = FakeSupermuxMacClient()
        fake.listResponse = SupermuxProjectsListResponse(
            projects: Self.fixturesA,
            presets: presetsA
        )
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.presets == presetsA)

        // A preset mutation on the Mac pokes the SAME projects.updated topic
        // (the observer hashes model.presets); the refetch carries the new bar.
        fake.listResponse = SupermuxProjectsListResponse(
            projects: Self.fixturesA,
            presets: presetsB
        )
        fake.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await TestWait().until { store.presets == presetsB }
    }

    @Test func resubscribesAndRefetchesAfterTheStreamEnds() async throws {
        let fake = FakeSupermuxMacClient()
        fake.listResponse = SupermuxProjectsListResponse(projects: Self.fixturesA)
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.isConnected)

        // Connection drop: the stream finishes; the store must resubscribe
        // and refetch so nothing missed while down is lost.
        fake.listResponse = SupermuxProjectsListResponse(projects: Self.fixturesB)
        fake.finishEventStreams()
        try await TestWait().until { fake.subscribedTopicSets.count == 2 }
        try await TestWait().until { store.projects == Self.fixturesB }
    }

    @Test func fetchFailureSurfacesErrorAndNextEventRecovers() async throws {
        struct Boom: Error {}
        let fake = FakeSupermuxMacClient()
        fake.listError = Boom()
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.lastErrorDescription != nil }
        #expect(!store.hasLoaded)
        #expect(store.projects.isEmpty)

        fake.listError = nil
        fake.listResponse = SupermuxProjectsListResponse(projects: Self.fixturesA)
        fake.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await TestWait().until { store.hasLoaded }
        #expect(store.projects == Self.fixturesA)
        #expect(store.lastErrorDescription == nil)
    }

    // MARK: UI-02 — capability gating

    @Test func withoutProjectsCapabilityTheSectionIsHiddenAndNothingIsFetched() async throws {
        let fake = FakeSupermuxMacClient()
        fake.listResponse = SupermuxProjectsListResponse(projects: Self.fixturesA)
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: ["workspace.groups.v1"])
        )
        #expect(!store.showsProjectsSection)

        // run() must be a no-op against an upstream Mac: no subscribe, no fetch.
        await store.run()
        #expect(fake.callLog.isEmpty)
        #expect(store.projects.isEmpty)
        #expect(!store.hasLoaded)
    }

    @Test func withProjectsCapabilityTheSectionIsVisible() {
        let store = makeStore(fake: FakeSupermuxMacClient())
        #expect(store.showsProjectsSection)
    }

    // MARK: icon fetch through the etag cache

    @Test func iconFetchStoresEtagThenServesNotModifiedFromCache() async throws {
        let fake = FakeSupermuxMacClient()
        let cache = SupermuxProjectIconCache()
        let store = makeStore(fake: fake, iconCache: cache)
        let project = Self.fixturesA[0]
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])

        fake.iconResponses = [
            SupermuxProjectIconResponse(
                notModified: false,
                etag: "e1",
                pngBase64: pngBytes.base64EncodedString()
            ),
        ]
        let first = await store.iconPNGData(for: project)
        #expect(first == pngBytes)
        #expect(fake.iconRequests.count == 1)
        #expect(fake.iconRequests[0].projectID == project.id)
        #expect(fake.iconRequests[0].etag == nil)

        // Second fetch sends the cached etag; a not_modified answer serves
        // the cached bytes without new image data on the wire.
        fake.iconResponses = [SupermuxProjectIconResponse(notModified: true, etag: "e1")]
        let second = await store.iconPNGData(for: project)
        #expect(second == pngBytes)
        #expect(fake.iconRequests.count == 2)
        #expect(fake.iconRequests[1].etag == "e1")

        // A changed icon replaces the cached entry.
        let newBytes = Data([1, 2, 3, 4])
        fake.iconResponses = [
            SupermuxProjectIconResponse(
                notModified: false,
                etag: "e2",
                pngBase64: newBytes.base64EncodedString()
            ),
        ]
        let third = await store.iconPNGData(for: project)
        #expect(third == newBytes)
        #expect(await cache.entry(forProjectID: project.id)?.etag == "e2")
    }

    @Test func iconFetchIsSkippedWithoutACustomIcon() async {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)
        // fixturesA[1] has no custom icon: SF symbol / letter avatar render
        // natively on the phone, so no RPC may be issued.
        let data = await store.iconPNGData(for: Self.fixturesA[1])
        #expect(data == nil)
        #expect(fake.iconRequests.isEmpty)
    }

    @Test func iconFetchFailureFallsBackToTheCachedIcon() async {
        struct Boom: Error {}
        let fake = FakeSupermuxMacClient()
        let cache = SupermuxProjectIconCache()
        let project = Self.fixturesA[0]
        let cachedBytes = Data([9, 9, 9])
        await cache.store(.init(etag: "e1", pngData: cachedBytes), forProjectID: project.id)
        fake.iconError = Boom()
        let store = makeStore(fake: fake, iconCache: cache)
        let data = await store.iconPNGData(for: project)
        #expect(data == cachedBytes)
    }

    // MARK: Presets visibility gate

    private static let projectsAndPresets = SupermuxMobileCapabilities(hostCapabilities: [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.presetsV1.rawValue,
    ])

    @Test func showsPresetsRequiresTheCapabilityAndAListThatCarriesPresets() async throws {
        let fake = FakeSupermuxMacClient()
        // An EMPTY bar still proves the read shape: the field travels.
        fake.listResponse = SupermuxProjectsListResponse(projects: [], presets: [])
        let store = makeStore(fake: fake, capabilities: Self.projectsAndPresets)

        // Before the first fetch nothing is proven yet.
        #expect(!store.showsPresets)

        let runner = Task { await store.run() }
        defer { runner.cancel() }
        try await TestWait().until { store.hasLoaded }
        #expect(store.showsPresets)
    }

    @Test func showsPresetsStaysHiddenWhenTheHostOmitsThePresetsField() async throws {
        let fake = FakeSupermuxMacClient()
        // An m2-f3-era fork Mac: advertises supermux.presets.v1 (CRUD works)
        // but its projects.list predates the presets read shape. Showing a
        // permanently-empty presets manager would look like data loss, so
        // the area hides until the host proves the read path.
        fake.listResponse = SupermuxProjectsListResponse(projects: Self.fixturesA, presets: nil)
        let store = makeStore(fake: fake, capabilities: Self.projectsAndPresets)
        let runner = Task { await store.run() }
        defer { runner.cancel() }
        try await TestWait().until { store.hasLoaded }
        #expect(!store.showsPresets)
        #expect(store.presets.isEmpty)
    }

    @Test func showsPresetsStaysHiddenWithoutThePresetsCapability() async throws {
        let fake = FakeSupermuxMacClient()
        fake.listResponse = SupermuxProjectsListResponse(
            projects: Self.fixturesA,
            presets: [
                SupermuxTerminalPresetDTO(
                    id: "44444444-4444-4444-4444-444444444444",
                    name: "claude",
                    command: "claude"
                ),
            ]
        )
        // projects.v1 alone: no preset CRUD on the Mac, so no presets UI.
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }
        try await TestWait().until { store.hasLoaded }
        #expect(!store.showsPresets)
    }
}
