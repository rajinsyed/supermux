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
    /// Transient progress text shown while AI names the branch / git creates it.
    @State private var statusMessage: String?
    /// Whether AI branch naming is wired and a key is configured (probed on
    /// appear for the hint; re-checked freshly at submit time).
    @State private var aiNamingConfigured = false
    /// The in-flight create work, retained so Cancel / dismiss can abort it
    /// before it (slowly) names a branch and creates a worktree.
    @State private var createTask: Task<Void, Never>?

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
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .onAppear {
            focusedField = .workspace
            Task { aiNamingConfigured = await model.isAIBranchNamingConfigured() }
        }
        // If the sheet goes away while a (possibly slow, AI-naming) create is in
        // flight, abort it so no worktree is created behind the user's back.
        .onDisappear { createTask?.cancel() }
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
            .disabled(isCreating)
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
            .disabled(isCreating)
            Text(branchHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                createTask?.cancel()
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
        // Branch field is blank: when AI naming is configured and a workspace
        // name is present, the branch is derived from it; otherwise a friendly
        // random name is used.
        if aiNamingConfigured, !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                localized: "supermux.newWorktree.branch.aiHint",
                defaultValue: "AI will suggest a branch name from the workspace name; a random name is used if that fails."
            )
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
        let trimmedBranch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        createTask = Task {
            var branchToUse = branchInput
            // Only invoke AI when the user left the branch blank but named the
            // workspace; a typed branch is always respected verbatim. The
            // configured check is done freshly here (not the on-appear cache) so
            // a key pasted after the sheet opened is still used.
            if trimmedBranch.isEmpty, !trimmedName.isEmpty,
               await model.isAIBranchNamingConfigured() {
                statusMessage = String(
                    localized: "supermux.newWorktree.status.naming",
                    defaultValue: "Generating branch name with AI…"
                )
                if let suggestion = await model.suggestBranchName(forWorkspaceName: trimmedName) {
                    branchToUse = suggestion
                }
            }
            statusMessage = nil
            // The user may have cancelled/dismissed during the AI await; if so,
            // do not create a worktree behind their back.
            if Task.isCancelled {
                isCreating = false
                return
            }
            do {
                let worktree = try await model.createWorktree(
                    projectId: project.id,
                    branchName: branchToUse,
                    baseBranch: nil
                )
                guard !Task.isCancelled else { return }
                onCreated(worktree, trimmedName.isEmpty ? nil : trimmedName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
