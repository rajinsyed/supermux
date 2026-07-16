import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-03 for the project/preset editors: every store write action sends the
/// method name + params matching architecture §2 and m2-f3's committed patch
/// shape EXACTLY (asserted against the fake's recorded wire calls), refetches
/// after project writes, and rethrows Mac errors so the sheets surface them
/// (never a silent failure).
@MainActor
@Suite struct SupermuxProjectsStoreWriteTests {
    private static let projectID = "11111111-1111-1111-1111-111111111111"
    private static let presetID = "33333333-3333-3333-3333-333333333333"

    private static let capabilities = SupermuxMobileCapabilities(hostCapabilities: [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.presetsV1.rawValue,
    ])

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = capabilities
    ) -> SupermuxMobileProjectsStore {
        SupermuxMobileProjectsStore(
            client: fake,
            capabilities: capabilities,
            idleSleep: { _ in await Task.yield() }
        )
    }

    private func fixtureProject(name: String = "Alpha") -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: Self.projectID, name: name, rootPath: "/Users/dev/alpha")
    }

    struct Boom: Error {}

    // MARK: Project create

    @Test func createProjectSendsExactWireShapeAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.projectWriteResponse = SupermuxProjectWriteResponse(project: fixtureProject())
        let store = makeStore(fake: fake)

        let created = try await store.createProject(rootPath: " /Users/dev/alpha ")

        #expect(created == fixtureProject())
        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.project.create")
        #expect(fake.recordedWireCalls.first?.params == [
            "root_path": "/Users/dev/alpha",
        ] as NSDictionary)
        // Optimistic-free semantics: send, await result, refetch.
        #expect(fake.projectsListCallCount == 1)
    }

    @Test func createProjectErrorRethrowsWithoutRefetch() async {
        let fake = FakeSupermuxMacClient()
        fake.projectWriteError = Boom()
        let store = makeStore(fake: fake)
        await #expect(throws: Boom.self) {
            _ = try await store.createProject(rootPath: "/Users/dev/alpha")
        }
        #expect(fake.projectsListCallCount == 0)
    }

    @Test func createProjectWithoutTheCapabilityThrowsUnavailable() async {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: [])
        )
        await #expect(throws: SupermuxMacUnavailableError.self) {
            _ = try await store.createProject(rootPath: "/Users/dev/alpha")
        }
        #expect(fake.callLog.isEmpty)
    }

    // MARK: Project update

    @Test func updateProjectSendsProjectIDPlusPatchObjectAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.projectWriteResponse = SupermuxProjectWriteResponse(project: fixtureProject(name: "Renamed"))
        let store = makeStore(fake: fake)

        var patch = SupermuxProjectPatch()
        patch.name = "Renamed"
        patch.colorHex = .clear
        patch.runCommands = ["bun run dev"]
        let updated = try await store.updateProject(projectID: Self.projectID, patch: patch)

        #expect(updated.name == "Renamed")
        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.project.update")
        #expect(fake.recordedWireCalls.first?.params == [
            "project_id": Self.projectID,
            "patch": [
                "name": "Renamed",
                "color_hex": NSNull(),
                "run_commands": ["bun run dev"],
            ],
        ] as NSDictionary)
        #expect(fake.projectsListCallCount == 1)
    }

    @Test func updateProjectErrorRethrowsForTheSheetToDisplay() async {
        let fake = FakeSupermuxMacClient()
        fake.projectWriteError = Boom()
        let store = makeStore(fake: fake)
        var patch = SupermuxProjectPatch()
        patch.name = "Renamed"
        await #expect(throws: Boom.self) {
            _ = try await store.updateProject(projectID: Self.projectID, patch: patch)
        }
    }

    // MARK: Project delete

    @Test func deleteProjectSendsProjectIDAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)

        try await store.deleteProject(projectID: Self.projectID)

        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.project.delete")
        #expect(fake.recordedWireCalls.first?.params == [
            "project_id": Self.projectID,
        ] as NSDictionary)
        #expect(fake.projectsListCallCount == 1)
    }

    // MARK: Section collapse

    @Test func setSectionCollapsedSendsTheBoolAndAdoptsTheResult() async {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)

        await store.setSectionCollapsed(true)

        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.projects.set_section_collapsed")
        #expect(fake.recordedWireCalls.first?.params == ["collapsed": true] as NSDictionary)
        #expect(store.isSectionCollapsed)
    }

    @Test func setSectionCollapsedFailureSurfacesTheErrorNotACrash() async {
        let fake = FakeSupermuxMacClient()
        fake.sectionCollapsedError = Boom()
        let store = makeStore(fake: fake)

        await store.setSectionCollapsed(true)

        #expect(!store.isSectionCollapsed)
        #expect(store.lastErrorDescription != nil)
    }

    // MARK: Preset CRUD

    @Test func presetCreateSendsFlatParamsOmittingAbsentOptionals() async throws {
        let fake = FakeSupermuxMacClient()
        fake.presetWriteResponse = SupermuxPresetWriteResponse(
            preset: SupermuxTerminalPresetDTO(id: Self.presetID, name: "Claude", command: "claude")
        )
        let store = makeStore(fake: fake)

        var draft = SupermuxPresetDraft()
        draft.name = "Claude"
        draft.command = "claude"
        let request = try #require(draft.createRequest())
        let preset = try await store.createPreset(request)

        #expect(preset.id == Self.presetID)
        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.preset.create")
        #expect(fake.recordedWireCalls.first?.params == [
            "name": "Claude",
            "command": "claude",
        ] as NSDictionary)
        // Presets travel on projects.list (m2-f5), so preset writes refetch
        // exactly like project writes.
        #expect(fake.projectsListCallCount == 1)
    }

    @Test func presetCreateErrorRethrowsWithoutRefetch() async {
        let fake = FakeSupermuxMacClient()
        fake.presetWriteError = Boom()
        let store = makeStore(fake: fake)
        var draft = SupermuxPresetDraft()
        draft.name = "Claude"
        draft.command = "claude"
        await #expect(throws: Boom.self) {
            _ = try await store.createPreset(try #require(draft.createRequest()))
        }
        #expect(fake.projectsListCallCount == 0)
    }

    @Test func presetUpdateSendsPresetIDPlusPatchObject() async throws {
        let fake = FakeSupermuxMacClient()
        fake.presetWriteResponse = SupermuxPresetWriteResponse(
            preset: SupermuxTerminalPresetDTO(id: Self.presetID, name: "Claude", command: "claude --resume")
        )
        let store = makeStore(fake: fake)

        var patch = SupermuxPresetPatch()
        patch.command = "claude --resume"
        patch.colorHex = .clear
        let updated = try await store.updatePreset(presetID: Self.presetID, patch: patch)

        #expect(updated.command == "claude --resume")
        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.preset.update")
        #expect(fake.recordedWireCalls.first?.params == [
            "preset_id": Self.presetID,
            "patch": [
                "command": "claude --resume",
                "color_hex": NSNull(),
            ],
        ] as NSDictionary)
        #expect(fake.projectsListCallCount == 1)
    }

    @Test func presetDeleteSendsPresetID() async throws {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)

        try await store.deletePreset(presetID: Self.presetID)

        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.preset.delete")
        #expect(fake.recordedWireCalls.first?.params == [
            "preset_id": Self.presetID,
        ] as NSDictionary)
        #expect(fake.projectsListCallCount == 1)
    }

    @Test func presetWritesWithoutTheCapabilityThrowUnavailable() async {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: [
                SupermuxMobileCapability.projectsV1.rawValue,
            ])
        )
        await #expect(throws: SupermuxMacUnavailableError.self) {
            _ = try await store.deletePreset(presetID: Self.presetID)
        }
        #expect(fake.callLog.isEmpty)
    }
}
