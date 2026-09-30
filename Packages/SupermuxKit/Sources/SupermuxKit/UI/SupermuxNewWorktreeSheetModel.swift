public import Foundation
import Observation
public import SupermuxMobileCore

/// The New Worktree sheet's state and flow, independent of SwiftUI: which Mac
/// it creates on (the device picker), that Mac's branches and Claude options,
/// the typed prompt and names, and the create / Start Claude flows.
///
/// Every Mac goes through one ``SupermuxWorktreeCreationTarget``, so This Mac
/// and another Mac run the same code; the sheet view only renders this model,
/// and the app's E2E socket drivers run it exactly as a click does.
///
/// Switching Mac keeps the prompt, workspace name and branch the user typed,
/// and reloads that Mac's starting branches and Claude options. A load that
/// was still running for the previous Mac is dropped.
@MainActor
@Observable
public final class SupermuxNewWorktreeSheetModel {
    /// Where the create flow is.
    public enum Phase: Equatable, Sendable {
        /// Editable.
        case idle
        /// Asking AI for names (Cancel still aborts).
        case naming
        /// Git runs (or the other Mac was asked): the point of no return.
        case runningGit
    }

    /// The unified project id (the last-device memory key).
    public let projectID: UUID
    /// The device picker's rows.
    public let entries: [SupermuxWorktreeDeviceEntry]
    /// The selected picker row.
    public private(set) var selectedEntryID: String?
    /// Where Create / Start Claude goes; `nil` when the selected Mac has no target.
    public private(set) var target: (any SupermuxWorktreeCreationTarget)?

    // Typed input: kept when the Mac changes.
    public var prompt = ""
    public var workspaceName = ""
    public var branchInput = ""

    // The selected Mac's state: reset when the Mac changes.
    public var baseBranch = ""
    public var baseBranchWasEdited = false
    public private(set) var localBranches: [String] = []
    public private(set) var branchesLoaded = false
    public private(set) var isLoadingBranches = false
    public private(set) var branchLoadError: String?
    public var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var aiNamingConfigured = false
    public private(set) var phase: Phase = .idle

    // Claude chips (only meaningful when the target supports the prompt path).
    public internal(set) var command = ""
    public internal(set) var commands: [String] = []
    /// `nil` = no `--model` flag (Claude Code's own default).
    public var selectedModel: String?
    /// `nil` = no `--effort` flag.
    public var selectedEffort: String?
    public internal(set) var models: [SupermuxAgentModelDTO] = []
    public internal(set) var modelsLoading = false
    public internal(set) var modelsError: String?

    /// Bumped on every Mac switch; async results for an older value are dropped.
    @ObservationIgnored var targetGeneration = 0
    @ObservationIgnored private var targets: [String: any SupermuxWorktreeCreationTarget] = [:]
    @ObservationIgnored private let makeTarget: @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?
    @ObservationIgnored private let lastDevices: SupermuxWorktreeLastDeviceStore?
    @ObservationIgnored private let onSetUp: @MainActor (SupermuxProjectSetupDestination) -> Void
    @ObservationIgnored private var createTask: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - projectID: The unified project id.
    ///   - entries: The picker rows (``SupermuxWorktreeDevicePlanner/entries(for:availability:setUpTargets:)``).
    ///   - initialEntryID: The preselected row
    ///     (``SupermuxWorktreeDevicePlanner/defaultEntryID(in:preferredDeviceKey:lastUsedDeviceKey:)``).
    ///   - makeTarget: Builds the target for a project copy (called once per
    ///     copy, the first time it is selected).
    ///   - lastDevices: Where a successful create records its Mac.
    ///   - onSetUp: Hands a "Set Up on <Mac>…" row to the setup sheet.
    public init(
        projectID: UUID,
        entries: [SupermuxWorktreeDeviceEntry],
        initialEntryID: String?,
        makeTarget: @escaping @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?,
        lastDevices: SupermuxWorktreeLastDeviceStore? = nil,
        onSetUp: @escaping @MainActor (SupermuxProjectSetupDestination) -> Void = { _ in }
    ) {
        self.projectID = projectID
        self.entries = entries
        self.makeTarget = makeTarget
        self.lastDevices = lastDevices
        self.onSetUp = onSetUp
        if let entry = entries.first(where: { $0.id == initialEntryID }), entry.location != nil {
            activate(entry)
        }
    }

