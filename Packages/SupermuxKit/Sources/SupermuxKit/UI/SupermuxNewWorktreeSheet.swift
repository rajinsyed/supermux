public import SwiftUI
import Foundation

/// Modal sheet for creating a git worktree (with a fresh branch) in a project.
///
/// Kept deliberately minimal — a workspace name and an optional branch name —
/// to mirror piggycode's frictionless flow. Leaving the branch blank generates
/// a friendly random name; the base branch is the project's default. Presented
/// via `.sheet(item:)` from ``SupermuxProjectsSectionView``, so it owns no
/// presentation binding and dismisses itself through the environment. Creation
/// is delegated to ``SupermuxProjectsModel/createWorktree(projectId:branchName:baseBranch:)``;
/// the new worktree and chosen workspace name are handed back through a callback
/// so the host can open a workspace in it.
public struct SupermuxNewWorktreeSheet: View {
    private let model: SupermuxProjectsModel
    private let project: SupermuxProject
    private let onCreated: (SupermuxProjectWorktree, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var workspaceName = ""
    @State private var branchInput = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private enum Field { case workspace, branch }

    /// Creates the sheet.
    /// - Parameters:
    ///   - model: Shared projects model that performs the git work.
    ///   - project: Project the worktree is created in.
    ///   - onCreated: Called after a successful create with the new worktree and
    ///     the chosen workspace name (`nil` when left blank).
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        onCreated: @escaping (SupermuxProjectWorktree, String?) -> Void
    ) {
        self.model = model
        self.project = project
        self.onCreated = onCreated
    }

    /// The sheet content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            workspaceField
            branchField
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focusedField = .workspace }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "supermux.newWorktree.title", defaultValue: "New Worktree"))
                .font(.headline)
            Text(project.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                String(localized: "supermux.newWorktree.workspace.placeholder", defaultValue: "Workspace name"),
                text: $workspaceName
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .workspace)
            .onSubmit(create)
        }
    }

    private var branchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                String(
                    localized: "supermux.newWorktree.branch.placeholder.optional",
                    defaultValue: "Branch name (optional)"
                ),
                text: $branchInput
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .branch)
            .onSubmit(create)
            Text(branchHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(action: create) {
                HStack(spacing: 5) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(String(localized: "supermux.newWorktree.create", defaultValue: "Create"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating)
        }
    }

    // MARK: - State

    /// The branch field is optional, so creation is only blocked while a git
    /// command is already in flight.
    private var canCreate: Bool { !isCreating }

    /// Subtitle under the branch field: a sanitized preview when the typed name
    /// differs from what git will use, or a note that a name will be generated.
    private var branchHint: String {
        if let sanitized = SupermuxBranchName().sanitize(branchInput) {
            if sanitized != branchInput.trimmingCharacters(in: .whitespacesAndNewlines) {
                return String(
                    localized: "supermux.newWorktree.branch.preview",
                    defaultValue: "Will be created as “\(sanitized)”"
                )
            }
            return ""
        }
        return String(
            localized: "supermux.newWorktree.branch.randomHint",
            defaultValue: "Leave blank for a random name like “cheerful-umbrella”"
        )
    }

    // MARK: - Actions

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let worktree = try await model.createWorktree(
                    projectId: project.id,
                    branchName: branchInput,
                    baseBranch: nil
                )
                onCreated(worktree, trimmedName.isEmpty ? nil : trimmedName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
