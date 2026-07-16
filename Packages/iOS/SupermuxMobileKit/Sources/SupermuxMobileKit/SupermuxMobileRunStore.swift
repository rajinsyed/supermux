public import Foundation
import Observation
public import SupermuxMobileCore

/// Main-actor state for the phone's run/launch/action controls: the
/// per-project run state (`run.state` + `supermux.run.updated` refetch), the
/// start/stop actions, preset launching, and project-action execution.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected. The
/// run loop is inert without `supermux.run.v1`; `launchPreset`/`runAction`
/// are additionally gated on `supermux.presets.v1` / `supermux.actions.v1`
/// — against an upstream Mac no request is ever issued.
///
/// Run state mirrors the Mac coordinator's optimistic bookkeeping (desktop
/// parity): `run.start`/`run.stop` apply the returned row immediately, and
/// every other transition arrives as a `supermux.run.updated` poke followed
/// by a `run.state` refetch.
///
/// Lifecycle: the section model runs ``run()`` inside the session task, so
/// the live subscription is structured — cancelled with the session.
@MainActor
@Observable
public final class SupermuxMobileRunStore {
    /// One run-state row per registered project, in the Mac's order.
    public private(set) var runs: [SupermuxRunStateDTO] = []

    /// Whether at least one `run.state` fetch has succeeded.
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up.
    public private(set) var isConnected = false

    /// Human-readable description of the most recent fetch failure, for a
    /// non-blocking error surface. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Cancellable reconnect-backoff sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void

    /// Whether the phone shows run indicators/controls at all: gated on the
    /// host advertising `supermux.run.v1`.
    public var showsRun: Bool { capabilities.supportsRun }

    /// Whether the phone shows preset launchers: gated on `supermux.presets.v1`.
    public var showsPresetLaunch: Bool { capabilities.supportsPresets }

    /// Whether the phone shows the project-actions menu: gated on
    /// `supermux.actions.v1`.
    public var showsActions: Bool { capabilities.supportsActions }

    /// Creates a run store.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - now: Clock seam for the reconnect-health check.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.now = now
        self.idleSleep = idleSleep
    }

    /// The current run row for one project, if `run.state` reported one.
    /// - Parameter projectID: The project's UUID string.
    public func run(forProjectID projectID: String) -> SupermuxRunStateDTO? {
        runs.first { $0.projectId == projectID }
    }

    /// Whether the project's run command is currently running.
    /// - Parameter projectID: The project's UUID string.
    public func isRunning(projectID: String) -> Bool {
        run(forProjectID: projectID)?.isRunning == true
    }

    /// Follows the live `supermux.run.updated` stream until cancelled,
    /// refetching `run.state` inside each subscription so no poke falls into
    /// a fetch/subscribe gap. A no-op without `supermux.run.v1`. Mirrors
    /// ``SupermuxMobileProjectsStore/run()``.
    public func run() async {
        guard capabilities.supportsRun else { return }
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST: pokes emitted while the fetch is in flight
            // buffer in the stream and replay after it, instead of dropping.
            let stream = await client.events(topics: [.runUpdated])
            isConnected = true
            let streamStartedAt = now()
            await refetch()
            for await event in stream where event.topic == .runUpdated {
                await refetch()
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Liveness, not traffic, is the health signal — an idle stream can
            // legitimately stay silent for hours.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// `mobile.supermux.run.start`: starts the project's run command and
    /// applies the returned row immediately (the Mac's answer IS the
    /// authoritative post-transition state — no refetch round-trip needed;
    /// the observer poke that follows refetches anyway). Errors rethrow for
    /// the control to display.
    ///
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - commandID: The chosen run command's 0-based `run_commands` index;
    ///     `nil` (the default control) starts every configured command with
    ///     desktop ⌘G `&&`-chaining semantics.
    public func startRun(projectID: String, commandID: Int? = nil) async throws {
        guard capabilities.supportsRun else { throw SupermuxMacUnavailableError() }
        let response = try await client.runStart(
            SupermuxRunStartRequest(projectID: projectID, commandID: commandID)
        )
        apply(response.run)
    }

    /// `mobile.supermux.run.stop`: interrupts the project's running command
    /// and applies the returned row immediately. Errors rethrow for the
    /// control to display.
    /// - Parameter projectID: The project's UUID string.
    public func stopRun(projectID: String) async throws {
        guard capabilities.supportsRun else { throw SupermuxMacUnavailableError() }
        let response = try await client.runStop(SupermuxRunStopRequest(projectID: projectID))
        apply(response.run)
    }

    /// `mobile.supermux.preset.launch`: runs a global preset in a workspace
    /// opened (or focused) at the project's root — the phone navigates to
    /// the returned workspace. Errors rethrow for the caller to display.
    ///
    /// - Parameters:
    ///   - presetID: The preset's UUID string.
    ///   - projectID: The target project's UUID string.
    /// - Returns: The hosting workspace + spawned terminal ids.
    public func launchPreset(presetID: String, projectID: String) async throws -> SupermuxPresetLaunchResponse {
        guard capabilities.supportsPresets else { throw SupermuxMacUnavailableError() }
        return try await client.presetLaunch(
            SupermuxPresetLaunchRequest(presetID: presetID, target: .project(id: projectID))
        )
    }

    /// `mobile.supermux.action.run`: runs one project action. An `open_url`
    /// outcome carries the URL back for the CALLER to open locally (nothing
    /// executed Mac-side); a `command` outcome already ran in a fresh Mac
    /// terminal. Errors rethrow for the caller to display.
    ///
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - actionID: The action's UUID string.
    /// - Returns: The outcome (`opensURLLocally` + `url`, or `ok`).
    public func runAction(projectID: String, actionID: String) async throws -> SupermuxActionRunResponse {
        guard capabilities.supportsActions else { throw SupermuxMacUnavailableError() }
        return try await client.actionRun(
            SupermuxActionRunRequest(projectID: projectID, actionID: actionID)
        )
    }

    /// Replaces (or appends) one project's row with the Mac's answer.
    private func apply(_ run: SupermuxRunStateDTO) {
        if let index = runs.firstIndex(where: { $0.projectId == run.projectId }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
    }

    private func refetch() async {
        do {
            let response = try await client.runState(SupermuxRunStateRequest())
            runs = response.runs
            hasLoaded = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