    // MARK: - Device picker

    /// The selected picker row.
    public var selectedEntry: SupermuxWorktreeDeviceEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    /// Whether the picker shows (more than one row).
    public var showsDevicePicker: Bool { SupermuxWorktreeDevicePlanner.showsPicker(entries) }

    /// The other Mac's name when creating there; `nil` for this Mac.
    public var remoteDeviceName: String? { target?.remoteDeviceName }

    /// Chooses a picker row. A "Set Up on <Mac>…" row hands off to the setup
    /// sheet; an unreachable Mac, or any change while a create runs, is ignored.
    public func selectEntry(id: String) {
        guard phase == .idle, id != selectedEntryID,
              let entry = entries.first(where: { $0.id == id }) else { return }
        if let destination = entry.setUpDestination {
            onSetUp(destination)
            return
        }
        guard entry.canCreate else { return }
        activate(entry)
    }

    private func activate(_ entry: SupermuxWorktreeDeviceEntry) {
        guard let location = entry.location else { return }
        let target = targets[entry.id] ?? makeTarget(location)
        targets[entry.id] = target
        selectedEntryID = entry.id
        self.target = target
        targetGeneration += 1
        localBranches = []
        branchesLoaded = false
        isLoadingBranches = false
        branchLoadError = nil
        baseBranchWasEdited = false
        baseBranch = Self.initialBaseBranch(configuredDefault: target?.configuredDefaultBranch, branches: [])
        errorMessage = nil
        statusMessage = nil
        aiNamingConfigured = false
        let list = target?.initialAgentCommands ?? SupermuxAgentCommandList(commands: [], selected: "")
        commands = list.commands
        command = list.selected
        models = []
        modelsLoading = false
        modelsError = nil
        selectedModel = nil
        selectedEffort = nil
    }

    // MARK: - Derived state

    /// Whether the prompt editor shows (the target offers "Start Claude").
    public var showsPromptEditor: Bool { target?.supportsAgentLaunch == true }

