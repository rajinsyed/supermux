import Foundation
import SupermuxMobileCore
import Testing

@testable import SupermuxKit

/// Ways project sync between two Macs could do damage (written before the code):
/// 1. A project without an origin is registered by path alone (a different
///    folder that merely sits at the same path on the other Mac).
/// 2. A project the destination already has (same origin, or same root) is
///    registered twice.
/// 3. A folder that is missing, a plain file, not a git repo, or a DIFFERENT
///    repo at the same path gets registered (sync must never clone or guess).
/// 4. A project the destination's user removed comes straight back.
/// 5. Copied settings overwrite config-owned fields (run/setup/teardown/actions)
///    on a project whose repo ships `.supermux/config.json`.
/// 6. Copied settings drop fields the source defines, or null out fields the
///    source leaves unset.
struct SupermuxProjectSyncPlannerTests {
    private let origin = "git@github.com:acme/app.git"

    private func dto(_ name: String, root: String, origin: String? = nil) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: UUID().uuidString, name: name, rootPath: root, gitRemoteURL: origin)
    }

    private func probe(
        exists: Bool = true,
        isDirectory: Bool = true,
        isGitRepo: Bool = true,
        origin: String? = "https://github.com/acme/app",
        isSuppressed: Bool = false
    ) -> SupermuxProjectProbeDTO {
        SupermuxProjectProbeDTO(
            rootPath: "/r/app",
            exists: exists,
            isDirectory: isDirectory,
            isGitRepo: isGitRepo,
            gitRemoteURL: origin,
            isSuppressed: isSuppressed
        )
    }

    // 1, 2
    @Test func candidatesAreOriginBackedProjectsTheDestinationLacks() {
        let app = dto("app", root: "/r/app", origin: origin)
        let notes = dto("notes", root: "/r/notes")
        let web = dto("web", root: "/r/web", origin: "git@github.com:acme/web.git")
        let api = dto("api", root: "/r/api", origin: "git@github.com:acme/api.git")
        let destination = [
            dto("web-elsewhere", root: "/x/web", origin: "https://github.com/acme/web"),
            dto("api", root: "/r/api"),
        ]
        let candidates = SupermuxProjectSyncPlanner.candidates(source: [app, notes, web, api], destination: destination)
        #expect(candidates.map(\.name) == ["app"])
    }

    // 3
    @Test func onlyAnExistingRepoWithTheSameOriginIsRegistered() {
        let app = dto("app", root: "/r/app", origin: origin)
        #expect(SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe()))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(exists: false)))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(isDirectory: false)))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(isGitRepo: false)))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(origin: nil)))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(origin: "git@github.com:fork/app.git")))
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(dto("app", root: "/r/app"), probe: probe()))
    }

    // 4
    @Test func aSuppressedRootIsNeverRegistered() {
        let app = dto("app", root: "/r/app", origin: origin)
        #expect(!SupermuxProjectSyncPlanner.shouldRegister(app, probe: probe(isSuppressed: true)))
    }

    // 5
    @Test func configManagedDestinationsKeepTheirConfigOwnedFields() {
        var source = dto("App", root: "/r/app", origin: origin)
        source.runCommands = ["bun dev"]
        source.setupCommands = ["bun install"]
        source.teardownCommands = ["docker compose down"]
        source.actions = [SupermuxProjectActionDTO(id: UUID().uuidString, name: "Open", command: "open .")]
        let patch = SupermuxProjectSyncPlanner.settingsPatch(from: source, destinationIsConfigManaged: true)
        #expect(patch["name"] as? String == "App")
        for key in ["run_commands", "setup_commands", "teardown_commands", "actions"] {
            #expect(patch[key] == nil, "\(key) is config-owned")
        }
    }

    // 6
    @Test func userOwnedDestinationsGetEveryDefinedSetting() throws {
        var source = dto("App", root: "/r/app", origin: origin)
        source.colorHex = "#FF8800"
        source.iconSymbol = "hammer"
        source.defaultBranch = "develop"
        source.runCommands = ["bun dev"]
        source.setupCommands = []
        source.teardownCommands = ["make clean"]
        let actionID = UUID().uuidString
        source.actions = [SupermuxProjectActionDTO(id: actionID, name: "Open", command: "open .", iconSymbol: "globe")]
        let patch = SupermuxProjectSyncPlanner.settingsPatch(from: source, destinationIsConfigManaged: false)
        #expect(patch["name"] as? String == "App")
        #expect(patch["color_hex"] as? String == "#FF8800")
        #expect(patch["icon_symbol"] as? String == "hammer")
        #expect(patch["default_branch"] as? String == "develop")
        #expect(patch["run_commands"] as? [String] == ["bun dev"])
        #expect(patch["setup_commands"] as? [String] == [])
        #expect(patch["teardown_commands"] as? [String] == ["make clean"])
        let actions = try #require(patch["actions"] as? [[String: Any]])
        #expect(actions.first?["id"] as? String == actionID)
        #expect(actions.first?["icon_symbol"] as? String == "globe")
        // The patch must parse with the host's own patch reader.
        _ = try SupermuxMobileProjectPatch(wire: patch)
    }

    /// 7. Sync ships disabled, or an explicit opt-out does not stick.
    @Test func syncProjectsDefaultsOnAndPersistsAnOptOut() throws {
        let suite = "supermux.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SupermuxDevicesSettings.syncProjectsKey == "supermux.devices.syncProjects")
        let settings = SupermuxDevicesSettings(defaults: defaults)
        #expect(settings.syncProjects)
        settings.syncProjects = false
        #expect(SupermuxDevicesSettings(defaults: defaults).syncProjects == false)
    }

    // 6
    @Test func unsetOptionalsAreOmittedNotNulled() {
        let source = dto("App", root: "/r/app", origin: origin)
        let patch = SupermuxProjectSyncPlanner.settingsPatch(from: source, destinationIsConfigManaged: false)
        for key in ["color_hex", "icon_symbol", "default_branch", "run_commands", "actions"] {
            #expect(patch[key] == nil, "\(key) is unset on the source")
        }
    }
}
