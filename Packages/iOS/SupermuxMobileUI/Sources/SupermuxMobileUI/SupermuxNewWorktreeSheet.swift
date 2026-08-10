public import SwiftUI

/// Modal sheet for creating a git worktree in a project from the phone — the
/// mobile counterpart of the desktop's New Worktree sheet.
///
/// A workspace name, an optional branch name with an AI-suggest button
/// (`worktree.suggest_branch` mac-side: AI when configured, friendly-random
/// otherwise), a starting-branch picker, and an open-after-create toggle. The
/// heavy lifting stays on the Mac; this view holds only closures onto the
/// worktrees store, so state crosses the snapshot boundary cleanly. On a
/// successful create with
/// open-after-create on, it navigates to the new workspace through the same
/// closure the shell's workspace rows use, then dismisses itself.
public struct SupermuxNewWorktreeSheet: View {
    private let projectName: String
    private let branches: [String]
    private let defaultBaseBranch: String?
    private let showsBaseBranchPicker: Bool
    private let suggestBranch: @MainActor (_ workspaceName: String?) async throws -> String
    private let createWorktree: @MainActor (
        _ workspaceName: String?,
        _ branchName: String?,
        _ baseBranch: String?,
        _ open: Bool
    ) async throws -> String?
    private let openWorkspace: @MainActor (_ workspaceID: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workspaceName = ""
    @State private var branchName = ""
    @State private var baseBranch = ""
    @State private var baseBranchWasEdited = false
    @State private var openAfterCreate = true
    @State private var isSuggesting = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Creates the sheet.
    /// - Parameters:
    ///   - projectName: The project's display name (subtitle).
    ///   - branches: Local branches available as starting points.
    ///   - defaultBaseBranch: The project's configured starting branch, if any.
    ///   - showsBaseBranchPicker: Whether the host supports explicit starting-
    ///     branch selection. New hosts pass `true` even for an empty branch list
    ///     so Repository HEAD remains selectable; older hosts pass `false`.
    ///   - suggestBranch: Asks the Mac for a branch-name suggestion.
    ///   - createWorktree: Creates the worktree; returns the opened
    ///     workspace's id when the Mac opened one.
    ///   - openWorkspace: Navigates to a workspace by id — the same closure
    ///     the shell's workspace rows use.
    public init(
        projectName: String,
        branches: [String],
        defaultBaseBranch: String?,
        showsBaseBranchPicker: Bool = true,
        suggestBranch: @escaping @MainActor (_ workspaceName: String?) async throws -> String,
        createWorktree: @escaping @MainActor (
            _ workspaceName: String?,
            _ branchName: String?,
            _ baseBranch: String?,
            _ open: Bool
        ) async throws -> String?,
        openWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in }
    ) {
        self.projectName = projectName
        self.branches = branches
        self.defaultBaseBranch = defaultBaseBranch
        self.showsBaseBranchPicker = showsBaseBranchPicker
        self.suggestBranch = suggestBranch
        self.createWorktree = createWorktree
        self.openWorkspace = openWorkspace
        _baseBranch = State(initialValue: Self.initialBaseBranch(
            configuredDefault: defaultBaseBranch,
            branches: branches
        ))
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
                if showsBaseBranchPicker {
                    Section {
                        Picker(
                            String(
                                localized: "supermux.newWorktree.base.label",
                                defaultValue: "Start from",
                                bundle: .module
                            ),
                            selection: Binding(
                                get: { baseBranch },
                                set: {
                                    baseBranch = $0
                                    baseBranchWasEdited = true
                                }
                            )
                        ) {
                            Text(String(
                                localized: "supermux.newWorktree.base.default",
                                defaultValue: "Repository HEAD",
                                bundle: .module
                            ))
                            .tag("")
                            ForEach(baseBranchOptions, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        .disabled(isCreating)
                    } footer: {
                        Text(String(
                            localized: "supermux.newWorktree.base.hint",
                            defaultValue: "Includes committed changes from the selected branch. Uncommitted changes aren’t copied.",
                            bundle: .module
                        ))
                    }
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
        .onChange(of: branches, initial: true) { _, _ in
            updateUntouchedBaseBranch()
        }
        .onChange(of: defaultBaseBranch) { _, _ in
            updateUntouchedBaseBranch()
        }
    }

    /// Configured project default first, followed by every local branch, with
    /// duplicates removed while preserving order.
    private var baseBranchOptions: [String] {
        var seen: Set<String> = []
        return ([defaultBaseBranch].compactMap { $0 } + branches).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func initialBaseBranch(configuredDefault: String?, branches: [String]) -> String {
        if let configuredDefault, !configuredDefault.isEmpty {
            return configuredDefault
        }
        return branches.contains("main") ? "main" : ""
    }

    /// An untouched picker defers to the Mac's fresh default resolution; only
    /// an explicit user choice becomes a wire override.
    static func requestedBaseBranch(selection: String, wasEdited: Bool) -> String? {
        guard wasEdited else { return nil }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HEAD" : trimmed
    }

    private var baseBranchForCreate: String? {
        Self.requestedBaseBranch(selection: baseBranch, wasEdited: baseBranchWasEdited)
    }

    private func updateUntouchedBaseBranch() {
        guard !baseBranchWasEdited else { return }
        baseBranch = Self.initialBaseBranch(
            configuredDefault: defaultBaseBranch,
            branches: branches
        )
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
                let workspaceID = try await createWorktree(
                    workspaceName,
                    branchName,
                    baseBranchForCreate,
                    openAfterCreate
                )
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