    /// Whether a prompt was typed (and the target can start Claude with it).
    public var hasPrompt: Bool {
        showsPromptEditor && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the primary button is enabled: a reachable target, not mid-create.
    /// The branch list is optional (an untouched picker defers to the service
    /// default), so a failed or slow branch read never blocks creating.
    public var canCreate: Bool {
        phase == .idle && target != nil && selectedEntry?.canCreate == true
    }

    /// The target's configured default starting branch.
    public var configuredDefaultBranch: String? { target?.configuredDefaultBranch }

    /// Configured project default first, then every local branch, deduped.
    public var baseBranchOptions: [String] {
        var seen: Set<String> = []
        return ([configuredDefaultBranch].compactMap { $0 } + localBranches).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    /// Re-applies a changed configured default, unless the user picked one.
    public func configuredDefaultBranchChanged() {
        guard branchesLoaded, !baseBranchWasEdited else { return }
        baseBranch = Self.initialBaseBranch(configuredDefault: configuredDefaultBranch, branches: localBranches)
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

    // MARK: - Loading

    /// Loads the selected Mac's AI availability, branches and Claude options.
    public func load() async {
        guard let target else { return }
        let generation = targetGeneration
        async let configured: Bool = target.isAINamingConfigured()
        async let branches: Void = loadBranches()
        async let catalog: Void = loadModels(for: command)
        let isConfigured = await configured
        if generation == targetGeneration { aiNamingConfigured = isConfigured }
        _ = await (branches, catalog)
    }

    /// Loads the selected Mac's local branches for the starting-branch menu.
    public func loadBranches() async {
        guard let target, !isLoadingBranches else { return }
        let generation = targetGeneration
        isLoadingBranches = true
        branchLoadError = nil
        defer { if generation == targetGeneration { isLoadingBranches = false } }
        do {
            let branches = try await target.loadBranches()
            guard generation == targetGeneration else { return }
            localBranches = branches
            branchesLoaded = true
            if !baseBranchWasEdited {
                baseBranch = Self.initialBaseBranch(configuredDefault: target.configuredDefaultBranch, branches: branches)
            }
        } catch {
            guard generation == targetGeneration else { return }
            branchesLoaded = false
            branchLoadError = error.localizedDescription
        }
    }

    // MARK: - Create

    /// Runs Create (prompt empty) or Start Claude (prompt typed) on the
    /// selected Mac. `onFinished` runs after the worktree was delivered (the
    /// sheet dismisses there). Returns the running flow, `nil` when disabled.
    @discardableResult
    public func submit(onFinished: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard canCreate, let target, let entry = selectedEntry else { return nil }
        let task = hasPrompt
            ? startAgent(on: target, entry: entry, onFinished: onFinished)
            : createPlain(on: target, entry: entry, onFinished: onFinished)
        createTask = task
        return task
    }

    /// Aborts the naming phase (git, once started, still delivers).
    public func cancel() {
        createTask?.cancel()
    }

    /// The Claude path: names from the prompt (typed fields win), worktree,
    /// and a workspace whose terminal runs the command — all on the target.
    private func startAgent(
        on target: any SupermuxWorktreeCreationTarget,
        entry: SupermuxWorktreeDeviceEntry,
        onFinished: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        phase = .naming
        errorMessage = nil
        statusMessage = aiNamingConfigured
            ? String(localized: "supermux.agent.status.naming", defaultValue: "Naming the workspace with AI…")
            : creatingStatus
        let request = SupermuxAgentLaunchRequest(
            projectId: target.projectID,
            prompt: prompt,
            command: command,
            model: selectedModel,
            effort: selectedEffort,
            baseBranch: Self.requestedBaseBranch(selection: baseBranch, wasEdited: baseBranchWasEdited),
            workspaceName: workspaceName,
            branchName: branchInput
        )
        return Task {
            do {
                try await target.startAgent(request) {
                    self.phase = .runningGit
                    self.statusMessage = self.creatingStatus
                }
                recordDevice(entry)
                onFinished()
            } catch is CancellationError {
                // Cancel (or the sheet going away) while naming. A request
                // lost after it was sent comes back as an "outcome unknown"
                // failure from the target instead.
                phase = .idle
                statusMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
                phase = .idle
            }
        }
    }

    /// The classic path: AI names the branch from the workspace name only when
    /// the branch was left blank; a typed branch is respected.
    private func createPlain(
        on target: any SupermuxWorktreeCreationTarget,
        entry: SupermuxWorktreeDeviceEntry,
        onFinished: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        phase = .naming
        errorMessage = nil
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedBase = Self.requestedBaseBranch(selection: baseBranch, wasEdited: baseBranchWasEdited)
        let typedBranch = branchInput
        return Task {
            var branchToUse = typedBranch
            if trimmedBranch.isEmpty, !trimmedName.isEmpty,
               await target.isAIBranchNamingConfigured() {
                statusMessage = String(
                    localized: "supermux.newWorktree.status.naming",
                    defaultValue: "Generating branch name with AI…"
                )
                if let suggestion = await target.suggestBranchName(forWorkspaceName: trimmedName) {
                    branchToUse = suggestion
                }
            }
            statusMessage = nil
            if Task.isCancelled {
                phase = .idle
                return
            }
            // Point of no return: Cancel is disabled from here and the created
            // worktree is always delivered by the target.
            phase = .runningGit
            if target.remoteDeviceName != nil { statusMessage = creatingStatus }
            do {
                try await target.createWorktree(
                    branchName: branchToUse,
                    baseBranch: selectedBase,
                    workspaceName: trimmedName.isEmpty ? nil : trimmedName
                )
                recordDevice(entry)
                onFinished()
            } catch is CancellationError {
                // Only a cancelled flow gets here: targets report a request
                // lost after it was sent as an "outcome unknown" failure.
                phase = .idle
                statusMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
                phase = .idle
            }
        }
    }

    /// "Creating on <Mac>…" for another Mac, else the classic text.
    private var creatingStatus: String {
        if let name = target?.remoteDeviceName {
            return String(localized: "supermux.newWorktree.status.creatingOn", defaultValue: "Creating on \(name)…")
        }
        return String(localized: "supermux.agent.status.creating", defaultValue: "Creating worktree…")
    }

    private func recordDevice(_ entry: SupermuxWorktreeDeviceEntry) {
        lastDevices?.record(deviceKey: entry.deviceKey, forProject: projectID)
    }
}
