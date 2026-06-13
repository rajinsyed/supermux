public import SwiftUI
import Foundation

/// Modal sheet for creating a git worktree (with a fresh branch) in a project.
///
/// Presented via `.sheet(item:)` from ``SupermuxProjectsSectionView``, so it
/// owns no presentation binding and dismisses itself through the environment.
/// Creation is delegated to
/// ``SupermuxProjectsModel/createWorktree(projectId:branchName:baseBranch:)``;
/// the resulting worktree is handed back through a callback so the host can
/// open a workspace in it.
public struct SupermuxNewWorktreeSheet: View {
    private let model: SupermuxProjectsModel
    private let project: SupermuxProject
    private let onCreated: (SupermuxProjectWorktree) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isBranchFieldFocused: Bool
    @State private var branchInput = ""
    @State private var baseBranch = ""
    @State private var localBranches: [String] = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Creates the sheet.
    /// - Parameters:
    ///   - model: Shared projects model that performs the git work.
    ///   - project: Project the worktree is created in.
    ///   - onCreated: Called with the new worktree after a successful create.
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        onCreated: @escaping (SupermuxProjectWorktree) -> Void
    ) {
        self.model = model
        self.project = project
        self.onCreated = onCreated
    }

    /// The sheet content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            branchField
            basePicker
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
        .task { await load() }
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

    private var branchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                String(localized: "supermux.newWorktree.branch.placeholder", defaultValue: "Branch name"),
                text: $branchInput
            )
            .textFieldStyle(.roundedBorder)
            .focused($isBranchFieldFocused)
            .onSubmit(create)
            if let preview = sanitizedPreview {
                Text(String(
                    localized: "supermux.newWorktree.branch.preview",
                    defaultValue: "Will be created as “\(preview)”"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var basePicker: some View {
        Picker(
            String(localized: "supermux.newWorktree.base.label", defaultValue: "Base branch"),
            selection: $baseBranch
        ) {
            Text(String(localized: "supermux.newWorktree.base.default", defaultValue: "Default (HEAD)"))
                .tag("")
            ForEach(localBranches, id: \.self) { branch in
                Text(branch).tag(branch)
            }
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
            .disabled(!canCreate)
        }
    }

    // MARK: - State

    private var canCreate: Bool {
        !branchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    private var sanitizedPreview: String? {
        guard let sanitized = SupermuxBranchName().sanitize(branchInput),
              sanitized != branchInput else { return nil }
        return sanitized
    }

    // MARK: - Actions

    private func load() async {
        isBranchFieldFocused = true
        let branches = await model.localBranches(projectId: project.id)
        localBranches = branches
        if let defaultBranch = project.defaultBranch, branches.contains(defaultBranch) {
            baseBranch = defaultBranch
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let worktree = try await model.createWorktree(
                    projectId: project.id,
                    branchName: branchInput,
                    baseBranch: baseBranch.isEmpty ? nil : baseBranch
                )
                onCreated(worktree)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
