import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Another Mac's copy of a project as a New Worktree target, over its device
/// link: `worktrees.list {include_branches}` for the starting branches,
/// `agent.options` for Claude commands / models (and whether that Mac
/// AI-names), `worktree.suggest_branch` for AI branch names, and
/// `worktree.create {open: true}` / `agent.start` with the long deadline.
///
/// After a create the other Mac has opened a workspace there; its mirror is
/// then opened, selected and focused in this window through
/// ``SupermuxDeviceWorkspaceOpener/openWhenAvailable(_:in:focus:timeout:)``,
/// which reuses a mirror the auto-mirror coordinator is already opening. The
/// open runs after the sheet has gone (like the local flow, which dismisses
/// once git returns); a failure is shown in an alert.
@MainActor
final class SupermuxRemoteWorktreeCreationTarget: SupermuxWorktreeCreationTarget {
    /// A failed remote operation, with a sentence naming the Mac.
    struct Failure: Error, LocalizedError, Equatable {
        let code: String?
        let message: String
        var errorDescription: String? { message }
    }

    /// `agent.options` may probe a Claude command's catalog on that Mac; a
    /// link timeout reconnects the link, so allow the probe's own deadline.
    static let optionsTimeout: Duration = .seconds(120)

    let location: SupermuxProjectLocation
    let machine: SurfaceMachineID
    private let deviceName: String
    private let devices: SupermuxDevices
    private let commands: SupermuxRemoteProjectCommands
    private let remoteProjects: SupermuxRemoteProjectsModel
    private let opener: SupermuxDeviceWorkspaceOpener
    private weak var tabManager: TabManager?
    private var aiNaming: Bool?
    private var knownCommands: SupermuxAgentCommandList?
    private var optionsInFlight: [String: Task<SupermuxAgentLaunchOptionsDTO, Never>] = [:]

    /// The workspace the last create opened on that Mac (E2E drivers).
    private(set) var lastCreatedRef: SupermuxRemoteWorkspaceRef?
    /// The mirror open that followed the last create (E2E drivers await it).
    private(set) var lastOpen: Task<SupermuxDeviceWorkspaceOpener.Opened, any Error>?

    /// A target for `location` (a copy on a device) that opens mirrors in
    /// `tabManager`'s window; `nil` for a copy on this Mac.
    init?(location: SupermuxProjectLocation, tabManager: TabManager, commands: SupermuxRemoteProjectCommands) {
        guard let machineID = location.machineID, let device = location.device else { return nil }
        self.location = location
        self.machine = SurfaceMachineID(rawValue: machineID)
        self.deviceName = device.name
        self.devices = commands.devices
        self.commands = commands
        self.remoteProjects = commands.remoteProjects
        self.opener = commands.opener
        self.tabManager = tabManager
    }

    var projectID: UUID { location.projectID }
    var remoteDeviceName: String? { deviceName }

    var configuredDefaultBranch: String? {
        remoteProjects.device(machine)?.project(id: location.projectID)?.defaultBranch
    }

    func loadBranches() async throws -> [String] {
        do {
            let result = try await devices.request(
                .worktreesList,
                params: ["project_id": location.projectID.uuidString, "include_branches": true],
                on: machine
            )
            return result["branches"] as? [String] ?? []
        } catch {
            throw failure(error)
        }
    }

    func isAINamingConfigured() async -> Bool {
        if let aiNaming { return aiNaming }
        _ = await agentOptions(for: knownCommands?.selected ?? "", forceRefresh: false)
        return aiNaming ?? false
    }

    /// Only when that Mac already said it AI-names (never waits for it):
    /// otherwise the blank branch goes to `worktree.create`, which AI-names it
    /// there itself when it can.
    func isAIBranchNamingConfigured() async -> Bool {
        aiNaming == true
    }

    /// That Mac's AI suggestion; a random suggestion is dropped so the create
    /// itself picks the random name, as a blank branch does on this Mac.
    func suggestBranchName(forWorkspaceName name: String) async -> String? {
        guard let result = try? await devices.request(
            .worktreeSuggestBranch,
            params: ["workspace_name": name],
            on: machine
        ), result["source"] as? String == "ai",
            let branch = result["branch_name"] as? String, !branch.isEmpty else { return nil }
        return branch
    }

