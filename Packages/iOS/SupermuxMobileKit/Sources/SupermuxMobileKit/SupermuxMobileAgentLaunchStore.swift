public import Foundation
import Observation
public import SupermuxMobileCore

/// Main-actor state for the phone's "Start Claude in a new worktree" sheet:
/// the Mac's Claude commands, the selected command's model catalog, the
/// user's picks, and the start action.
///
/// The Mac is the source of truth (commands, catalogs, naming, git, the
/// terminal); this store only mirrors options and sends one `agent.start`.
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed capability
/// snapshot, both constructor-injected. Inert without `supermux.agent_launch.v1`.
@MainActor
@Observable
public final class SupermuxMobileAgentLaunchStore {
    /// The Mac's configured commands, in display order.
    public private(set) var commands: [String] = []
    /// The command the current catalog describes.
    public private(set) var command = ""
    /// The selected command's models (may be empty).
    public private(set) var models: [SupermuxAgentModelDTO] = []
    /// Where the catalog came from.
    public private(set) var modelsSource: SupermuxAgentLaunchOptionsDTO.ModelsSource = .unavailable
    /// A user-facing reason when the catalog is unavailable.
    public private(set) var modelsError: String?
    /// Whether an options fetch is in flight.
    public private(set) var isLoadingOptions = false
    /// Whether the first options fetch has completed (success or failure).
    public private(set) var hasLoadedOptions = false
    /// The options fetch failure to surface, if any. Cleared on success.
    public private(set) var optionsError: String?
    /// The `--model` selector to launch with; `nil` = CLI default.
    public var selectedModel: String? {
        didSet { clampEffort() }
    }
    /// The `--effort` level to launch with; `nil` = CLI default.
    public var selectedEffort: String?
    /// Whether a start is on the wire.
    public private(set) var isStarting = false

    /// The project the sheet launches into (UUID string).
    public let projectID: String

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    /// Guards against a slow options reply for a command the user has since
    /// switched away from.
    @ObservationIgnored private var optionsGeneration = 0

    /// Whether the phone shows the entry point at all.
    public var showsAgentLaunch: Bool { capabilities.supportsAgentLaunch }

    /// The descriptor for ``selectedModel``, when it is in the catalog.
    public var selectedModelDescriptor: SupermuxAgentModelDTO? {
        guard let selectedModel else { return nil }
        return models.first { $0.value == selectedModel }
    }

    /// The models offered as explicit picks (the CLI's `default` entry is the
    /// default row, not a selectable model).
    public var selectableModels: [SupermuxAgentModelDTO] { models.selectableModels }

    /// Claude Code's own default entry, when the catalog has one (its display
    /// name titles the default row).
    public var defaultModelEntry: SupermuxAgentModelDTO? { models.defaultEntry }

    /// The effort levels the current selection accepts (empty hides the
    /// picker). The default row takes effort too — see
    /// `Array<SupermuxAgentModelDTO>.effortLevels(forSelection:)`.
    public var effortLevels: [String] { models.effortLevels(forSelection: selectedModel) }

    /// Creates the store.
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - projectID: The project's UUID string.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        projectID: String
    ) {
        self.client = client
        self.capabilities = capabilities
        self.projectID = projectID
    }

    /// Fetches the Mac's commands and the catalog for `command` (or the Mac's
    /// remembered selection when `nil`). Applies the Mac's last-used model
    /// and effort for that command as the initial picks. A no-op without the
    /// capability.
    /// - Parameters:
    ///   - command: The command to describe, or `nil` for the Mac's default.
    ///   - refresh: Whether to bypass the Mac's cached catalog.
    public func loadOptions(command: String? = nil, refresh: Bool = false) async {
        guard capabilities.supportsAgentLaunch else { return }
        optionsGeneration += 1
        let generation = optionsGeneration
        isLoadingOptions = true
        optionsError = nil
        defer {
            if generation == optionsGeneration {
                isLoadingOptions = false
                hasLoadedOptions = true
            }
        }
        do {
            let options = try await client.agentOptions(SupermuxAgentOptionsRequest(
                projectID: projectID,
                command: command,
                refresh: refresh
            ))
            guard generation == optionsGeneration else { return }
            apply(options)
        } catch {
            guard generation == optionsGeneration else { return }
            optionsError = error.localizedDescription
        }
    }

    /// Switches to another command and reloads its catalog. Unknown commands
    /// are ignored.
    /// - Parameter newCommand: One of ``commands``.
    public func selectCommand(_ newCommand: String) async {
        guard commands.contains(newCommand), newCommand != command else { return }
        command = newCommand
        // Everything that described the OLD catalog goes: a failed reload
        // must not show the previous command's reason under the new one.
        models = []
        modelsSource = .unavailable
        modelsError = nil
        selectedModel = nil
        selectedEffort = nil
        await loadOptions(command: newCommand)
    }

    /// Re-probes the current command's catalog on the Mac.
    public func refreshModels() async {
        await loadOptions(command: command.isEmpty ? nil : command, refresh: true)
    }

    /// `mobile.supermux.agent.start` with the current picks. Errors rethrow
    /// for the sheet to display; the store stays usable for another attempt.
    /// Throws ``SupermuxMacUnavailableError`` without `supermux.agent_launch.v1`
    /// — the same gate ``loadOptions(command:refresh:)`` applies.
    /// - Parameters:
    ///   - prompt: The task Claude starts on.
    ///   - baseBranch: The branch to start from, or `nil` for the default.
    ///   - workspaceName: A typed workspace title; blank derives from the prompt.
    ///   - branchName: A typed branch; blank derives from the prompt.
    /// - Returns: The Mac's result (worktree, names, opened workspace id).
    public func start(
        prompt: String,
        baseBranch: String? = nil,
        workspaceName: String? = nil,
        branchName: String? = nil
    ) async throws -> SupermuxAgentStartResponse {
        guard capabilities.supportsAgentLaunch else { throw SupermuxMacUnavailableError() }
        guard !isStarting else { throw SupermuxAgentLaunchStoreError.alreadyStarting }
        isStarting = true
        defer { isStarting = false }
        return try await client.agentStart(SupermuxAgentStartRequest(
            projectID: projectID,
            prompt: prompt,
            command: command.isEmpty ? nil : command,
            model: selectedModel,
            effort: selectedEffort,
            baseBranch: normalized(baseBranch),
            workspaceName: normalized(workspaceName),
            branchName: normalized(branchName)
        ))
    }

    private func apply(_ options: SupermuxAgentLaunchOptionsDTO) {
        commands = options.commands
        command = options.selectedCommand
        models = options.models
        modelsSource = options.modelsSource
        modelsError = options.modelsSource == .unavailable ? options.modelsError : nil
        if let last = options.lastModel, models.selectableModels.contains(where: { $0.value == last }) {
            selectedModel = last
        } else {
            selectedModel = nil
        }
        // Effort applies to the default row too, so keep the remembered level
        // and let the clamp drop it only when this selection rejects it.
        selectedEffort = options.lastEffort
        clampEffort()
    }

    /// Drops an effort the selected model does not accept.
    private func clampEffort() {
        guard let effort = selectedEffort else { return }
        if !effortLevels.contains(effort) {
            selectedEffort = nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Local (never wire) errors of ``SupermuxMobileAgentLaunchStore``.
public enum SupermuxAgentLaunchStoreError: Error, Equatable, Sendable {
    /// A start is already on the wire.
    case alreadyStarting
}
