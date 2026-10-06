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
/// Switching Mac keeps the prompt, attached images, workspace name and branch
/// the user typed, and reloads that Mac's starting branches and Claude options. A load that
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

    /// The unified project id.
    public let projectID: UUID
    /// The device picker's rows, each with its Mac's link state read live: a
    /// Mac that finishes connecting while the sheet is open becomes
    /// selectable, and one that drops is disabled (Create too, when it is
    /// the selected one). Which Macs are listed is fixed when the sheet opens.
    public var entries: [SupermuxWorktreeDeviceEntry] {
        let now = availability()
        return rows.map { row in now[row.deviceKey].map(row.with(availability:)) ?? row }
    }
    /// The selected picker row.
    public private(set) var selectedEntryID: String?
    /// Where Create / Start Claude goes; `nil` when the selected Mac has no target.
    public private(set) var target: (any SupermuxWorktreeCreationTarget)?

    // Typed input: kept when the Mac changes.
    public var prompt = ""
    /// Images attached to the prompt (``addAttachments(_:)``), in order.
    public internal(set) var attachments: [SupermuxPromptAttachment] = []
    /// Pastes, drops or picks still being converted (``attachImages(_:)``);
    /// Start waits for them, so no image is left behind.
    public internal(set) var pendingImageImports = 0
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
    @ObservationIgnored private let rows: [SupermuxWorktreeDeviceEntry]
    @ObservationIgnored private let availability: @MainActor () -> [String: SupermuxWorktreeDeviceAvailability]
    @ObservationIgnored private var targets: [String: any SupermuxWorktreeCreationTarget] = [:]
    @ObservationIgnored private let makeTarget: @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?
    @ObservationIgnored private let lastDevices: SupermuxWorktreeLastDeviceStore?
    /// Whether the selected Mac is the user's choice (picked in the picker, or
    /// asked for from "New Worktree on ▸ <Mac>"), not one the sheet fell back to.
    @ObservationIgnored private var selectionIsChoice: Bool
    @ObservationIgnored private let onSetUp: @MainActor (SupermuxProjectSetupDestination) -> Void
    @ObservationIgnored private var createTask: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - projectID: The unified project id.
    ///   - entries: The picker rows (``SupermuxWorktreeDevicePlanner/entries(for:availability:setUpTargets:)``).
    ///   - initialEntryID: The preselected row
    ///     (``SupermuxWorktreeDevicePlanner/defaultEntryID(in:preferredDeviceKey:lastUsedDeviceKey:)``).
    ///   - initialEntryIsChoice: Whether that row is the Mac the user asked
    ///     for ("New Worktree on ▸ <Mac>"); a create there is then remembered
    ///     like a Mac picked in the sheet.
    ///   - makeTarget: Builds the target for a project copy (called once per
    ///     copy, the first time it is selected).
    ///   - lastDevices: Where a successful create on a chosen Mac records it.
    ///   - availability: Each Mac's link state now, by device key (read on
    ///     every render; a Mac missing here keeps its row's opening state).
    ///   - onSetUp: Hands a "Set Up on <Mac>…" row to the setup sheet.
    public init(
        projectID: UUID,
        entries: [SupermuxWorktreeDeviceEntry],
        initialEntryID: String?,
        initialEntryIsChoice: Bool = false,
        makeTarget: @escaping @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?,
        lastDevices: SupermuxWorktreeLastDeviceStore? = nil,
        availability: @escaping @MainActor () -> [String: SupermuxWorktreeDeviceAvailability] = { [:] },
        onSetUp: @escaping @MainActor (SupermuxProjectSetupDestination) -> Void = { _ in }
    ) {
        self.projectID = projectID
        self.rows = entries
        self.availability = availability
        self.makeTarget = makeTarget
        self.lastDevices = lastDevices
        self.selectionIsChoice = initialEntryIsChoice
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
        selectionIsChoice = true
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

    /// Whether a prompt was typed or an image attached (and the target can
    /// start Claude with it): the sheet is in its Start Claude mode.
    public var hasPrompt: Bool {
        showsPromptEditor && (hasPromptText || !attachments.isEmpty)
    }

    /// Whether the prompt has text (images alone do not tell Claude the task).
    public var hasPromptText: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the primary button is enabled: a reachable target, not
    /// mid-create, no image still converting, and text for Claude when
    /// images are attached.
    /// The branch list is optional (an untouched picker defers to the service
    /// default), so a failed or slow branch read never blocks creating.
    public var canCreate: Bool {
        phase == .idle && pendingImageImports == 0 && target != nil && selectedEntry?.canCreate == true
            && (!hasPrompt || hasPromptText)
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

    /// Changes when another Mac is selected or the selected one becomes
    /// reachable or unreachable: the sheet runs ``load()`` on every change.
    public var loadKey: String {
        "\(selectedEntryID ?? "")|\(selectedEntry?.canCreate == true)"
    }

    /// Loads the selected Mac's AI availability, branches and Claude options
    /// (nothing while it is unreachable; its hint says why). Loading again
    /// after a reconnect keeps what the user picked.
    public func load() async {
        guard let target, selectedEntry?.canCreate == true else { return }
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
    /// - Parameters:
    ///   - selectsWorkspace: Whether the new workspace becomes the window's
    ///     selected one; `false` when the create runs in the background
    ///     (``SupermuxPendingWorktreeStore``).
    ///   - onFinished: Runs once the worktree was delivered.
    @discardableResult
    public func submit(
        selectsWorkspace: Bool = true,
        onFinished: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        guard canCreate, let target, let entry = selectedEntry else { return nil }
        let delivery = Delivery(entry: entry, selectsWorkspace: selectsWorkspace, onFinished: onFinished)
        let task = hasPrompt
            ? startAgent(on: target, delivery: delivery)
            : createPlain(on: target, delivery: delivery)
        createTask = task
        return task
    }

    /// Aborts the naming phase (git, once started, still delivers).
    public func cancel() {
        createTask?.cancel()
    }

    /// Where a create's result goes: the Mac to remember, whether its
    /// workspace is selected, and the caller's completion.
    private struct Delivery {
        let entry: SupermuxWorktreeDeviceEntry
        let selectsWorkspace: Bool
        let onFinished: @MainActor () -> Void
    }

    /// The Claude path: names from the prompt (typed fields win), worktree,
    /// and a workspace whose terminal runs the command — all on the target.
    private func startAgent(
        on target: any SupermuxWorktreeCreationTarget,
        delivery: Delivery
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
        let files = attachments.map(\.fileURL)
        let namingStatus = statusMessage
        return Task {
            var request = request
            do {
                // The images go first (an upload to another Mac): a failure
                // there leaves nothing created.
                if !files.isEmpty {
                    if let name = target.remoteDeviceName {
                        statusMessage = String(
                            localized: "supermux.newWorktree.status.sendingImages",
                            defaultValue: "Sending images to \(name)…"
                        )
                    }
                    request.attachmentPaths = try await target.stageAttachments(files)
                    try Task.checkCancellation()
                    statusMessage = namingStatus
                }
                try await target.startAgent(request, selectsWorkspace: delivery.selectsWorkspace) {
                    self.phase = .runningGit
                    self.statusMessage = self.creatingStatus
                }
                recordDevice(delivery.entry)
                delivery.onFinished()
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
        delivery: Delivery
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
            statusMessage = creatingStatus
            do {
                try await target.createWorktree(
                    branchName: branchToUse,
                    baseBranch: selectedBase,
                    workspaceName: trimmedName.isEmpty ? nil : trimmedName,
                    selectsWorkspace: delivery.selectsWorkspace
                )
                recordDevice(delivery.entry)
                delivery.onFinished()
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

    /// Remembers the Mac of a successful create when the user chose it, or
    /// when no Mac is remembered yet. A Mac the sheet fell back to (the
    /// remembered one lacks this project or cannot create now) leaves the
    /// memory alone: the remembered Mac is skipped here, not forgotten.
    private func recordDevice(_ entry: SupermuxWorktreeDeviceEntry) {
        guard let lastDevices, selectionIsChoice || lastDevices.deviceKey() == nil else { return }
        lastDevices.record(deviceKey: entry.deviceKey)
    }
}