    func createWorktree(branchName: String, baseBranch: String?, workspaceName: String?) async throws {
        let request = SupermuxRemoteWorktreeRequest(
            workspaceName: workspaceName ?? "",
            branchName: branchName,
            baseBranch: baseBranch ?? ""
        )
        let ref: SupermuxRemoteWorkspaceRef
        do {
            ref = try await commands.requestWorktreeCreate(location, request: request)
        } catch {
            throw failure(error)
        }
        openMirror(of: ref)
    }

    // MARK: - Prompt-first

    var supportsAgentLaunch: Bool {
        devices.cachedHostCapabilities(on: machine)
            .map { $0.contains(SupermuxMobileCapability.agentLaunchV1.rawValue) } ?? true
    }

    /// The command list is edited in that Mac's own sheet.
    var canEditAgentCommands: Bool { false }

    var initialAgentCommands: SupermuxAgentCommandList {
        knownCommands ?? SupermuxAgentCommandList(commands: [], selected: "")
    }

    func setAgentCommands(_ commands: [String]) -> SupermuxAgentCommandList { initialAgentCommands }

    /// That Mac remembers the command its `agent.start` used.
    func rememberAgentCommand(_ command: String) {}

    func agentOptions(for command: String, forceRefresh: Bool) async -> SupermuxAgentLaunchOptionsDTO {
        let key = forceRefresh ? "refresh:" + command : command
        if let running = optionsInFlight[key] { return await running.value }
        var params: [String: Any] = ["project_id": location.projectID.uuidString]
        if !command.isEmpty { params["command"] = command }
        if forceRefresh { params["refresh"] = true }
        let deviceName = self.deviceName
        let task = Task { @MainActor [devices, machine] () -> SupermuxAgentLaunchOptionsDTO in
            do {
                return try await devices.request(
                    SupermuxMobileMethod.agentOptions.rawValue,
                    params: params,
                    on: machine,
                    timeout: Self.optionsTimeout,
                    as: SupermuxAgentLaunchOptionsDTO.self
                )
            } catch {
                return SupermuxAgentLaunchOptionsDTO(
                    commands: [],
                    selectedCommand: command,
                    models: [],
                    modelsSource: .unavailable,
                    modelsError: Self.failure(error, deviceName: deviceName).localizedDescription
                )
            }
        }
        optionsInFlight[key] = task
        let options = await task.value
        optionsInFlight[key] = nil
        if let known = options.aiNamingConfigured { aiNaming = known }
        if !options.commands.isEmpty {
            knownCommands = SupermuxAgentCommandList(commands: options.commands, selected: options.selectedCommand)
        }
        return options
    }

    /// That Mac's shell builds the line, so it is not previewed here.
    func shellLinePreview(command: String, model: String?, effort: String?, prompt: String) -> String? { nil }

    func startAgent(
        _ request: SupermuxAgentLaunchRequest,
        willCreateWorktree: @escaping @MainActor () -> Void
    ) async throws {
        // Naming and git both run on that Mac inside one call; once it is
        // sent there is no taking it back.
        willCreateWorktree()
        let ref: SupermuxRemoteWorkspaceRef
        do {
            ref = try await commands.requestAgentStart(location, request: request)
        } catch {
            throw failure(error)
        }
        openMirror(of: ref)
    }

    // MARK: - Helpers

    /// Opens the new workspace's mirror in this window and selects it; runs
    /// on after the sheet is gone.
    private func openMirror(of ref: SupermuxRemoteWorkspaceRef) {
        lastCreatedRef = ref
        // With the window gone, the auto-mirror coordinator still mirrors it
        // into another window.
        guard let tabManager else { return }
        let opener = self.opener
        let deviceName = self.deviceName
        lastOpen = Task { @MainActor in
            do {
                return try await opener.openWhenAvailable(ref, in: tabManager, focus: true)
            } catch {
                Self.presentOpenFailure(error, deviceName: deviceName)
                throw error
            }
        }
    }

    private func failure(_ error: any Error) -> any Error {
        Self.failure(error, deviceName: deviceName)
    }

    /// Maps a device / host error onto a sentence naming the Mac.
    static func failure(_ error: any Error, deviceName: String) -> any Error {
        if error is CancellationError { return error }
        let code = (error as? SupermuxDeviceError)?.code
        return Failure(
            code: code,
            message: SupermuxRemoteWorktreeFailure.message(
                code: code,
                hostMessage: error.localizedDescription,
                deviceName: deviceName
            )
        )
    }

    private static func presentOpenFailure(_ error: any Error, deviceName: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "supermux.newWorktree.openFailed.title",
            defaultValue: "The worktree was created on \(deviceName), but it could not be opened here."
        )
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
