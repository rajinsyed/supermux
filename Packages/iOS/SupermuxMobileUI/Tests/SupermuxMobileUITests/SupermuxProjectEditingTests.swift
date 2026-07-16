import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The section model's editing seam: the closure bundle routes editor saves
/// through the live session's store (recorded wire calls prove the §2
/// shapes), collapse toggles now persist Mac-side through
/// `mobile.supermux.projects.set_section_collapsed`, and a dead session
/// surfaces ``SupermuxMacUnavailableError`` instead of failing silently.
@MainActor
@Suite struct SupermuxProjectEditingTests {
    private let wait = TestWait()

    private static let capabilities = [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.presetsV1.rawValue,
    ]

    private func fixtureProject() -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Alpha",
            rootPath: "/Users/dev/alpha"
        )
    }

    private func runningSession(
        client: FakeSupermuxMacClient,
        model: SupermuxProjectsSectionModel
    ) async throws -> Task<Void, Never> {
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let session = Task {
            await model.runSession(client: client, hostCapabilities: Set(Self.capabilities))
        }
        try await wait.until { model.snapshot.hasLoaded }
        return session
    }

    @Test func editingActionsRouteProjectCRUDThroughTheSessionStore() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxProjectsSectionModel()
        let session = try await runningSession(client: client, model: model)
        defer { session.cancel() }

        let editing = try #require(model.actions.editing)

        client.projectWriteResponse = SupermuxProjectWriteResponse(project: fixtureProject())
        _ = try await editing.createProject("/Users/dev/alpha")
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.project.create")

        var patch = SupermuxProjectPatch()
        patch.name = "Renamed"
        _ = try await editing.updateProject(fixtureProject().id, patch)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.project.update")
        #expect(client.recordedWireCalls.last?.params == [
            "project_id": fixtureProject().id,
            "patch": ["name": "Renamed"],
        ] as NSDictionary)

        try await editing.deleteProject(fixtureProject().id)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.project.delete")
    }

    @Test func editingActionsRoutePresetCRUDThroughTheSessionStore() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxProjectsSectionModel()
        let session = try await runningSession(client: client, model: model)
        defer { session.cancel() }

        let editing = try #require(model.actions.editing)
        let presetID = "33333333-3333-3333-3333-333333333333"
        client.presetWriteResponse = SupermuxPresetWriteResponse(
            preset: SupermuxTerminalPresetDTO(id: presetID, name: "Claude", command: "claude")
        )

        var draft = SupermuxPresetDraft()
        draft.name = "Claude"
        draft.command = "claude"
        let request = try #require(draft.createRequest())
        _ = try await editing.createPreset(request)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.preset.create")

        var patch = SupermuxPresetPatch()
        patch.command = "claude --resume"
        _ = try await editing.updatePreset(presetID, patch)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.preset.update")

        try await editing.deletePreset(presetID)
        #expect(client.recordedWireCalls.last?.method == "mobile.supermux.preset.delete")
        #expect(client.recordedWireCalls.last?.params == ["preset_id": presetID] as NSDictionary)
    }

    @Test func editorProjectServesTheFreshDTOForSeedingTheEditor() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxProjectsSectionModel()
        let session = try await runningSession(client: client, model: model)
        defer { session.cancel() }

        let editing = try #require(model.actions.editing)
        #expect(editing.editorProject(fixtureProject().id) == fixtureProject())
        #expect(editing.editorProject("unknown") == nil)
    }

    @Test func editingActionsWithoutASessionThrowUnavailable() async throws {
        let model = SupermuxProjectsSectionModel()
        let editing = try #require(model.actions.editing)
        await #expect(throws: SupermuxMacUnavailableError.self) {
            _ = try await editing.createProject("/Users/dev/alpha")
        }
    }

    @Test func toggleCollapsedPersistsTheStateMacSide() async throws {
        let client = FakeSupermuxMacClient()
        let model = SupermuxProjectsSectionModel()
        let session = try await runningSession(client: client, model: model)
        defer { session.cancel() }

        #expect(!model.snapshot.isCollapsed)
        model.toggleCollapsed()
        // The local override flips immediately (responsive header) …
        #expect(model.snapshot.isCollapsed)
        // … and the write reaches the Mac through the §2 method.
        try await wait.until {
            client.recordedWireCalls.contains { call in
                call.method == "mobile.supermux.projects.set_section_collapsed"
            }
        }
        let call = client.recordedWireCalls.last { $0.method.hasSuffix("set_section_collapsed") }
        #expect(call?.params == ["collapsed": true] as NSDictionary)
    }
}
