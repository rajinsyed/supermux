public import SwiftUI
import Foundation
import SupermuxMobileCore

/// "Start Claude in a new worktree": type the task, pick the Claude command,
/// model, and effort, and one click creates a worktree named from the prompt
/// and opens a workspace whose terminal is already running Claude with it.
///
/// Prompt-first on purpose — the plain New Worktree sheet asks for names the
/// user then has to reuse when they finally type the prompt into Claude. Here
/// the prompt is the only required input; the workspace title and branch are
/// derived (AI when a gateway key is configured, an offline heuristic
/// otherwise, previewed live under the editor). Creation and launch route
/// through ``SupermuxAgentWorktreeLauncher``, the same path the phone's
/// `agent.start` RPC uses.
public struct SupermuxAgentWorktreeSheet: View {
    let model: SupermuxProjectsModel
    let project: SupermuxProject
    let environment: SupermuxAgentLaunchEnvironment
    private let opener: any SupermuxWorkspaceOpening

    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    @State var prompt = ""
    @State var command: String
    @State var commands: [String]
    /// `nil` means "let the CLI pick" (its settings-file default).
    @State var selectedModel: String?
    /// `nil` means the CLI default for the chosen model.
    @State var selectedEffort: String?
    @State var models: [SupermuxAgentModelDTO] = []
    @State var modelsLoading = false
    @State var modelsError: String?
    @State var baseBranch: String
    @State var baseBranchWasEdited = false
    @State var localBranches: [String] = []
    @State var branchesLoaded = false
    @State var aiNamingConfigured = false
    @State var errorMessage: String?
    @State var statusMessage: String?
    @State var showsCommandEditor = false
    @State private var startTask: Task<Void, Never>?

    enum Phase { case idle, naming, runningGit }
    @State var phase: Phase = .idle

    /// Creates the sheet.
    /// - Parameters:
    ///   - model: The shared projects model (branch list, current project).
    ///   - project: The project the worktree is created in.
    ///   - environment: Launcher, model catalog, and command settings.
    ///   - opener: Opens the resulting workspace in the host window.
    public init(
        model: SupermuxProjectsModel,
        project: SupermuxProject,
        environment: SupermuxAgentLaunchEnvironment,
        opener: any SupermuxWorkspaceOpening
    ) {
        self.model = model
        self.project = project
        self.environment = environment
        self.opener = opener
        let settings = environment.settings
        _commands = State(initialValue: settings.commands)
        _command = State(initialValue: settings.selectedCommand)
        _baseBranch = State(initialValue: SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: project.defaultBranch,
            branches: []
        ))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            promptEditor
            namingPreview
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            promptFocused = true
            Task { await load() }
        }
        .onChange(of: command) { _, newCommand in
            environment.settings.setSelectedCommand(newCommand)
            Task { await loadModels(for: newCommand) }
        }
        .onChange(of: selectedModel) { _, _ in
            clampEffort()
        }
        .onDisappear { startTask?.cancel() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            SupermuxProjectAvatarView(project: project, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "supermux.agent.sheet.title", defaultValue: "Start Claude in a New Worktree"))
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
                Text(String(localized: "supermux.agent.prompt.placeholder", defaultValue: "What should Claude work on?"))
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
                .focused($promptFocused)
                .disabled(phase != .idle)
        }
        .frame(minHeight: 92, maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    promptFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    /// Live, offline preview of the names the launch will use. AI (when
    /// configured) refines these at submit time; the hint says so.
    @ViewBuilder
    private var namingPreview: some View {
        let names = SupermuxPromptNaming.names(from: prompt)
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(names == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            if let names {
                Text(names.workspaceName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(names.branchName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if aiNamingConfigured {
                    Text(String(localized: "supermux.agent.preview.aiRefines", defaultValue: "AI will refine"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(String(
                    localized: "supermux.agent.preview.hint",
                    defaultValue: "Workspace and branch names are generated from the prompt."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipRow
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "supermux.common.cancel", defaultValue: "Cancel")) {
                    startTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .runningGit)
                Button(action: start) {
                    HStack(spacing: 5) {
                        if phase != .idle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        }
                        Text(String(localized: "supermux.agent.start", defaultValue: "Start"))
                        Text("⌘↩")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canStart)
            }
        }
    }

    // MARK: - State

    var canStart: Bool {
        phase == .idle && branchesLoaded
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedModelDescriptor: SupermuxAgentModelDTO? {
        guard let selectedModel else { return nil }
        return models.first { $0.value == selectedModel }
    }

    /// Drops an effort the newly chosen model does not support.
    private func clampEffort() {
        guard let effort = selectedEffort else { return }
        guard let descriptor = selectedModelDescriptor, descriptor.supportsEffort else {
            selectedEffort = nil
            return
        }
        if !descriptor.supportedEffortLevels.contains(effort) {
            selectedEffort = nil
        }
    }

    private var configuredDefaultBranch: String? {
        model.projects.first(where: { $0.id == project.id })?.defaultBranch ?? project.defaultBranch
    }

    var baseBranchOptions: [String] {
        var seen: Set<String> = []
        return ([configuredDefaultBranch].compactMap { $0 } + localBranches).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    // MARK: - Actions

    private func load() async {
        async let configured = environment.launcher.isAINamingConfigured()
        async let branches: Void = loadBranches()
        async let catalog: Void = loadModels(for: command)
        aiNamingConfigured = await configured
        _ = await (branches, catalog)
    }

    private func loadBranches() async {
        do {
            let branches = try await model.localBranches(projectId: project.id)
            localBranches = branches
            branchesLoaded = true
            if !baseBranchWasEdited {
                baseBranch = SupermuxNewWorktreeSheet.initialBaseBranch(
                    configuredDefault: configuredDefaultBranch,
                    branches: branches
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadModels(for command: String, forceRefresh: Bool = false) async {
        modelsLoading = true
        modelsError = nil
        defer { modelsLoading = false }
        let result = await environment.catalog.models(
            for: command,
            workingDirectoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true),
            forceRefresh: forceRefresh
        )
        // The user may have switched commands while this probe ran.
        guard command == self.command else { return }
        models = result.models
        modelsError = result.source == .unavailable ? result.errorDescription : nil
        let last = environment.settings.lastChoice(for: command)
        if let lastModel = last.model, models.contains(where: { $0.value == lastModel }) {
            selectedModel = lastModel
            selectedEffort = last.effort
        } else {
            selectedModel = nil
            selectedEffort = nil
        }
        clampEffort()
    }

    /// Replaces the command list from the editor popover.
    func saveCommands(_ edited: [String]) {
        environment.settings.setCommands(edited)
        commands = environment.settings.commands
        if !commands.contains(command) {
            command = environment.settings.selectedCommand
        }
    }

    private func start() {
        guard canStart else { return }
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
            baseBranch: SupermuxNewWorktreeSheet.requestedBaseBranch(
                selection: baseBranch,
                wasEdited: baseBranchWasEdited
            )
        )
        startTask = Task {
            do {
                let launch = try await environment.launcher.start(request) {
                    phase = .runningGit
                    statusMessage = String(localized: "supermux.agent.status.creating", defaultValue: "Creating worktree…")
                }
                guard !Task.isCancelled else { return }
                opener.openWorkspace(launch.openRequest)
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
}
