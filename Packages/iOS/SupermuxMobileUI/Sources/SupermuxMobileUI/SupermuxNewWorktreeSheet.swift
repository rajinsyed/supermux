public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// Modal sheet for creating a git worktree in a project from the phone — the
/// mobile counterpart of the desktop's New Worktree sheet, including its
/// optional "start Claude in it" path.
///
/// One sheet, two outcomes, chosen by whether the prompt is filled in:
///
/// - **Prompt empty** — the classic flow: workspace name, optional branch
///   (AI-suggest button), starting branch, open-after-create toggle, over
///   `worktree.create`.
/// - **Prompt filled** — a Claude section appears (command / model / effort
///   from the Mac), blank names are derived from the prompt Mac-side, and
///   "Start Claude" sends one `agent.start`: the Mac creates the worktree and
///   opens a workspace already running Claude with the prompt.
///
/// The prompt path shows only when the host advertises
/// `supermux.agent_launch.v1` (an `agentStore` is supplied). Holds only
/// closures and stores, so state crosses the snapshot boundary cleanly.
public struct SupermuxNewWorktreeSheet: View {
    private let projectName: String
    private let branches: [String]
    private let defaultBaseBranch: String?
    private let showsBaseBranchPicker: Bool
    private let agentStore: SupermuxMobileAgentLaunchStore?
    private let suggestBranch: @MainActor (_ workspaceName: String?) async throws -> String
    private let createWorktree: @MainActor (
        _ workspaceName: String?,
        _ branchName: String?,
        _ baseBranch: String?,
        _ open: Bool
    ) async throws -> String?
    private let openWorkspace: @MainActor (_ workspaceID: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
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
    ///     branch selection.
    ///   - agentStore: The agent-launch store, or `nil` to hide the Claude
    ///     path. The sheet loads its options itself, so presenting never
    ///     waits on the Mac's model probe.
    ///   - suggestBranch: Asks the Mac for a branch-name suggestion.
    ///   - createWorktree: Creates a plain worktree; returns the opened
    ///     workspace's id when the Mac opened one.
    ///   - openWorkspace: Navigates to a workspace by id.
    public init(
        projectName: String,
        branches: [String],
        defaultBaseBranch: String?,
        showsBaseBranchPicker: Bool = true,
        agentStore: SupermuxMobileAgentLaunchStore? = nil,
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
        self.agentStore = agentStore
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
                if agentStore != nil {
                    promptSection
                }
                namesSection
                if hasPrompt, let agentStore {
                    SupermuxNewWorktreeClaudeSection(store: agentStore, isBusy: isCreating)
                }
                if showsBaseBranchPicker {
                    baseBranchSection
                }
                if !hasPrompt {
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
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: hasPrompt)
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
                        Text(String(localized: "supermux.common.cancel", defaultValue: "Cancel", bundle: .module))
                    }
                    .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if isCreating {
                            ProgressView()
                        } else if hasPrompt {
                            Text(String(localized: "supermux.newWorktree.startClaude", defaultValue: "Start Claude", bundle: .module))
                                .fontWeight(.semibold)
                        } else {
                            Text(String(localized: "supermux.newWorktree.create", defaultValue: "Create", bundle: .module))
                        }
                    }
                    .disabled(isCreating)
                    .accessibilityIdentifier("SupermuxCreateWorktreeButton")
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        .accessibilityIdentifier("SupermuxNewWorktreeSheet")
        // The Claude options (commands + model catalog) load behind the open
        // sheet: a cold probe can take seconds and must never hold the sheet
        // back from a plain worktree. Picks reset by `selectCommand` keep a
        // Start pressed mid-load on the CLI defaults.
        .task {
            guard let agentStore, !agentStore.hasLoadedOptions else { return }
            await agentStore.loadOptions()
        }
        .onChange(of: branches, initial: true) { _, _ in updateUntouchedBaseBranch() }
        .onChange(of: defaultBaseBranch) { _, _ in updateUntouchedBaseBranch() }
    }

    // MARK: - Sections

    private var promptSection: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.newWorktree.prompt.placeholder",
                    defaultValue: "What should Claude work on? (optional)",
                    bundle: .module
                ),
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(2...8)
            .disabled(isCreating)
            .accessibilityIdentifier("SupermuxAgentPromptField")
        } header: {
            Text(projectName)
        } footer: {
            Text(hasPrompt
                ? String(
                    localized: "supermux.newWorktree.prompt.footer.active",
                    defaultValue: "The Mac names blank fields from this prompt, creates the worktree, and opens Claude in it.",
                    bundle: .module
                )
                : String(
                    localized: "supermux.newWorktree.prompt.footer.idle",
                    defaultValue: "Type a task to start Claude in the new worktree, or leave empty for a plain worktree.",
                    bundle: .module
                ))
        }
    }

    private var namesSection: some View {
        Section {
            TextField(workspacePlaceholder, text: $workspaceName)
                .disabled(isCreating)
            HStack(spacing: 8) {
                TextField(branchPlaceholder, text: $branchName)
                    .disabled(isCreating)
                if !hasPrompt {
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
            }
        } footer: {
            if !hasPrompt {
                Text(String(
                    localized: "supermux.newWorktree.branch.hint",
                    defaultValue: "Leave the branch blank and the Mac picks a name — AI-suggested when configured, a friendly random name otherwise.",
                    bundle: .module
                ))
            }
        }
    }

    private var baseBranchSection: some View {
        Section {
            Picker(
                String(localized: "supermux.newWorktree.base.label", defaultValue: "Start from", bundle: .module),
                selection: Binding(
                    get: { baseBranch },
                    set: {
                        baseBranch = $0
                        baseBranchWasEdited = true
                    }
                )
            ) {
                Text(String(localized: "supermux.newWorktree.base.default", defaultValue: "Repository HEAD", bundle: .module))
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

    // MARK: - State

    private var hasPrompt: Bool {
        agentStore != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workspacePlaceholder: String {
        hasPrompt
            ? String(localized: "supermux.newWorktree.workspace.placeholder.derived", defaultValue: "Workspace name (from prompt)", bundle: .module)
            : String(localized: "supermux.newWorktree.workspace.placeholder", defaultValue: "Workspace name", bundle: .module)
    }

    private var branchPlaceholder: String {
        hasPrompt
            ? String(localized: "supermux.newWorktree.branch.placeholder.derived", defaultValue: "Branch (from prompt)", bundle: .module)
            : String(localized: "supermux.newWorktree.branch.placeholder", defaultValue: "Branch name (optional)", bundle: .module)
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
        baseBranch = Self.initialBaseBranch(configuredDefault: defaultBaseBranch, branches: branches)
    }

    // MARK: - Actions

    /// Fills the branch field from the Mac's suggestion. Never overwrites
    /// while a create is running.
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

    /// Creates the worktree on the Mac — plain, or with Claude when a prompt
    /// is present — then navigates to the opened workspace and dismisses.
    /// Errors show inline and the form stays editable for another attempt.
    private func create() {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                if hasPrompt, let agentStore {
                    let result = try await agentStore.start(
                        prompt: prompt,
                        baseBranch: baseBranchForCreate,
                        workspaceName: workspaceName,
                        branchName: branchName
                    )
                    // Claude only runs in an opened workspace: a reply without
                    // one is not a success to dismiss on. The worktree exists,
                    // so say so and stay put rather than create a second one.
                    guard let workspaceID = result.workspaceId else {
                        errorMessage = Self.workspaceNotOpenedMessage(branch: result.branchName)
                        isCreating = false
                        return
                    }
                    openWorkspace(workspaceID)
                } else {
                    let workspaceID = try await createWorktree(workspaceName, branchName, baseBranchForCreate, openAfterCreate)
                    if openAfterCreate, let workspaceID {
                        openWorkspace(workspaceID)
                    }
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

extension SupermuxNewWorktreeSheet {
    /// The inline error for an `agent.start` that created the worktree but
    /// opened no workspace (the Mac had no window to open it in).
    static func workspaceNotOpenedMessage(branch: String?) -> String {
        let format = String(
            localized: "supermux.newWorktree.error.workspaceNotOpened",
            defaultValue: "The Mac created the worktree “%@” but couldn’t open a workspace for it. Open it from the worktree list.",
            bundle: .module
        )
        return String(format: format, branch ?? "")
    }
}

/// The Claude section of the New Worktree sheet: command, model, and effort
/// pickers fed by the Mac's launch options, plus the resolved command line.
struct SupermuxNewWorktreeClaudeSection: View {
    let store: SupermuxMobileAgentLaunchStore
    let isBusy: Bool

    var body: some View {
        Section {
            if store.commands.count > 1 {
                Picker(
                    String(localized: "supermux.agent.command.label", defaultValue: "Command", bundle: .module),
                    selection: Binding(
                        get: { store.command },
                        set: { newValue in Task { await store.selectCommand(newValue) } }
                    )
                ) {
                    ForEach(store.commands, id: \.self) { command in
                        Text(command).monospaced().tag(command)
                    }
                }
                .disabled(isBusy || store.isLoadingOptions)
            }
            modelRow
            if !store.effortLevels.isEmpty {
                Picker(
                    String(localized: "supermux.agent.effort.label", defaultValue: "Effort", bundle: .module),
                    selection: Binding(
                        get: { store.selectedEffort ?? "" },
                        set: { store.selectedEffort = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text(defaultEffortTitle).tag("")
                    ForEach(store.effortLevels, id: \.self) { level in
                        Text(SupermuxAgentEffortLabel.title(for: level)).tag(level)
                    }
                }
                .disabled(isBusy)
            }
        } header: {
            Text(String(localized: "supermux.agent.section.claude", defaultValue: "Claude", bundle: .module))
        } footer: {
            if let modelsError = store.modelsError {
                Label(modelsError, systemImage: "exclamationmark.triangle")
            } else {
                Text(commandPreview)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if store.isLoadingOptions, store.models.isEmpty {
            HStack {
                Text(String(localized: "supermux.agent.model.label", defaultValue: "Model", bundle: .module))
                Spacer()
                ProgressView()
            }
        } else {
            Picker(
                String(localized: "supermux.agent.model.label", defaultValue: "Model", bundle: .module),
                selection: Binding(
                    get: { store.selectedModel ?? "" },
                    set: { store.selectedModel = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text(store.defaultModelEntry?.displayName
                    ?? String(localized: "supermux.agent.model.default", defaultValue: "Default", bundle: .module))
                    .tag("")
                ForEach(store.selectableModels) { model in
                    Text(model.displayName).tag(model.value)
                }
            }
            .disabled(isBusy)
        }
    }

    private var defaultEffortTitle: String {
        if let level = store.selectedModelDescriptor?.defaultEffortLevel {
            let format = String(localized: "supermux.agent.effort.defaultNamed", defaultValue: "Default (%@)", bundle: .module)
            return String(format: format, SupermuxAgentEffortLabel.title(for: level))
        }
        return String(localized: "supermux.agent.effort.default", defaultValue: "Default", bundle: .module)
    }

    /// `<command> [--model M] [--effort E] …`, so the pickers are never a guess.
    private var commandPreview: String {
        var parts = [store.command]
        if let model = store.selectedModel { parts += ["--model", model] }
        if let effort = store.selectedEffort { parts += ["--effort", effort] }
        parts.append("\"…\"")
        return parts.joined(separator: " ")
    }
}

/// Localized display names for Claude effort levels on the phone.
enum SupermuxAgentEffortLabel {
    static func title(for level: String) -> String {
        switch level.lowercased() {
        case "low": return String(localized: "supermux.agent.effort.low", defaultValue: "Low", bundle: .module)
        case "medium": return String(localized: "supermux.agent.effort.medium", defaultValue: "Medium", bundle: .module)
        case "high": return String(localized: "supermux.agent.effort.high", defaultValue: "High", bundle: .module)
        case "xhigh": return String(localized: "supermux.agent.effort.xhigh", defaultValue: "Extra High", bundle: .module)
        case "max": return String(localized: "supermux.agent.effort.max", defaultValue: "Max", bundle: .module)
        default: return level
        }
    }
}
