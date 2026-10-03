import Foundation
import SupermuxMobileCore
import Testing

import CmuxFoundation
@testable import SupermuxKit

/// Ways the host's `git_remote_url` fill and the local Mac's remote lookup could fail:
/// Wire payload (`mobile.supermux.projects.list`, `project.create/update`):
/// 1. A resolved origin is not carried on the project's DTO.
/// 2. A project without an origin gets `git_remote_url: ""`/null instead of omitting the key
///    (older phones and Macs must see the exact legacy shape).
/// 3. URLs are matched to the wrong project (keyed by name or id instead of `root_path`).
/// 4. The single-project result drops the origin.
/// Local Mac lookup (`SupermuxProjectGitRemotes`):
/// 5. A refresh leaves projects unresolved or maps a URL to the wrong project id.
/// 6. A project removed from the list keeps a stale URL.
/// 7. The identity is the raw URL instead of the normalized host/owner/repo key, so
///    SSH and HTTPS spellings of one repo on two Macs never match.
@MainActor
struct SupermuxProjectGitRemotesTests {
    private func project(_ name: String, root: String) -> SupermuxProject {
        SupermuxProject(name: name, rootPath: root, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func decodedProjects(_ payload: [String: Any]) throws -> [SupermuxProjectDTO] {
        let raw = try #require(payload["projects"] as? [[String: Any]])
        return try raw.map { try SupermuxWireJSON().decode(SupermuxProjectDTO.self, from: $0) }
    }

    @Test func projectsListCarriesOriginsByRootPath() throws {
        let alpha = project("Alpha", root: "/r/alpha")
        let beta = project("Beta", root: "/r/beta")
        let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
            projects: [alpha, beta],
            presets: [],
            isSectionCollapsed: false,
            gitRemoteURLs: ["/r/alpha": "git@github.com:o/alpha.git"]
        )
        let dtos = try decodedProjects(payload)
        #expect(dtos.first { $0.id == alpha.id.uuidString }?.gitRemoteURL == "git@github.com:o/alpha.git")
        #expect(dtos.first { $0.id == beta.id.uuidString }?.gitRemoteURL == nil)
        let rawBeta = try #require((payload["projects"] as? [[String: Any]])?.first { $0["id"] as? String == beta.id.uuidString })
        #expect(rawBeta["git_remote_url"] == nil, "no origin keeps the legacy wire shape")
    }

    @Test func projectsListWithoutOriginsKeepsTheLegacyShape() throws {
        let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
            projects: [project("Alpha", root: "/r/alpha")],
            presets: [],
            isSectionCollapsed: false
        )
        let raw = try #require((payload["projects"] as? [[String: Any]])?.first)
        #expect(raw["git_remote_url"] == nil)
    }

    @Test func singleProjectPayloadCarriesTheOrigin() throws {
        let alpha = project("Alpha", root: "/r/alpha")
        let payload = try SupermuxMobileProjectsPayloadBuilder().projectPayload(
            project: alpha,
            gitRemoteURL: "https://github.com/o/alpha"
        )
        let raw = try #require(payload["project"] as? [String: Any])
        #expect(raw["git_remote_url"] as? String == "https://github.com/o/alpha")
    }

    @Test func localLookupResolvesByProjectAndDropsRemovedProjects() async {
        let alpha = project("Alpha", root: "/r/alpha")
        let beta = project("Beta", root: "/r/beta")
        let gamma = project("Gamma", root: "/r/gamma")
        let resolver = SupermuxGitRemoteURLResolver(runner: OriginRunner(origins: [
            "/r/alpha": "git@github.com:o/alpha.git",
            "/r/beta": "https://github.com/o/beta",
        ]))
        let remotes = SupermuxProjectGitRemotes(resolver: resolver)

        await remotes.refresh(projects: [alpha, beta, gamma])
        #expect(remotes.url(for: alpha.id) == "git@github.com:o/alpha.git")
        #expect(remotes.url(for: beta.id) == "https://github.com/o/beta")
        #expect(remotes.url(for: gamma.id) == nil)
        #expect(remotes.urlsByProjectID.count == 2)

        await remotes.refresh(projects: [beta])
        #expect(remotes.url(for: alpha.id) == nil, "a removed project drops its URL")
        #expect(remotes.url(for: beta.id) == "https://github.com/o/beta")
    }

    @Test func identityIsTheNormalizedRepositoryKey() async {
        let alpha = project("Alpha", root: "/r/alpha")
        let resolver = SupermuxGitRemoteURLResolver(runner: OriginRunner(origins: [
            "/r/alpha": "git@github.com:Owner/alpha.git",
        ]))
        let remotes = SupermuxProjectGitRemotes(resolver: resolver)
        await remotes.refresh(projects: [alpha])
        #expect(remotes.identity(for: alpha.id) == "github.com/Owner/alpha")
        #expect(remotes.identity(for: alpha.id) == SupermuxGitRemoteIdentity.normalized("https://github.com/Owner/alpha"))
    }
}

/// Answers `git config --get remote.origin.url` from a fixed map; exit 1 otherwise.
private struct OriginRunner: CommandRunning {
    let origins: [String: String]

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        guard let origin = origins[directory] else {
            return CommandResult(stdout: "", stderr: nil, exitStatus: 1, timedOut: false, executionError: nil)
        }
        return CommandResult(stdout: origin + "\n", stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
    }
}
