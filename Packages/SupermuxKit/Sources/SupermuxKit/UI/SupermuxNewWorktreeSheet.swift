public import SwiftUI
public import AppKit
import Foundation
import SupermuxMobileCore

/// Modal sheet for creating a git worktree in a project — optionally with
/// Claude already running in it.
///
/// One sheet, two outcomes, chosen by whether the prompt is filled in:
///
/// - **Prompt empty** — the classic flow: a workspace name, an optional
///   branch (AI-named from the workspace name when a gateway key is set,
///   friendly-random otherwise), a starting branch. "Create" opens a clean
///   terminal.
/// - **Prompt filled** — the prompt is the primary input: workspace name and
///   branch default to names derived from it (typed values still win), the
///   Claude chips (command / model / effort) appear, and "Start Claude" opens
///   the workspace with its terminal already running the command with the
///   prompt as the first message. That path goes through
///   ``SupermuxAgentWorktreeLauncher`` — the same path the phone uses.
///
/// Presented via `.sheet(item:)` from ``SupermuxProjectsSectionView``; the
/// host opens the resulting workspace through the callbacks.
public struct SupermuxNewWorktreeSheet: View {
    let model: SupermuxProjectsModel
    let project: SupermuxProject
    /// The project's resolved avatar image (custom icon or detected logo),
    /// shared with the sidebar row so the header shows the same icon.
    private let projectIcon: NSImage?
    /// Launcher / catalog / commands for the Claude path; `nil` hides it.
    let agentLaunch: SupermuxAgentLaunchEnvironment?
    private let onCreated: (SupermuxProjectWorktree, String?) -> Void
    private let onLaunched: (SupermuxAgentWorktreeLaunch) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State var prompt = ""
    @State private var workspaceName = ""
    @State private var branchInput = ""
    @State var baseBranch = ""
    @State var baseBranchWasEdited = false
    @State var localBranches: [String] = []
    @State var branchesLoaded = false
    @State private var isLoadingBranches = false
    @State private var branchLoadError: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var aiNamingConfigured = false
    @State private var createTask: Task<Void, Never>?

    // Claude chips state (only meaningful when `agentLaunch` is present).
    @State var command = ""
    @State var commands: [String] = []
    /// `nil` = no `--model` flag (Claude Code's own default).
    @State var selectedModel: String?
    /// `nil` = no `--effort` flag.
    @State var selectedEffort: String?
    @State var models: [SupermuxAgentModelDTO] = []
    @State var modelsLoading = false
    @State var modelsError: String?
    @State var showsCommandEditor = false

    enum Phase { case idle, naming, runningGit }
    @State var phase: Phase = .idle

    private enum Field { case prompt, workspace, branch }

