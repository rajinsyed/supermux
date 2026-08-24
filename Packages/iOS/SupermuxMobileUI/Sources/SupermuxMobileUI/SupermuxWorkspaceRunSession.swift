import Foundation
public import Observation
import SupermuxMobileCore
import SupermuxMobileKit

/// Owns the project and run-state session used by the workspace title menu.
///
/// The workspace detail view keeps one instance alive while it is visible. The
/// session follows the authoritative `projects.list` and `run.state` streams so
/// the menu uses the same command availability and start/stop state as the
/// Projects list instead of maintaining a parallel optimistic copy.
@MainActor
@Observable
public final class SupermuxWorkspaceRunSession {
    /// The most recent start/stop failure, presented by the workspace-tools modifier.
    public private(set) var actionErrorDescription: String?

    private var projectsStore: SupermuxMobileProjectsStore?
    private var runStore: SupermuxMobileRunStore?
    private var busyProjectIDs: Set<String> = []
    @ObservationIgnored private var sessionConnectionID: AnyHashable?

    /// Creates an idle workspace run session.
    public init() {}

    /// Whether the title menu should show a run action for this project.
    ///
    /// The action stays hidden until the authoritative project list proves that
    /// the project has at least one nonblank run command.
    ///
    /// - Parameter projectID: The workspace's owning project id, or `nil` for an unassociated workspace.
    /// - Returns: `true` when a start/stop action is available.
    public func showsEntry(forProjectID projectID: String?) -> Bool {
        menuState(forProjectID: projectID) != nil
    }

    /// Stable identity for the equatable workspace title menu.
    ///
    /// - Parameter projectID: The workspace's owning project id.
    /// - Returns: A token that changes when command availability, run state, or busy state changes.
    public func menuIdentityToken(forProjectID projectID: String?) -> String {
        guard let state = menuState(forProjectID: projectID) else { return "hidden" }
        let commands = state.commands
            .map { "\($0.id):\($0.title)" }
            .joined(separator: "\u{1F}")
        return "\(state.projectID)|\(state.isRunning)|\(state.isBusy)|\(commands)"
    }

    /// Runs one connection's project and run-state streams until cancelled.
    func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable?
    ) async {
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
        guard capabilities.supportsProjects, capabilities.supportsRun else {
            endSession()
            return
        }

        if connectionID != sessionConnectionID || projectsStore == nil || runStore == nil {
            projectsStore = SupermuxMobileProjectsStore(client: client, capabilities: capabilities)
            runStore = SupermuxMobileRunStore(client: client, capabilities: capabilities)
            sessionConnectionID = connectionID
            busyProjectIDs = []
            actionErrorDescription = nil
        }

        guard let projectsStore, let runStore else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await projectsStore.run() }
            group.addTask { await runStore.run() }
        }
    }

    /// Drops the connection-scoped stores and hides the menu entry.
    func endSession() {
        projectsStore = nil
        runStore = nil
        sessionConnectionID = nil
        busyProjectIDs = []
        actionErrorDescription = nil
    }

    /// Starts all commands, or one selected command, through the shared run store.
    func startRun(projectID: String, commandID: Int?) async -> Bool {
        await perform(projectID: projectID) { store in
            try await store.startRun(projectID: projectID, commandID: commandID)
        }
    }

    /// Stops the project's active run through the shared run store.
    func stopRun(projectID: String) async -> Bool {
        await perform(projectID: projectID) { store in
            try await store.stopRun(projectID: projectID)
        }
    }

    /// Clears the error after the outer alert is dismissed.
    func dismissActionError() {
        actionErrorDescription = nil
    }

    struct MenuState: Equatable {
        struct Command: Identifiable, Equatable {
            let id: Int
            let title: String
        }

        let projectID: String
        let isRunning: Bool
        let isBusy: Bool
        let commands: [Command]
    }

    func menuState(forProjectID projectID: String?) -> MenuState? {
        guard let projectID,
              let project = projectsStore?.projects.first(where: { $0.id == projectID }),
              runStore?.showsRun == true else {
            return nil
        }
        let commands = (project.runCommands ?? []).enumerated().compactMap { index, command in
            let title = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : MenuState.Command(id: index, title: title)
        }
        guard !commands.isEmpty else { return nil }
        return MenuState(
            projectID: projectID,
            isRunning: runStore?.isRunning(projectID: projectID) == true,
            isBusy: busyProjectIDs.contains(projectID),
            commands: commands
        )
    }

    private func perform(
        projectID: String,
        operation: (SupermuxMobileRunStore) async throws -> Void
    ) async -> Bool {
        guard !busyProjectIDs.contains(projectID) else { return false }
        guard let runStore else {
            actionErrorDescription = SupermuxMacUnavailableError().localizedDescription
            return false
        }

        busyProjectIDs.insert(projectID)
        actionErrorDescription = nil
        defer { busyProjectIDs.remove(projectID) }
        do {
            try await operation(runStore)
            return true
        } catch {
            actionErrorDescription = error.localizedDescription
            return false
        }
    }
}
