import Foundation
import SupermuxKit
import SupermuxMobileCore
import Testing

/// RPC-WSL-01: the workspace-list augmenter core. A workspace associated to a
/// fixture project with a known activity state yields `supermux_project_id`
/// equal to the project id and `supermux_activity` in
/// `{working, needs_input, ready}`; a workspace with no association carries
/// NEITHER field (per the validation contract, activity travels only for
/// project-associated workspaces).
@MainActor
struct SupermuxMobileWorkspaceFieldsTests {
    private func fields(
        workspaceID: UUID = UUID(),
        directory: String? = nil,
        activity: SupermuxWorkspaceActivity,
        branch: String? = nil,
        pullRequest: SupermuxPullRequest? = nil,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> [String: Any] {
        SupermuxMobileWorkspaceFields.fields(
            workspaceID: workspaceID,
            directory: directory,
            activity: activity,
            branch: branch,
            pullRequest: pullRequest,
            projects: projects,
            associations: associations
        )
    }

    @Test func associatedWorkspaceCarriesProjectIDAndWorkingActivity() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            directory: "/elsewhere",
            activity: .working,
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.projectIDKey] as? String == project.id.uuidString)
        #expect(payload[SupermuxMobileWorkspaceFields.activityKey] as? String == "working")
    }

    @Test func associatedActivityValuesUseTheWireDTOSpelling() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let allowed = Set(SupermuxWorkspaceActivityDTO.allCases.map(\.rawValue))
        #expect(allowed == ["working", "needs_input", "ready"])

        for (activity, expected) in [
            (SupermuxWorkspaceActivity.working, "working"),
            (.needsInput, "needs_input"),
            (.ready, "ready"),
        ] {
            let workspaceID = UUID()
            store.associate(workspaceId: workspaceID, projectId: project.id)
            let payload = fields(
                workspaceID: workspaceID,
                activity: activity,
                projects: [project],
                associations: store
            )
            let raw = payload[SupermuxMobileWorkspaceFields.activityKey] as? String
            #expect(raw == expected)
            #expect(raw.map(allowed.contains) == true)
        }
    }

    @Test func associatedIdleWorkspaceCarriesProjectIDButNoActivity() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            activity: .idle,
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.projectIDKey] as? String == project.id.uuidString)
        #expect(payload[SupermuxMobileWorkspaceFields.activityKey] == nil)
    }

    @Test func unassociatedWorkspaceCarriesNeitherFieldEvenWhenActive() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")

        // No association, directory unrelated to any project, agent working:
        // the payload must stay empty (RPC-WSL-01's "neither field" clause).
        let payload = fields(
            workspaceID: UUID(),
            directory: "/elsewhere",
            activity: .working,
            projects: [project],
            associations: store
        )

        #expect(payload.isEmpty)
    }

    @Test func worktreeDirectoryAssociationResolvesLikeTheSidebar() {
        // Same durable signal the Mac sidebar nests by: a workspace living in
        // the project's worktrees dir is associated without an explicit link.
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")

        let payload = fields(
            workspaceID: UUID(),
            directory: "/repos/alpha/.worktrees/feature",
            activity: .ready,
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.projectIDKey] as? String == project.id.uuidString)
        #expect(payload[SupermuxMobileWorkspaceFields.activityKey] as? String == "ready")
    }

    @Test func activityMappingToTheWireDTOOmitsIdle() {
        #expect(SupermuxWorkspaceActivity.working.mobileWireDTO == .working)
        #expect(SupermuxWorkspaceActivity.needsInput.mobileWireDTO == .needsInput)
        #expect(SupermuxWorkspaceActivity.ready.mobileWireDTO == .ready)
        #expect(SupermuxWorkspaceActivity.idle.mobileWireDTO == nil)
    }

    // MARK: - m6-f2 sidebar-row parity fields (supermux_branch / supermux_pull_request)

    @Test func associatedWorkspaceCarriesItsBranch() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            activity: .idle,
            branch: "feature/parity",
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.branchKey] as? String == "feature/parity")
    }

    @Test func blankOrNilBranchIsOmitted() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        for branch in [nil, "", "   "] as [String?] {
            let workspaceID = UUID()
            store.associate(workspaceId: workspaceID, projectId: project.id)
            let payload = fields(
                workspaceID: workspaceID,
                activity: .idle,
                branch: branch,
                projects: [project],
                associations: store
            )
            #expect(payload[SupermuxMobileWorkspaceFields.branchKey] == nil)
        }
    }

    @Test func associatedWorkspaceCarriesItsPullRequestAsTheSharedDTOShape() throws {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            activity: .working,
            pullRequest: SupermuxPullRequest(
                number: 4321,
                status: .merged,
                url: try #require(URL(string: "https://github.com/acme/alpha/pull/4321"))
            ),
            projects: [project],
            associations: store
        )

        // Same wire shape as the worktree DTO's pull_request (SupermuxPullRequestDTO),
        // so the phone's badge mapping is shared, not duplicated. A fresh
        // badge omits is_stale entirely.
        let pullRequest = try #require(payload[SupermuxMobileWorkspaceFields.pullRequestKey] as? [String: Any])
        #expect(pullRequest["number"] as? Int == 4321)
        #expect(pullRequest["state"] as? String == "merged")
        #expect(pullRequest["url"] as? String == "https://github.com/acme/alpha/pull/4321")
        #expect(pullRequest["is_stale"] == nil)
    }

    @Test func stalePullRequestCarriesIsStale() throws {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            activity: .idle,
            pullRequest: SupermuxPullRequest(
                number: 9,
                status: .open,
                url: try #require(URL(string: "https://github.com/acme/alpha/pull/9")),
                isStale: true
            ),
            projects: [project],
            associations: store
        )

        let pullRequest = try #require(payload[SupermuxMobileWorkspaceFields.pullRequestKey] as? [String: Any])
        #expect(pullRequest["is_stale"] as? Bool == true)
    }

    @Test func nilPullRequestIsOmitted() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")
        let workspaceID = UUID()
        store.associate(workspaceId: workspaceID, projectId: project.id)

        let payload = fields(
            workspaceID: workspaceID,
            activity: .ready,
            pullRequest: nil,
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.pullRequestKey] == nil)
    }

    @Test func unassociatedWorkspaceCarriesNoParityFieldsEitherWay() throws {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")

        // Branch + PR present but no association: the payload must stay empty
        // (the §6 rule — supermux fields travel only for associated workspaces).
        let payload = fields(
            workspaceID: UUID(),
            directory: "/elsewhere",
            activity: .working,
            branch: "main",
            pullRequest: SupermuxPullRequest(
                number: 7,
                status: .open,
                url: try #require(URL(string: "https://github.com/acme/alpha/pull/7"))
            ),
            projects: [project],
            associations: store
        )

        #expect(payload.isEmpty)
    }
}
