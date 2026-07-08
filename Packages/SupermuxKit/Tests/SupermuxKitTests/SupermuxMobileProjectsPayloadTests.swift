import Foundation
import SupermuxMobileCore
import Testing
@testable import SupermuxKit

/// Wire-payload tests for the `mobile.supermux.projects.list` read path
/// (validation contract RPC-PROJ-01): a `SupermuxProjectsModel` seeded from a
/// temp projects file maps through the DTO extensions into a
/// `{projects: [SupermuxProjectDTO], section_collapsed}` payload that decodes
/// back to the fixtures through the shared `SupermuxWireJSON` bridge.
@MainActor
struct SupermuxMobileProjectsPayloadTests {
    /// A fresh, unique temp-directory URL (not created on disk).
    private func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// A project with every DTO-visible field populated.
    private func fullyPopulatedProject() -> SupermuxProject {
        SupermuxProject(
            id: UUID(),
            name: "Alpha",
            rootPath: "/tmp/supermux-alpha-\(UUID().uuidString)",
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            customIconPath: nil,
            defaultBranch: "main",
            worktreesDirName: ".trees",
            runCommands: ["npm run dev"],
            setupCommands: ["npm install"],
            teardownCommands: ["docker compose down"],
            actions: [
                SupermuxProjectAction(name: "Open in Editor", command: "cursor .", iconSymbol: "pencil"),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
    }

    /// Builds a model whose projects file on disk carries `projects`.
    private func makeLoadedModel(
        projects: [SupermuxProject],
        isSectionCollapsed: Bool,
        fileURL: URL
    ) async throws -> SupermuxProjectsModel {
        let store = SupermuxProjectStore(fileURL: fileURL)
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: projects,
            isSectionCollapsed: isSectionCollapsed
        ))
        let model = SupermuxProjectsModel(
            store: store,
            worktreeService: SupermuxGitWorktreeService()
        )
        await model.loadIfNeeded()
        return model
    }

    // MARK: - DTO mapping

    @Test func projectDTOMapsEveryWireField() throws {
        let project = fullyPopulatedProject()

        let dto = SupermuxProjectDTO(project: project, hasCustomIcon: true)

        #expect(dto.id == project.id.uuidString)
        #expect(dto.name == "Alpha")
        #expect(dto.rootPath == project.rootPath)
        #expect(dto.colorHex == "#3b82f6")
        #expect(dto.iconSymbol == "folder")
        #expect(dto.hasCustomIcon == true)
        #expect(dto.defaultBranch == "main")
        #expect(dto.worktreesDirName == ".trees")
        #expect(dto.runCommands == ["npm run dev"])
        #expect(dto.setupCommands == ["npm install"])
        #expect(dto.teardownCommands == ["docker compose down"])
        #expect(dto.actions?.count == 1)
        #expect(dto.actions?.first?.id == project.actions.first?.id.uuidString)
        #expect(dto.actions?.first?.name == "Open in Editor")
        #expect(dto.actions?.first?.command == "cursor .")
        #expect(dto.actions?.first?.iconSymbol == "pencil")
        #expect(dto.createdAt == 1_700_000_000)
        #expect(dto.lastOpenedAt == 1_700_100_000)
    }

    @Test func projectActionDTOFallsBackToNilIconSymbol() {
        let action = SupermuxProjectAction(name: "Dev", command: "npm run dev")

        let dto = SupermuxProjectActionDTO(action: action)

        #expect(dto.iconSymbol == nil)
        #expect(dto.kind == nil)
        #expect(dto.url == nil)
    }

    // MARK: - RPC-PROJ-01: projects.list payload from a seeded model

    @Test func projectsListPayloadRoundTripsSeededFixtures() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixtures = [fullyPopulatedProject(), fullyPopulatedProject()]
        let model = try await makeLoadedModel(
            projects: fixtures,
            isSectionCollapsed: true,
            fileURL: dir.appendingPathComponent("projects.json")
        )

        let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
            projects: model.projects,
            isSectionCollapsed: model.isSectionCollapsed
        )

        #expect(payload["section_collapsed"] as? Bool == true)
        let encoded = try #require(payload["projects"] as? [[String: Any]])
        let wire = SupermuxWireJSON()
        let decoded = try encoded.map { try wire.decode(SupermuxProjectDTO.self, from: $0) }
        #expect(decoded.count == fixtures.count)
        for (dto, fixture) in zip(decoded, fixtures) {
            #expect(dto.id == fixture.id.uuidString)
            #expect(dto.name == fixture.name)
            #expect(dto.rootPath == fixture.rootPath)
            #expect(dto.colorHex == fixture.colorHex)
            #expect(dto.iconSymbol == fixture.iconSymbol)
            // The fixture roots don't exist on disk, so no icon is fetchable.
            #expect(dto.hasCustomIcon == false)
            #expect(dto.defaultBranch == fixture.defaultBranch)
            #expect(dto.worktreesDirName == fixture.worktreesDirName)
            #expect(dto.runCommands == fixture.runCommands)
            #expect(dto.setupCommands == fixture.setupCommands)
            #expect(dto.teardownCommands == fixture.teardownCommands)
            #expect(dto.actions?.map(\.name) == fixture.actions.map(\.name))
            #expect(dto.createdAt == fixture.createdAt.timeIntervalSince1970)
            #expect(dto.lastOpenedAt == fixture.lastOpenedAt?.timeIntervalSince1970)
        }
    }

    @Test func projectsListPayloadMarksFetchableCustomIcon() async throws {
        let dir = freshTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let iconURL = dir.appendingPathComponent("custom-icon.png")
        try SupermuxIconTestFixtures.pngData().write(to: iconURL)
        var project = fullyPopulatedProject()
        project.customIconPath = iconURL.path

        let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
            projects: [project],
            isSectionCollapsed: false
        )

        let encoded = try #require(payload["projects"] as? [[String: Any]])
        let dto = try SupermuxWireJSON().decode(SupermuxProjectDTO.self, from: try #require(encoded.first))
        #expect(dto.hasCustomIcon == true)
        #expect(payload["section_collapsed"] as? Bool == false)
    }
}
