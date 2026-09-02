public import Foundation
public import SupermuxMobileCore

/// A model catalog read for one Claude command, with where it came from.
public struct SupermuxAgentModelCatalogResult: Equatable, Sendable {
    /// The command's models (may be empty when unavailable).
    public var models: [SupermuxAgentModelDTO]
    /// Whether the models came from the cache, a fresh probe, or nowhere.
    public var source: SupermuxAgentLaunchOptionsDTO.ModelsSource
    /// A user-facing reason when `source` is `unavailable`.
    public var errorDescription: String?

    /// Creates a result.
    public init(
        models: [SupermuxAgentModelDTO],
        source: SupermuxAgentLaunchOptionsDTO.ModelsSource,
        errorDescription: String? = nil
    ) {
        self.models = models
        self.source = source
        self.errorDescription = errorDescription
    }
}

/// Serves each Claude command's model catalog: cached when fresh, probed
/// otherwise, with one in-flight probe per command shared across callers.
///
/// Catalogs are persisted through the harness's ``SupermuxHarnessModelCatalogStore``
/// under a per-command pseudo-path (``storagePath(for:)``), so a `ccx` proxy
/// catalog and the plain `claude` catalog never mix, and a catalog fetched by
/// the Mac sheet is what the phone is served next.
@MainActor
public final class SupermuxAgentModelCatalog {
    /// Reads a catalog for a launch plan. Production wraps the harness probe;
    /// tests inject a stub.
    public typealias Probe = @MainActor (SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog

    private let store: SupermuxHarnessModelCatalogStore
    private let probe: Probe
    private let shellPath: String
    private let environment: [String: String]
    private var inFlight: [String: Task<[SupermuxAgentModelDTO], any Error>] = [:]

    /// Creates the catalog service.
    ///
    /// - Parameters:
    ///   - store: The persisted catalog store (shared with the harness panes).
    ///   - shellPath: The interactive shell commands resolve in.
    ///   - environment: The environment probes inherit.
    ///   - probe: The initialize probe; defaults to the harness probe.
    public init(
        store: SupermuxHarnessModelCatalogStore,
        shellPath: String = SupermuxAgentCommandProbePlan.shellPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: Probe? = nil
    ) {
        self.store = store
        self.shellPath = shellPath
        self.environment = environment
        self.probe = probe ?? { plan in
            try await SupermuxHarnessModelCatalogProbe().probe(plan: plan)
        }
    }

    /// The pseudo-path a command's catalog is cached under.
    ///
    /// The store keys by file path; a command is not a file, so it is filed
    /// under a reserved directory that no real executable lives in. Stable
    /// across working directories (the store standardizes paths against `/`).
    /// - Parameter command: The Claude command.
    public static func storagePath(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        return "/supermux-agent-command/" + escaped
    }

    /// The cached catalog for `command`, when one is still fresh.
    /// - Parameter command: The Claude command.
    public func cachedModels(for command: String) -> [SupermuxAgentModelDTO]? {
        store.snapshot(forBinaryPath: Self.storagePath(for: command))
            .map { $0.models.compactMap { SupermuxAgentModelDTO(initializeModel: $0.rawValue) } }
    }

    /// The catalog for `command`: the fresh cache when present, otherwise a
    /// probe. Never throws — an unreadable catalog degrades to an empty,
    /// `unavailable` result so the launch can still proceed on the CLI default.
    ///
    /// - Parameters:
    ///   - command: The Claude command.
    ///   - workingDirectoryURL: Where a probe runs.
    ///   - forceRefresh: Skip the cache and probe regardless.
    public func models(
        for command: String,
        workingDirectoryURL: URL,
        forceRefresh: Bool = false
    ) async -> SupermuxAgentModelCatalogResult {
        if !forceRefresh, let cached = cachedModels(for: command), !cached.isEmpty {
            return SupermuxAgentModelCatalogResult(models: cached, source: .cache)
        }
        do {
            let models = try await refresh(command: command, workingDirectoryURL: workingDirectoryURL)
            return SupermuxAgentModelCatalogResult(models: models, source: .probe)
        } catch {
            return SupermuxAgentModelCatalogResult(
                models: [],
                source: .unavailable,
                errorDescription: Self.describe(error)
            )
        }
    }

    /// Probes `command` now and persists the result. Concurrent callers for
    /// the same command share one probe.
    ///
    /// - Parameters:
    ///   - command: The Claude command.
    ///   - workingDirectoryURL: Where the probe runs.
    /// - Returns: The freshly read models.
    /// - Throws: The probe's failure.
    public func refresh(command: String, workingDirectoryURL: URL) async throws -> [SupermuxAgentModelDTO] {
        let key = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let running = inFlight[key] {
            return try await running.value
        }
        let plan = SupermuxAgentCommandProbePlan.plan(
            command: key,
            shellPath: shellPath,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment
        )
        let task = Task<[SupermuxAgentModelDTO], any Error> { @MainActor [store, probe] in
            let catalog = try await probe(plan)
            try? store.store(catalog.models, forBinaryPath: Self.storagePath(for: key))
            return catalog.models.compactMap { SupermuxAgentModelDTO(initializeModel: $0.rawValue) }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private static func describe(_ error: any Error) -> String {
        if let probeError = error as? SupermuxHarnessModelCatalogProbeError {
            switch probeError {
            case .timedOut:
                return String(
                    localized: "supermux.agent.models.error.timedOut",
                    defaultValue: "The command did not answer in time."
                )
            case .processExited(let status):
                let format = String(
                    localized: "supermux.agent.models.error.exited",
                    defaultValue: "The command exited with status %lld before listing models."
                )
                return String(format: format, Int64(status))
            case .initializeFailed(let message):
                return message ?? String(
                    localized: "supermux.agent.models.error.initialize",
                    defaultValue: "The command rejected the model request."
                )
            case .incomplete:
                return String(
                    localized: "supermux.agent.models.error.incomplete",
                    defaultValue: "The command stopped before listing models."
                )
            }
        }
        return error.localizedDescription
    }
}
