public import Foundation
import Observation

/// The New Worktree creates running in the background, held app-wide and
/// drawn only by the window that started each one (its `owner`): that window's
/// targets open the workspace, so its sidebar is where the row belongs.
///
/// Create / Start Claude hands its sheet here and the sheet closes at once, so
/// the next task can start without waiting for AI naming and git. The sidebar
/// draws each create as a loading row under the project it was started from
/// until its workspace is open; the workspace opens without switching the
/// window, so whatever the user moved on to keeps the focus. A failed create
/// stays as a row that reopens its sheet, everything typed still in it, or is
/// dismissed.
@MainActor
@Observable
public final class SupermuxPendingWorktreeStore {
    /// Every create, oldest first.
    public private(set) var creations: [SupermuxPendingWorktreeCreation] = []

    /// Creates an empty store.
    public init() {}

    /// The creates under one sidebar project row of one window, oldest first.
    /// - Parameters:
    ///   - rowID: A local project's id, or a remote-only row's id.
    ///   - owner: The window, as given to ``start(_:rowID:owner:)``.
    public func creations(forRow rowID: UUID, owner: AnyHashable?) -> [SupermuxPendingWorktreeCreation] {
        creations.filter { $0.rowID == rowID && $0.owner == owner }
    }

    /// Starts the sheet's Create / Start Claude without waiting for it.
    /// - Parameters:
    ///   - sheet: The sheet to run (its inputs as typed).
    ///   - rowID: The sidebar project row to show it under.
    ///   - owner: The window whose sheet started it (any stable key the host
    ///     picks); only that window draws its row.
    /// - Returns: The running create, or `nil` when the sheet cannot create now.
    @discardableResult
    public func start(
        _ sheet: SupermuxNewWorktreeSheetModel,
        rowID: UUID,
        owner: AnyHashable?
    ) -> SupermuxPendingWorktreeCreation? {
        let creation = SupermuxPendingWorktreeCreation(rowID: rowID, owner: owner, sheet: sheet)
        // Removed the moment the workspace is delivered, so the loading row
        // and the workspace row never show together.
        let finished: @MainActor () -> Void = { [weak self] in self?.remove(creation.id) }
        guard let task = sheet.submit(selectsWorkspace: false, onFinished: finished) else { return nil }
        creations.append(creation)
        Task { [weak self] in
            await task.value
            // A failure keeps its row; a cancelled create leaves nothing to show.
            if creation.failure == nil { self?.remove(creation.id) }
        }
        return creation
    }

    /// Cancels a create that is still naming; git, once running, finishes.
    public func cancel(_ id: UUID) {
        guard let creation = creation(id), creation.canCancel else { return }
        creation.sheet.cancel()
    }

    /// Removes a failed create's row.
    public func dismiss(_ id: UUID) {
        guard creation(id)?.failure != nil else { return }
        remove(id)
    }

    /// Takes a failed create out of the sidebar so its sheet can be shown
    /// again, with the error and everything typed.
    /// - Returns: The create, or `nil` unless it failed.
    public func reopen(_ id: UUID) -> SupermuxPendingWorktreeCreation? {
        guard let creation = creation(id), creation.failure != nil else { return nil }
        remove(id)
        return creation
    }

    private func creation(_ id: UUID) -> SupermuxPendingWorktreeCreation? {
        creations.first { $0.id == id }
    }

    private func remove(_ id: UUID) {
        creations.removeAll { $0.id == id }
    }
}

/// One New Worktree create running in the background. Its sheet model runs
/// the flow; the row reads that model's phase, status and error.
@MainActor
public final class SupermuxPendingWorktreeCreation: Identifiable {
    /// Stable id of the sidebar row.
    public let id = UUID()
    /// The sidebar project row it shows under: a local project's id, or a
    /// remote-only row's id.
    public let rowID: UUID
    /// The window that started it.
    public let owner: AnyHashable?
    /// The name shown while it runs.
    public let title: String
    /// The sheet running the create, shown again by ``SupermuxPendingWorktreeStore/reopen(_:)``.
    public let sheet: SupermuxNewWorktreeSheetModel

    init(rowID: UUID, owner: AnyHashable?, sheet: SupermuxNewWorktreeSheetModel) {
        self.rowID = rowID
        self.owner = owner
        self.title = sheet.backgroundTitle
        self.sheet = sheet
    }

    /// The error sentence once the create failed; `nil` while it runs.
    public var failure: String? {
        sheet.phase == .idle ? sheet.errorMessage : nil
    }

    /// Whether Cancel still applies: AI naming can stop, git cannot.
    public var canCancel: Bool { sheet.phase == .naming }

    /// The value the sidebar row renders. A failure gets a short line there
    /// (git's own output leads with noise that would fill the row) and its
    /// full sentence in the tooltip and the reopened sheet.
    public var row: SupermuxPendingWorktreeRow {
        let status = failure == nil
            ? sheet.statusMessage ?? String(localized: "supermux.agent.status.creating", defaultValue: "Creating worktree…")
            : String(localized: "supermux.pendingWorktree.failed", defaultValue: "Couldn’t create the worktree")
        return SupermuxPendingWorktreeRow(
            id: id,
            title: title,
            status: status,
            detail: failure,
            isFailed: failure != nil,
            canCancel: canCancel
        )
    }
}

extension SupermuxNewWorktreeSheetModel {
    /// What the sidebar calls a create running in the background: the typed
    /// workspace name, else the one the prompt suggests, else the typed branch.
    var backgroundTitle: String {
        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if hasPrompt, let derived = SupermuxPromptNaming.names(from: prompt) { return derived.workspaceName }
        let branch = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }
        return String(localized: "supermux.pendingWorktree.untitled", defaultValue: "New Worktree")
    }
}