    /// Creates the sheet.
    /// - Parameters:
    ///   - model: Shared projects model that performs the git work.
    ///   - project: Project the worktree is created in.
    ///   - projectIcon: The project's resolved avatar image, when the host has
    ///     one cached; `nil` falls back to the symbol or initial letter.
    ///   - agentLaunch: Claude launch collaborators; `nil` hides the prompt
    ///     path entirely (plain worktree sheet).
    ///   - onCreated: Called after a plain create with the new worktree and
    ///     the chosen workspace name (`nil` when left blank).
    ///   - onLaunched: Called after a Claude launch with the launch result;
    ///     the host opens `launch.openRequest`.
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        projectIcon: NSImage? = nil,
        agentLaunch: SupermuxAgentLaunchEnvironment? = nil,
        onCreated: @escaping (SupermuxProjectWorktree, String?) -> Void,
        onLaunched: @escaping (SupermuxAgentWorktreeLaunch) -> Void = { _ in }
    ) {
        self.model = model
        self.project = project
        self.projectIcon = projectIcon
        self.agentLaunch = agentLaunch
        self.onCreated = onCreated
        self.onLaunched = onLaunched
        _baseBranch = State(initialValue: Self.initialBaseBranch(
            configuredDefault: project.defaultBranch,
            branches: []
        ))
        if let settings = agentLaunch?.settings {
            _commands = State(initialValue: settings.commands)
            _command = State(initialValue: settings.selectedCommand)
        }
    }

    /// The sheet content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if agentLaunch != nil {
                promptEditor
            }
            nameFields
            if hasPrompt {
                commandPreview
            }
            chipRow
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let message = errorMessage ?? branchLoadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if branchLoadError != nil, errorMessage == nil {
                        Spacer(minLength: 0)
                        Button(String(localized: "common.retry", defaultValue: "Retry")) {
                            Task { await loadBranches() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            buttons
        }
        .padding(16)
        .frame(width: agentLaunch == nil ? 380 : 460)
        .animation(.snappy(duration: 0.18), value: hasPrompt)
        .onAppear {
            focusedField = agentLaunch == nil ? .workspace : .prompt
            Task { await load() }
        }
        .onChange(of: configuredDefaultBranch) { _, configuredDefault in
            guard branchesLoaded, !baseBranchWasEdited else { return }
            baseBranch = Self.initialBaseBranch(configuredDefault: configuredDefault, branches: localBranches)
        }
        .onChange(of: command) { _, newCommand in
            agentLaunch?.settings.setSelectedCommand(newCommand)
            Task { await loadModels(for: newCommand) }
        }
        .onChange(of: selectedModel) { _, _ in clampEffort() }
        // If the sheet goes away while the (possibly slow) AI-naming phase is
        // in flight, abort it so no worktree is created behind the user's
        // back. Cancel is disabled once git runs, so this only covers
        // programmatic dismissal.
        .onDisappear { createTask?.cancel() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            SupermuxProjectAvatarView(project: project, detectedIcon: projectIcon, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "supermux.newWorktree.title", defaultValue: "New Worktree"))
                    .font(.headline)
                Text(project.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            if prompt.isEmpty {
                Text(String(
                    localized: "supermux.newWorktree.prompt.placeholder",
                    defaultValue: "What should Claude work on? Leave empty for a plain worktree."
                ))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .focused($focusedField, equals: .prompt)
                .disabled(phase != .idle)
        }
        .frame(minHeight: 76, maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focusedField == .prompt ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    /// Workspace name and branch side by side. With a prompt, their
    /// placeholders show the names that will be derived, so leaving them
    /// blank is the normal case and typing overrides.
    private var nameFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(workspacePlaceholder, text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .workspace)
                    .onSubmit(create)
                    .disabled(phase != .idle)
                TextField(branchPlaceholder, text: $branchInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focusedField, equals: .branch)
                    .onSubmit(create)
                    .disabled(phase != .idle)
                    .frame(width: hasPrompt ? 170 : 150)
            }
            Text(nameHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The exact shell line the new terminal will run, so what the chips
    /// mean is never a guess.
    private var commandPreview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(previewLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
            // Cancelling can abort the AI-naming phase, but not a git process
            // already creating the worktree — so it is disabled then.
            .disabled(phase == .runningGit)
            Button(action: create) {
                HStack(spacing: 5) {
                    if phase != .idle {
                        ProgressView().controlSize(.small)
                    } else if hasPrompt {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(hasPrompt
                        ? String(localized: "supermux.newWorktree.startClaude", defaultValue: "Start Claude")
                        : String(localized: "supermux.newWorktree.create", defaultValue: "Create"))
                    if hasPrompt {
                        Text("⌘↩").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .keyboardShortcut(hasPrompt ? .init(.return, modifiers: .command) : .defaultAction)
            .disabled(!canCreate)
        }
    }

    // MARK: - State

    var hasPrompt: Bool {
        agentLaunch != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the primary button is enabled: not mid-create, branches known.
    private var canCreate: Bool { phase == .idle && branchesLoaded }

    /// Offline preview of the names the prompt would produce (AI refines at
    /// submit when configured).
    private var derivedNames: SupermuxPromptNames? {
        hasPrompt ? SupermuxPromptNaming.names(from: prompt) : nil
    }

    private var workspacePlaceholder: String {
        derivedNames?.workspaceName
            ?? String(localized: "supermux.newWorktree.workspace.placeholder", defaultValue: "Workspace name")
    }

    private var branchPlaceholder: String {
        derivedNames?.branchName
            ?? String(localized: "supermux.newWorktree.branch.placeholder.optional", defaultValue: "Branch name (optional)")
    }

    var previewLine: String {
        SupermuxAgentLaunchCommand.shellLine(
            command: command,
            model: selectedModel,
            effort: selectedEffort,
            prompt: prompt
        )
    }

    /// Subtitle under the fields: what the names will be, or a sanitized
    /// preview when the typed branch differs from what git will use.
    private var nameHint: String {
        let typedBranch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sanitized = SupermuxBranchName().sanitize(branchInput), sanitized != typedBranch {
            return String(
                localized: "supermux.newWorktree.branch.preview",
                defaultValue: "Will be created as “\(sanitized)”"
            )
        }
        if hasPrompt {
            return aiNamingConfigured
                ? String(
                    localized: "supermux.newWorktree.prompt.aiHint",
                    defaultValue: "Blank fields are named from the prompt by AI; typed values are kept."
                )
                : String(
                    localized: "supermux.newWorktree.prompt.hint",
                    defaultValue: "Blank fields are named from the prompt; typed values are kept."
                )
        }
        if !typedBranch.isEmpty { return "" }
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

    /// The model's current configured default, falling back to the
    /// presentation snapshot only if the project is no longer in the model.
    private var configuredDefaultBranch: String? {
        model.projects.first(where: { $0.id == project.id })?.defaultBranch ?? project.defaultBranch
    }

    /// Configured project default first, then every local branch, deduped.
    var baseBranchOptions: [String] {
        var seen: Set<String> = []
        return ([configuredDefaultBranch].compactMap { $0 } + localBranches).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func initialBaseBranch(configuredDefault: String?, branches: [String]) -> String {
        if let configuredDefault, !configuredDefault.isEmpty {
            return configuredDefault
        }
        return branches.contains("main") ? "main" : ""
    }

    /// An untouched picker defers to the service's fresh default resolution;
    /// only an explicit user choice becomes an override (`HEAD` for the
    /// repository-head option).
    static func requestedBaseBranch(selection: String, wasEdited: Bool) -> String? {
        guard wasEdited else { return nil }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HEAD" : trimmed
    }

    /// The effort levels the current model selection accepts.
    var effortLevels: [String] { models.effortLevels(forSelection: selectedModel) }

    var selectedModelDescriptor: SupermuxAgentModelDTO? {
        guard let selectedModel else { return nil }
        return models.first { $0.value == selectedModel }
    }

    /// Drops an effort the newly chosen model does not accept.
    func clampEffort() {
        guard let effort = selectedEffort, !effortLevels.contains(effort) else { return }
        selectedEffort = nil
    }

    // MARK: - Actions

    private func load() async {
        async let configured: Bool = {
            if let agentLaunch { return await agentLaunch.launcher.isAINamingConfigured() }
            return await model.isAIBranchNamingConfigured()
        }()
        async let branches: Void = loadBranches()
        async let catalog: Void = loadModels(for: command)
        aiNamingConfigured = await configured
        _ = await (branches, catalog)
    }

    private func loadBranches() async {
        guard !isLoadingBranches else { return }
        isLoadingBranches = true
        branchLoadError = nil
        defer { isLoadingBranches = false }
        do {
            let branches = try await model.localBranches(projectId: project.id)
            localBranches = branches
            branchesLoaded = true
            if !baseBranchWasEdited {
                baseBranch = Self.initialBaseBranch(configuredDefault: configuredDefaultBranch, branches: branches)
            }
        } catch {
            branchesLoaded = false
            branchLoadError = error.localizedDescription
        }
    }

    func loadModels(for command: String, forceRefresh: Bool = false) async {
        guard let agentLaunch, !command.isEmpty else { return }
        modelsLoading = true
        modelsError = nil
        defer { modelsLoading = false }
        let result = await agentLaunch.catalog.models(
            for: command,
            workingDirectoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true),
            forceRefresh: forceRefresh
        )
        // The user may have switched commands while this probe ran.
        guard command == self.command else { return }
        models = result.models
        modelsError = result.source == .unavailable ? result.errorDescription : nil
        let last = agentLaunch.settings.lastChoice(for: command)
        if let lastModel = last.model, models.selectableModels.contains(where: { $0.value == lastModel }) {
            selectedModel = lastModel
        } else {
            selectedModel = nil
        }
        selectedEffort = last.effort
        clampEffort()
    }

    /// Replaces the command list from the editor popover.
    func saveCommands(_ edited: [String]) {
        guard let settings = agentLaunch?.settings else { return }
        settings.setCommands(edited)
        commands = settings.commands
        if !commands.contains(command) {
            command = settings.selectedCommand
        }
    }

    private func create() {
        guard canCreate else { return }
        if hasPrompt {
            startClaude()
        } else {
            createPlain()
        }
    }

    /// The Claude path: names from the prompt (typed fields win), worktree,
    /// and an open request whose terminal runs the command — all inside the
    /// shared launcher.
    private func startClaude() {
        guard let agentLaunch else { return }
        phase = .naming
        errorMessage = nil
        statusMessage = aiNamingConfigured
            ? String(localized: "supermux.agent.status.naming", defaultValue: "Naming the workspace with AI…")
            : String(localized: "supermux.agent.status.creating", defaultValue: "Creating worktree…")
        let request = SupermuxAgentLaunchRequest(
            projectId: project.id,
            prompt: prompt,
            command: command,
            model: selectedModel,
            effort: selectedEffort,
            baseBranch: Self.requestedBaseBranch(selection: baseBranch, wasEdited: baseBranchWasEdited),
            workspaceName: workspaceName,
            branchName: branchInput
        )
        createTask = Task {
            do {
                let launch = try await agentLaunch.launcher.start(request) {
                    phase = .runningGit
                    statusMessage = String(localized: "supermux.agent.status.creating", defaultValue: "Creating worktree…")
                }
                guard !Task.isCancelled else { return }
                onLaunched(launch)
                dismiss()
            } catch is CancellationError {
                phase = .idle
                statusMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
                phase = .idle
            }
        }
    }

    /// The classic path, unchanged: AI names the branch from the workspace
    /// name only when the branch was left blank; a typed branch is respected.
    private func createPlain() {
        phase = .naming
        errorMessage = nil
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedBase = Self.requestedBaseBranch(selection: baseBranch, wasEdited: baseBranchWasEdited)
        createTask = Task {
            var branchToUse = branchInput
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
            if Task.isCancelled {
                phase = .idle
                return
            }
            // Point of no return: Cancel is disabled from here and the created
            // worktree is always delivered via onCreated.
            phase = .runningGit
            do {
                let worktree = try await model.createWorktree(
                    projectId: project.id,
                    branchName: branchToUse,
                    baseBranch: selectedBase
                )
                guard !Task.isCancelled else { return }
                onCreated(worktree, trimmedName.isEmpty ? nil : trimmedName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }
}
