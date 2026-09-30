import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Ways the cross-device project merge could go wrong (written before the code):
/// 1. The same repo on this Mac and a device renders twice instead of as one
///    project with two locations.
/// 2. SSH and HTTPS spellings of one origin do not merge.
/// 3. An ambiguous origin (two local checkouts, or two on one device) merges the
///    wrong pair instead of falling back to identical name + root path.
/// 4. Two projects whose origins DIFFER merge because name and root happen to match.
/// 5. Origin-less projects never merge, or merge on name alone.
/// 6. One local project swallows several projects from the same device.
/// 7. A repo present on two devices loses one of its device locations.
/// 8. Remote-only projects land between local ones or in an unstable order.
/// 9. Ids are unstable, or a remote-only project reuses the remote Mac's own
///    project UUID (which could alias a local project).
/// 10. A remote project id that equals a LOCAL project id (the loopback case, or
///     a copied projects file) resolves to the local project without matching.
/// 11. Offline devices lose their locations, or are shown as online.
/// 12. Malformed remote ids crash the merge or duplicate rows.
/// 13. The nesting lookup confuses a location's project id across Macs.
struct SupermuxUnifiedProjectsTests {
    private let studio = SupermuxProjectDevice(machineID: "device:aaaa@default", name: "Studio", isOnline: true)
    private let laptop = SupermuxProjectDevice(machineID: "device:bbbb@default", name: "Laptop", isOnline: true)

    private func local(
        _ name: String,
        root: String,
        origin: String? = nil,
        id: UUID = UUID()
    ) -> SupermuxUnifiedProjects.LocalProject {
        SupermuxUnifiedProjects.LocalProject(
            project: SupermuxProject(id: id, name: name, rootPath: root, createdAt: Date(timeIntervalSince1970: 0)),
            gitRemoteIdentity: SupermuxGitRemoteIdentity.normalized(origin)
        )
    }

