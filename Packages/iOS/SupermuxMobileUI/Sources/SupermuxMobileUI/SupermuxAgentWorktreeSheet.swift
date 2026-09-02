public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// "Start Claude in a New Worktree" from the phone: type the task, pick the
/// Claude command / model / effort the Mac offers, and the Mac creates a
/// worktree named from the prompt and opens a workspace already running
/// Claude with it. The mobile counterpart of the desktop sheet; every
/// decision (naming, catalogs, git, the terminal) stays on the Mac.
///
/// Holds only a store and closures, so state crosses the snapshot boundary
/// cleanly; the presenting wrapper owns the store's lifetime.
public struct SupermuxAgentWorktreeSheet: View {
    private let projectName: String
    private let store: SupermuxMobileAgentLaunchStore
    private let branches: [String]
    private let defaultBaseBranch: String?
    private let showsBaseBranchPicker: Bool
    private let openWorkspace: @MainActor (_ workspaceID: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool
    @State private var prompt = ""
    @State private var baseBranch = ""
    @State private var baseBranchWasEdited = false
    @State private var errorMessage: String?

    /// Creates the sheet.
    /// - Parameters:
    ///   - projectName: The project's display name (subtitle).
    ///   - store: The agent-launch store (options already loaded by the host).
    ///   - branches: Local branches available as starting points.
    ///   - defaultBaseBranch: The project's configured starting branch.
    ///   - showsBaseBranchPicker: Whether the host supports explicit
    ///     starting-branch selection.
    ///   - openWorkspace: Navigates to a workspace by id after the launch.
    public init(
        projectName: String,
        store: SupermuxMobileAgentLaunchStore,
        branches: [String],
        defaultBaseBranch: String?,
        showsBaseBranchPicker: Bool = true,
        openWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in }
    ) {
        self.projectName = projectName
        self.store = store
        self.branches = branches
        self.defaultBaseBranch = defaultBaseBranch
        self.showsBaseBranchPicker = showsBaseBranchPicker
        self.openWorkspace = openWorkspace
        _baseBranch = State(initialValue: SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: defaultBaseBranch,
            branches: branches
        ))
    }

    public var body: some View {
        NavigationStack {
            Form {
                promptSection
                claudeSection
                if showsBaseBranchPicker {
                    baseBranchSection
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
                localized: "supermux.agent.sheet.title",
                defaultValue: "Start Claude",
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
                    .disabled(store.isStarting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: start) {
                        if store.isStarting {
                            ProgressView()
                        } else {
                            Text(String(localized: "supermux.agent.start", defaultValue: "Start", bundle: .module))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canStart)
                    .accessibilityIdentifier("SupermuxAgentStartButton")
                }
            }
        }
        .interactiveDismissDisabled(store.isStarting)
        .accessibilityIdentifier("SupermuxAgentWorktreeSheet")
        .onAppear { promptFocused = true }
        .onChange(of: branches, initial: true) { _, _ in updateUntouchedBaseBranch() }
        .onChange(of: defaultBaseBranch) { _, _ in updateUntouchedBaseBranch() }
    }

    // MARK: - Sections

    private var promptSection: some View {
        Section {
            TextField(
                String(
                    localized: "supermux.agent.prompt.placeholder",
                    defaultValue: "What should Claude work on?",
                    bundle: .module
                ),
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(3...8)
            .focused($promptFocused)
            .disabled(store.isStarting)
            .accessibilityIdentifier("SupermuxAgentPromptField")
        } header: {
            Text(projectName)
        } footer: {
            Text(String(
                localized: "supermux.agent.prompt.footer",
                defaultValue: "The Mac names the workspace and branch from this prompt, creates the worktree, and opens Claude in it.",
                bundle: .module
            ))
        }
    }

    private var claudeSection: some View {
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
                .disabled(store.isStarting || store.isLoadingOptions)
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
                .disabled(store.isStarting)
            }
        } header: {
            Text(String(localized: "supermux.agent.section.claude", defaultValue: "Claude", bundle: .module))
        } footer: {
            if let modelsError = store.modelsError {
                Label(modelsError, systemImage: "exclamationmark.triangle")
            } else if store.commands.count > 1 {
                Text(String(
                    localized: "supermux.agent.command.footer",
                    defaultValue: "Commands and models come from the Mac. Edit the command list in the Mac sheet.",
                    bundle: .module
                ))
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
                Text(String(localized: "supermux.agent.model.default", defaultValue: "Default", bundle: .module)).tag("")
                ForEach(store.models) { model in
                    Text(model.displayName).tag(model.value)
                }
            }
            .disabled(store.isStarting)
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
            .disabled(store.isStarting)
        }
    }

    // MARK: - State

    private var canStart: Bool {
        !store.isStarting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var defaultEffortTitle: String {
        if let level = store.selectedModelDescriptor?.defaultEffortLevel {
            let format = String(
                localized: "supermux.agent.effort.defaultNamed",
                defaultValue: "Default (%@)",
                bundle: .module
            )
            return String(format: format, SupermuxAgentEffortLabel.title(for: level))
        }
        return String(localized: "supermux.agent.effort.default", defaultValue: "Default", bundle: .module)
    }

    private var baseBranchOptions: [String] {
        var seen: Set<String> = []
        return ([defaultBaseBranch].compactMap { $0 } + branches).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    private func updateUntouchedBaseBranch() {
        guard !baseBranchWasEdited else { return }
        baseBranch = SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: defaultBaseBranch,
            branches: branches
        )
    }

    // MARK: - Actions

    private func start() {
        guard canStart else { return }
        errorMessage = nil
        Task {
            do {
                let result = try await store.start(
                    prompt: prompt,
                    baseBranch: SupermuxNewWorktreeSheet.requestedBaseBranch(
                        selection: baseBranch,
                        wasEdited: baseBranchWasEdited
                    )
                )
                if let workspaceID = result.workspaceId {
                    openWorkspace(workspaceID)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
