import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// The app-group icon mirror the notification extension paints banners from.
///
/// The phone runs one projects store per connected Mac, and every store
/// shares ONE mirror directory keyed by the Mac-local project id. Written as
/// the ways a refresh can damage that shared directory.
@MainActor
@Suite struct SupermuxMobileProjectsStoreIconMirrorTests {
    /// A container rooted at a temp directory, standing in for the app group.
    private final class TemporaryContainer: FileManager {
        let root: URL

        init(root: URL) {
            self.root = root
            super.init()
        }

        override func containerURL(
            forSecurityApplicationGroupIdentifier groupIdentifier: String
        ) -> URL? {
            groupIdentifier == SupermuxSharedProjectIconStore.appGroupIdentifier ? root : nil
        }
    }

    private static let capabilities = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.projectsV1.rawValue]
    )

    private static let studioProject = "0A6E3E1B-8C1F-4E58-9C1D-2B5F0E7A9C11"
    private static let studioDeletedProject = "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55"
    private static let studioOlderHostProject = "3B7A1C2D-0E4F-4A5B-9C6D-7E8F9A0B1C2D"
    private static let macBookProject = "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF"

    private func withContainer(_ body: (TemporaryContainer) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "supermux-icon-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(TemporaryContainer(root: root))
    }

    private func mirror(_ projectID: String, in files: FileManager) {
        SupermuxSharedProjectIconStore.store(Data([0x89, 0x50]), forProjectID: projectID, fileManager: files)
    }

    private func isMirrored(_ projectID: String, in files: FileManager) -> Bool {
        SupermuxSharedProjectIconStore.iconData(forProjectID: projectID, fileManager: files) != nil
    }

    private func project(_ id: String, hasCustomIcon: Bool?) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: id, name: id, rootPath: "/Users/dev/\(id)", hasCustomIcon: hasCustomIcon)
    }

    /// Studio's refresh lists only Studio's projects. The MacBook's mirrored
    /// logo is not Studio's to delete: nothing re-fetches it, so every push
    /// from the MacBook would fall back to the generated chip.
    @Test func aRefreshNeverDeletesAnotherMacsMirroredIcon() async throws {
        try await withContainer { files in
            mirror(Self.macBookProject, in: files)
            let studio = FakeSupermuxMacClient()
            studio.listResponse = SupermuxProjectsListResponse(projects: [
                project(Self.studioProject, hasCustomIcon: true),
            ])
            let store = SupermuxMobileProjectsStore(
                client: studio,
                capabilities: Self.capabilities,
                iconMirrorFiles: files,
                idleSleep: { _ in await Task.yield() }
            )
            let runner = Task { await store.run() }
            defer { runner.cancel() }

            try await TestWait().until { store.hasLoaded }

            #expect(isMirrored(Self.macBookProject, in: files))
        }
    }

    /// A refresh still cleans up after ITS OWN Mac: a project it listed before
    /// and no longer lists, and a live project whose host now explicitly says
    /// it has no custom icon. An older host's `nil` is "unknown", not removal.
    @Test func aRefreshDropsOnlyItsOwnDeletedAndIconlessProjects() async throws {
        try await withContainer { files in
            for id in [Self.studioProject, Self.studioDeletedProject, Self.studioOlderHostProject, Self.macBookProject] {
                mirror(id, in: files)
            }
            let studio = FakeSupermuxMacClient()
            studio.listResponse = SupermuxProjectsListResponse(projects: [
                project(Self.studioProject, hasCustomIcon: true),
                project(Self.studioDeletedProject, hasCustomIcon: true),
                project(Self.studioOlderHostProject, hasCustomIcon: nil),
            ])
            let store = SupermuxMobileProjectsStore(
                client: studio,
                capabilities: Self.capabilities,
                iconMirrorFiles: files,
                idleSleep: { _ in await Task.yield() }
            )
            let runner = Task { await store.run() }
            defer { runner.cancel() }
            try await TestWait().until { store.hasLoaded }

            studio.listResponse = SupermuxProjectsListResponse(projects: [
                project(Self.studioProject, hasCustomIcon: false),
                project(Self.studioOlderHostProject, hasCustomIcon: nil),
            ])
            studio.emit(SupermuxMobileEvent(topic: .projectsUpdated))
            try await TestWait().until { store.projects.count == 2 }

            #expect(!isMirrored(Self.studioProject, in: files))
            #expect(!isMirrored(Self.studioDeletedProject, in: files))
            #expect(isMirrored(Self.studioOlderHostProject, in: files))
            #expect(isMirrored(Self.macBookProject, in: files))
        }
    }
}