    private func remote(_ name: String, root: String, origin: String? = nil, id: UUID = UUID()) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: id.uuidString, name: name, rootPath: root, gitRemoteURL: origin)
    }

    private func merge(
        _ locals: [SupermuxUnifiedProjects.LocalProject],
        _ devices: [(SupermuxProjectDevice, [SupermuxProjectDTO])]
    ) -> SupermuxUnifiedProjectList {
        SupermuxUnifiedProjects.merge(
            local: locals,
            devices: devices.map { SupermuxUnifiedProjects.DeviceProjects(device: $0.0, projects: $0.1) }
        )
    }

    // 1, 2
    @Test func sameOriginMergesAcrossSpellingsIntoOneProjectWithTwoLocations() throws {
        let app = local("app", root: "/Users/me/dev/app", origin: "git@github.com:acme/app.git")
        let remoteID = UUID()
        let list = merge([app], [(studio, [remote("app-remote", root: "/Users/other/code/app", origin: "https://github.com/acme/app", id: remoteID)])])
        #expect(list.projects.count == 1)
        let project = try #require(list.projects.first)
        #expect(project.id == app.project.id)
        #expect(project.name == "app")
        #expect(project.locations.count == 2)
        #expect(project.locations[0].isThisMac)
        #expect(project.locations[0].projectID == app.project.id)
        #expect(project.locations[1].device == studio)
        #expect(project.locations[1].projectID == remoteID)
        #expect(project.locations[1].rootPath == "/Users/other/code/app")
    }

    // 3 (local side ambiguous)
    @Test func ambiguousLocalOriginFallsBackToNameAndRoot() {
        let origin = "git@github.com:acme/app.git"
        let first = local("app", root: "/r/app", origin: origin)
        let second = local("app-copy", root: "/r/app-copy", origin: origin)
        let list = merge([first, second], [(studio, [remote("app-copy", root: "/r/app-copy", origin: origin)])])
        #expect(list.projects.count == 2)
        #expect(list.projects[0].locations.count == 1)
        #expect(list.projects[1].id == second.project.id)
        #expect(list.projects[1].locations.count == 2)
    }

    // 3 (device side ambiguous)
    @Test func ambiguousDeviceOriginFallsBackToNameAndRoot() {
        let origin = "git@github.com:acme/app.git"
        let app = local("app", root: "/r/app", origin: origin)
        let list = merge([app], [(studio, [
            remote("app", root: "/r/app", origin: origin),
            remote("app-scratch", root: "/r/scratch", origin: origin),
        ])])
        #expect(list.projects.count == 2)
        #expect(list.projects[0].locations.count == 2)
        #expect(list.projects[1].isRemoteOnly)
        #expect(list.projects[1].name == "app-scratch")
    }

    // 4
    @Test func differentOriginsNeverMergeEvenWithSameNameAndRoot() {
        let app = local("app", root: "/r/app", origin: "git@github.com:acme/app.git")
        let list = merge([app], [(studio, [remote("app", root: "/r/app", origin: "git@github.com:fork/app.git")])])
        #expect(list.projects.count == 2)
        #expect(list.projects[1].isRemoteOnly)
    }

    // 5
    @Test func originlessProjectsMergeOnlyOnIdenticalNameAndRoot() {
        let notes = local("notes", root: "/Users/me/notes")
        let list = merge([notes], [(studio, [
            remote("notes", root: "/Users/me/notes/"),
            remote("notes", root: "/Users/other/notes"),
        ])])
        #expect(list.projects.count == 2)
        #expect(list.projects[0].locations.count == 2, "a trailing slash is the same root")
        #expect(list.projects[1].isRemoteOnly, "same name, different root stays separate")
    }

    // 6
    @Test func aLocalProjectClaimsAtMostOneProjectPerDevice() {
        let notes = local("notes", root: "/r/notes")
        let list = merge([notes], [(studio, [remote("notes", root: "/r/notes"), remote("notes", root: "/r/notes")])])
        #expect(list.projects[0].locations.count == 2)
        #expect(list.projects.count == 2)
        #expect(list.projects[1].isRemoteOnly)
    }

    // 7
    @Test func aRepoOnTwoDevicesGetsThreeLocationsInDeviceOrder() {
        let origin = "https://github.com/acme/app.git"
        let app = local("app", root: "/r/app", origin: origin)
        let list = merge([app], [
            (studio, [remote("app", root: "/s/app", origin: origin)]),
            (laptop, [remote("app", root: "/l/app", origin: origin)]),
        ])
        #expect(list.projects.count == 1)
        #expect(list.projects[0].locations.map(\.machineID) == [nil, studio.machineID, laptop.machineID])
    }

    // 8
    @Test func remoteOnlyProjectsFollowLocalsGroupedByDeviceThenName() {
        let a = local("zeta", root: "/r/zeta")
        let b = local("alpha", root: "/r/alpha")
        let list = merge([a, b], [
            (studio, [remote("web", root: "/s/web"), remote("api", root: "/s/api")]),
            (laptop, [remote("Docs", root: "/l/docs"), remote("cli", root: "/l/cli")]),
        ])
        #expect(list.projects.map(\.name) == ["zeta", "alpha", "api", "web", "cli", "Docs"])
        #expect(list.remoteOnly.map(\.name) == ["api", "web", "cli", "Docs"])
    }

    // 9
    @Test func idsAreStableAndRemoteOnlyIdsAreDerived() throws {
        let remoteID = UUID()
        let dto = remote("api", root: "/s/api", id: remoteID)
        let first = merge([], [(studio, [dto])])
        let second = merge([], [(studio, [dto])])
        let onLaptop = merge([], [(laptop, [dto])])
        let id = try #require(first.projects.first?.id)
        #expect(id == second.projects.first?.id)
        #expect(id != remoteID, "a remote Mac's project UUID is never reused as a unified id")
        #expect(id != onLaptop.projects.first?.id)
        #expect(id == SupermuxUnifiedProjects.remoteOnlyID(machineID: studio.machineID, projectID: remoteID))
    }

    // 10
    @Test func aRemoteIdEqualToALocalIdDoesNotAliasTheLocalProject() throws {
        let sharedID = UUID()
        let app = local("app", root: "/r/app", origin: "git@github.com:acme/app.git", id: sharedID)
        let list = merge([app], [(studio, [remote("other", root: "/r/other", id: sharedID)])])
        #expect(list.projects.count == 2)
        let remoteOnly = try #require(list.remoteOnly.first)
        #expect(list.projectID(onMachine: studio.machineID, remoteProjectID: sharedID) == remoteOnly.id)
        #expect(list.projectID(forLocalProject: sharedID) == sharedID)
    }

    // 10 (loopback: both sides share one list, ids equal)
    @Test func loopbackStyleSharedListMergesEveryProject() {
        let app = local("app", root: "/r/app", origin: "git@github.com:acme/app.git")
        let notes = local("notes", root: "/r/notes")
        let loop = SupermuxProjectDevice(machineID: "device:5e1f@rws", name: "Loopback Mac", isOnline: true)
        let list = merge([app, notes], [(loop, [
            remote("app", root: "/r/app", origin: "git@github.com:acme/app.git", id: app.project.id),
            remote("notes", root: "/r/notes", id: notes.project.id),
        ])])
        #expect(list.projects.count == 2)
        #expect(list.remoteOnly.isEmpty)
        #expect(list.projects.allSatisfy { $0.locations.count == 2 })
    }

    // 11
    @Test func offlineDevicesKeepTheirLocationsMarkedOffline() throws {
        let offline = SupermuxProjectDevice(machineID: studio.machineID, name: "Studio", isOnline: false)
        let list = merge([], [(offline, [remote("api", root: "/s/api")])])
        let location = try #require(list.projects.first?.locations.first)
        #expect(!location.isOnline)
        #expect(!location.isThisMac)
    }

    // 12
    @Test func malformedAndDuplicateRemoteIdsAreDropped() {
        let id = UUID()
        let list = merge([], [(studio, [
            SupermuxProjectDTO(id: "not-a-uuid", name: "bad", rootPath: "/s/bad"),
            remote("api", root: "/s/api", id: id),
            remote("api-dup", root: "/s/api2", id: id),
        ])])
        #expect(list.projects.map(\.name) == ["api"])
    }

    // 13
    @Test func lookupsResolveLocationsPerMac() throws {
        let app = local("app", root: "/r/app", origin: "git@github.com:acme/app.git")
        let remoteID = UUID()
        let list = merge([app], [(studio, [remote("app", root: "/x/app", origin: "git@github.com:acme/app.git", id: remoteID)])])
        #expect(list.projectID(onMachine: studio.machineID, remoteProjectID: remoteID) == app.project.id)
        #expect(list.projectID(onMachine: laptop.machineID, remoteProjectID: remoteID) == nil)
        #expect(list.projectID(onMachine: studio.machineID, remoteProjectID: app.project.id) == nil)
        #expect(list.projectID(forLocalProject: remoteID) == nil)
        let project = try #require(list.project(id: app.project.id))
        #expect(project.location(onMachine: studio.machineID)?.projectID == remoteID)
        #expect(project.localLocation?.projectID == app.project.id)
        #expect(project.remoteLocations.count == 1)
    }

    @Test func devicesLackingAProjectExcludeDevicesThatHaveIt() throws {
        let app = local("app", root: "/r/app", origin: "git@github.com:acme/app.git")
        let list = merge([app], [(studio, [remote("app", root: "/r/app", origin: "git@github.com:acme/app.git")])])
        let project = try #require(list.projects.first)
        #expect(project.devicesLacking(among: [studio, laptop]) == [laptop])
    }
}
