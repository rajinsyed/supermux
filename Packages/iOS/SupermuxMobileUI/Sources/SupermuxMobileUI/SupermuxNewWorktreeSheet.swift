public import SwiftUI

/// Modal sheet for creating a git worktree in a project from the phone — the
/// mobile counterpart of the desktop's New Worktree sheet.
///
/// A workspace name, an optional branch name with an AI-suggest button
/// (`worktree.suggest_branch` mac-side: AI when configured, friendly-random
/// otherwise), and an open-after-create toggle. The heavy lifting stays on
/// the Mac; this view holds only closures onto the worktrees store, so it
/// crosses the snapshot boundary cleanly. On a successful create with
/// open-after-create on, it navigates to the new workspace through the same
/// closure the shell's workspace rows use, then dismisses itself.
public struct SupermuxNewWorktreeSheet: View {
    private let projectName: String
    private let suggestBranch: @MainActor (_ workspaceName: String?) async throws -> String
    private let createWorktree: @MainActor (
        _ workspaceName: String?,
        _ branchName: String?,
        _ open: Bool
    ) async throws -> String?
    private let openWorkspace: @MainActor (_ workspaceID: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workspaceName = ""
    @State private var branchName = ""
    @State private var openAfterCreate = true
    @State private var isSuggesting = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Creates the sheet.
    /// - Parameters:
    ///   - projectName: The project's display name (subtitle).
    ///   - suggestBranch: Asks the Mac for a branch-name suggestion.
    ///   - createWorktree: Creates the worktree; returns the opened
    ///     workspace's id when the Mac opened one.
    ///   - openWorkspace: Navigates to a workspace by id — the same closure
    ///     the shell's workspace rows use.
    public init(
        projectName: String,
        suggestBranch: @escaping @MainActor (_ workspaceName: String?) async throws -> String,
        createWorktree: @escaping @MainActor (
            _ workspaceName: String?,
            _ branchName: String?,
            _ open: Bool
        ) async throws -> String?,
        openWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in }
    ) {
        self.projectName = projectName
        self.suggestBranch = suggestBranch
        self.createWorktree = createWorktree
        self.openWorkspace = openWorkspace
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(
                            localized: "supermux.newWorktree.workspace.placeholder",
                            defaultValue: "Workspace name",
                            bundle: .module
                        ),
                        text: $workspaceName
                    )
                    .disabled(isCreating)
                    HStack(spacing: 8) {
                        TextField(
                            String(
                                localized: "supermux.newWorktree.branch.placeholder",
                                defaultValue: "Branch name (optional)",
                                bundle: .module
                            ),
                            text: $branchName
                        )
                        .disabled(isCreating)
                        if isSuggesting {
                            ProgressView()
                        } else {
                            Button(action: suggest) {
                                Image(systemName: "wand.and.stars")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isCreating)
                            .accessibilityLabel(String(
                                localized: "supermux.newWorktree.suggest",
                                defaultValue: "Suggest a branch name",
                                bundle: .module
                            ))
                            .accessibilityIdentifier("SupermuxSuggestBranchButton")
                        }
                    }
                } footer: {
                    Text(String(
                        localized: "supermux.newWorktree.branch.hint",
                        defaultValue: "Leave the branch blank and the Mac picks a name — AI-suggested when configured, a friendly random name otherwise.",
                        bundle: .module
                    ))
                }
                Section {
                    Toggle(isOn: $openAfterCreate) {
                        Text(String(
                            localized: "supermux.newWorktree.openAfterCreate",
                            defaultValue: "Open after creating",
                            bundle: .module
                        ))
                    }
                    .disabled(isCreating)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(
                localized: "supermux.newWorktree.title",
                defaultValue: "New Worktree",
                bundle: .module
            ))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(String(
                            localized: "supermux.common.cancel",
                            defaultValue: "Cancel",
                            bundle: .module
                        ))
                    }
                    .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text(String(
                                localized: "supermux.newWorktree.create",
                                defaultValue: "Create",
                                bundle: .module
                            ))
                        }
                    }
                    .disabled(isCreating)
                    .accessibilityIdentifier("SupermuxCreateWorktreeButton")
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        .accessibilityIdentifier("SupermuxNewWorktreeSheet")
    }

    // MARK: - Actions

    /// Fills the branch field from the Mac's suggestion (AI when configured
    /// mac-side; friendly-random otherwise). Never overwrites while a create
    /// is running.
    private func suggest() {
        guard !isSuggesting, !isCreating else { return }
        isSuggesting = true
        errorMessage = nil
        Task {
            defer { isSuggesting = false }
            do {
                branchName = try await suggestBranch(workspaceName)
            } catch {
                errorMessage = String(
                    localized: "supermux.newWorktree.error.suggestFailed",
                    defaultValue: "Couldn’t suggest a branch name.",
                    bundle: .module
                )
            }
        }
    }

    /// Creates the worktree on the Mac; on success navigates to the opened
    /// workspace (when requested) and dismisses. Errors show inline and the
    /// form stays editable for another attempt.
    private func create() {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let workspaceID = try await createWorktree(workspaceName, branchName, openAfterCreate)
                if openAfterCreate, let workspaceID {
                    openWorkspace(workspaceID)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
