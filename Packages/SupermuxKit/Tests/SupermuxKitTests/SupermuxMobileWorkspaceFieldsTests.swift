import Foundation
import SupermuxKit
import SupermuxMobileCore
import Testing

/// RPC-WSL-01: the workspace-list augmenter core. A workspace associated to a
/// fixture project with a known activity state yields `supermux_project_id`
/// equal to the project id and `supermux_activity` in
/// `{working, needs_input, ready}`. Active global workspaces carry activity too,
/// while the project-specific branch field remains association-gated.
@MainActor
struct SupermuxMobileWorkspaceFieldsTests {
    private func fields(
        workspaceID: UUID = UUID(),
        directory: String? = nil,
        activity: SupermuxWorkspaceActivity,
        branch: String? = nil,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> [String: Any] {
        SupermuxMobileWorkspaceFields.fields(
            workspaceID: workspaceID,
            directory: directory,
            activity: activity,
            branch: branch,
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

    @Test func unassociatedWorkspaceCarriesWorkingActivityWithoutProjectID() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")

        let payload = fields(
            workspaceID: UUID(),
            directory: "/elsewhere",
            activity: .working,
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.projectIDKey] == nil)
        #expect(payload[SupermuxMobileWorkspaceFields.activityKey] as? String == "working")
        #expect(payload.count == 1)
    }

    @Test func unassociatedIdleWorkspaceCarriesNoFields() {
        let payload = fields(
            workspaceID: UUID(),
            directory: "/elsewhere",
            activity: .idle,
            projects: [],
            associations: SupermuxWorkspaceAssociationStore()
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

    // MARK: - m6-f2 sidebar-row parity field (supermux_branch)

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

    @Test func unassociatedWorkspaceOmitsProjectParityFieldsButKeepsActivity() {
        let store = SupermuxWorkspaceAssociationStore()
        let project = SupermuxProject(name: "Alpha", rootPath: "/repos/alpha")

        let payload = fields(
            workspaceID: UUID(),
            directory: "/elsewhere",
            activity: .working,
            branch: "main",
            projects: [project],
            associations: store
        )

        #expect(payload[SupermuxMobileWorkspaceFields.projectIDKey] == nil)
        #expect(payload[SupermuxMobileWorkspaceFields.activityKey] as? String == "working")
        #expect(payload[SupermuxMobileWorkspaceFields.branchKey] == nil)
        #expect(payload.count == 1)
    }
}
