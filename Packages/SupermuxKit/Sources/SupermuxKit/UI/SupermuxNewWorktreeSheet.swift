public import SwiftUI
import Foundation

/// Modal sheet for creating a git worktree (with a fresh branch) in a project.
///
/// Kept deliberately minimal — a workspace name, an optional branch name, and
/// a starting-branch picker — to mirror piggycode's frictionless flow. Leaving
/// the branch blank generates a friendly random name; the starting branch
/// defaults to the project's configured branch, otherwise `main` when available
/// or the repository `HEAD`. The sheet is presented via `.sheet(item:)` from
/// ``SupermuxProjectsSectionView``, so it owns no
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
    @State private var baseBranch = ""
    @State private var localBranches: [String] = []
    /// Distinguishes the untouched default from the user deliberately choosing
    /// the repository `HEAD` option after branches load.
    @State private var baseBranchWasEdited = false
    @State private var branchesLoaded = false
    @State private var isLoadingBranches = false
    @State private var branchLoadError: String?
    @State private var errorMessage: String?
    /// Transient progress text shown while AI names the branch / git creates it.
    @State private var statusMessage: String?
    /// Whether AI branch naming is wired and a key is configured (probed on
    /// appear for the hint; re-checked freshly at submit time).
    @State private var aiNamingConfigured = false
    /// The in-flight create work, retained so Cancel / dismiss can abort it
    /// while it is still (slowly) naming a branch — before git runs.
    @State private var createTask: Task<Void, Never>?
    /// Where the create flow currently is; drives which controls are enabled.
    private enum CreatePhase {
        /// No create in flight.
        case idle
        /// The (still cancellable) AI branch-naming step is running.
        case naming
        /// `git worktree add` has started. Cancelling a task cannot stop a
        /// running git process, so in this phase the Cancel button is disabled:
        /// creation completes (it takes seconds) and is delivered via `onCreated`
        /// rather than silently leaving an orphaned worktree behind.
        case runningGit
    }
    @State private var phase: CreatePhase = .idle

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
        _baseBranch = State(initialValue: Self.initialBaseBranch(
            configuredDefault: project.defaultBranch,
            branches: []
        ))
    }

    /// The sheet content.
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            workspaceField
            branchField
            basePicker
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
            Task { await load() }
        }
        .onChange(of: configuredDefaultBranch) { _, configuredDefault in
            guard branchesLoaded, !baseBranchWasEdited else { return }
            baseBranch = Self.initialBaseBranch(
                configuredDefault: configuredDefault,
                branches: localBranches
            )
        }
        // If the sheet goes away while the (possibly slow) AI-naming phase is in
        // flight, abort it so no worktree is created behind the user's back.
        // Once git itself is running, cancellation can't stop it — the Cancel
        // button is disabled for that window, so this only covers programmatic
        // dismissal.
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
            .disabled(phase != .idle)
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
            .disabled(phase != .idle)
            Text(branchHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var basePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(
                String(localized: "supermux.newWorktree.base.label", defaultValue: "Start from"),
                selection: Binding(
                    get: { baseBranch },
                    set: {
                        baseBranch = $0
                        baseBranchWasEdited = true
                    }
                )
            ) {
                Text(String(localized: "supermux.newWorktree.base.default", defaultValue: "Repository HEAD"))
                    .tag("")
                ForEach(baseBranchOptions, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .disabled(phase != .idle || !branchesLoaded)
            Text(String(
                localized: "supermux.newWorktree.base.hint",
                defaultValue: "Includes committed changes from the selected branch. Uncommitted changes aren’t copied."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if isLoadingBranches {
                ProgressView()
                    .controlSize(.small)
            } else if let branchLoadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(branchLoadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(String(localized: "common.retry", defaultValue: "Retry")) {
                        Task { await loadBranches() }
                    }
                    .controlSize(.small)
                }
            }
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
            // Cancelling can genuinely abort the AI-naming phase, but not a git
            // process already creating the worktree — so it is disabled (rather
            // than pretending, then discarding a worktree that was created).
            .disabled(phase == .runningGit)
            Button(action: create) {
                HStack(spacing: 5) {
                    if phase != .idle {
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

    /// The model's current configured default, falling back to the presentation
    /// snapshot only if the project is no longer in the model.
    private var configuredDefaultBranch: String? {
        if let current = model.projects.first(where: { $0.id == project.id }) {
            return current.defaultBranch
        }
        return project.defaultBranch
    }

    /// Configured project default first, followed by every local branch, with
    /// duplicates removed while preserving order.
    private var baseBranchOptions: [String] {
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
    /// only an explicit user choice becomes an override.
    static func requestedBaseBranch(selection: String, wasEdited: Bool) -> String? {
        guard wasEdited else { return nil }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HEAD" : trimmed
    }

    /// The branch field is optional, but the starting-branch snapshot must be
    /// authoritative before creation can begin.
    private var canCreate: Bool { phase == .idle && branchesLoaded }

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

    private func load() async {
        async let configured = model.isAIBranchNamingConfigured()
        await loadBranches()
        aiNamingConfigured = await configured
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
                baseBranch = Self.initialBaseBranch(
                    configuredDefault: configuredDefaultBranch,
                    branches: branches
                )
            }
        } catch {
            branchesLoaded = false
            branchLoadError = error.localizedDescription
        }
    }

    private func create() {
        guard canCreate else { return }
        phase = .naming
        errorMessage = nil
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedBase = Self.requestedBaseBranch(
            selection: baseBranch,
            wasEdited: baseBranchWasEdited
        )
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
                phase = .idle
                return
            }
            // Point of no return: Cancel is disabled from here (no await sits
            // between the check above and this write, so a cancel can't slip
            // in), and the created worktree is always delivered via onCreated.
            phase = .runningGit
            do {
                let worktree = try await model.createWorktree(
                    projectId: project.id,
                    branchName: branchToUse,
                    baseBranch: selectedBase
                )
                // Cancellation here can only come from programmatic sheet
                // teardown (Cancel is disabled). The worktree exists either
                // way; it stays on disk and is listed under the project's
                // disclosure, just not opened as a workspace.
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
