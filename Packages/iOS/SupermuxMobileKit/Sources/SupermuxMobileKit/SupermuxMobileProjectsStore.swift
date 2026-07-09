public import Foundation
import Observation
public import SupermuxMobileCore

/// Main-actor state for the phone's Projects section: the project list,
/// the Mac sidebar's collapse state, and icon fetches through the etag
/// cache.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected. The
/// section is hidden (and the store inert) unless the host advertises
/// `supermux.projects.v1`.
///
/// Lifecycle: the owning view runs ``run()`` inside its `.task` modifier so
/// the live subscription is structured — cancelled automatically when the
/// view disappears, never stored where it could leak.
@MainActor
@Observable
public final class SupermuxMobileProjectsStore {
    /// The registered projects, in the Mac sidebar's order.
    public private(set) var projects: [SupermuxProjectDTO] = []

    /// The global terminal presets, in the Mac bar's order (the desktop shows
    /// the same set above every workspace's terminal — presets are NOT scoped
    /// per project). Synced from `projects.list`, which carries them since
    /// m2-f5; against an older host this stays empty.
    public private(set) var presets: [SupermuxTerminalPresetDTO] = []

    /// Whether the last successful list actually carried the `presets` field.
    /// A pre-m2-f5 host omits it even while advertising `supermux.presets.v1`
    /// (the CRUD capability predates the read shape); the presets UI must
    /// hide then, or the bar would look permanently — and wrongly — empty.
    private var listCarriesPresets = false

    /// Whether the Mac sidebar's Projects section is collapsed. Seeded from
    /// the Mac; `false` until the first successful fetch.
    public private(set) var isSectionCollapsed = false

    /// Whether at least one fetch has succeeded (drives placeholder vs list).
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up. The stream ends when
    /// the connection drops; ``run()`` resubscribes while it remains active.
    public private(set) var isConnected = false

    /// Human-readable description of the most recent fetch failure, for a
    /// non-blocking error surface. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let iconCache: SupermuxProjectIconCache
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Cancellable reconnect-backoff sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void

    /// Whether the phone shows the Projects section at all (UI-02): gated on
    /// the host advertising `supermux.projects.v1`.
    public var showsProjectsSection: Bool { capabilities.supportsProjects }

    /// Whether the phone shows the global Presets area: the host must
    /// advertise `supermux.presets.v1` AND have proven the m2-f5 read shape
    /// by carrying `presets` on `projects.list` (an upstream Mac, an older
    /// fork Mac, or a not-yet-loaded session renders no presets UI at all).
    public var showsPresets: Bool { capabilities.supportsPresets && listCarriesPresets }

    /// Creates a projects store.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - iconCache: The etag-keyed icon cache (shareable across stores).
    ///   - now: Clock seam for the reconnect-health check; defaults to the
    ///     wall clock.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        iconCache: SupermuxProjectIconCache = SupermuxProjectIconCache(),
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.iconCache = iconCache
        self.now = now
        self.idleSleep = idleSleep
    }

    /// Follows the live `supermux.projects.updated` stream until cancelled,
    /// refetching inside each subscription so no poke falls into a
    /// fetch/subscribe gap. A no-op without `supermux.projects.v1` — against
    /// an upstream Mac the store never issues a request.
    ///
    /// If the stream ends while the task is still active (connection drop),
    /// the store marks itself disconnected, resubscribes, and refetches so
    /// changes missed while down are recovered.
    public func run() async {
        guard capabilities.supportsProjects else { return }
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST: pokes emitted while the fetch is in flight
            // buffer in the stream and replay after it, instead of dropping.
            let stream = await client.events(topics: [.projectsUpdated])
            isConnected = true
            let streamStartedAt = now()
            await refetch()
            for await event in stream {
                guard event.topic == .projectsUpdated else { continue }
                await refetch()
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Back off before resubscribing unless the stream was healthy
            // (survived a while): liveness, not traffic, is the health
            // signal — an idle stream can legitimately stay silent for hours.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// Fetches a project's custom icon PNG through the etag cache.
    ///
    /// Sends the cached etag when present; a `not_modified` answer serves
    /// the cached bytes, fresh bytes replace the cache entry, and a failed
    /// fetch falls back to whatever is cached. Returns `nil` when the
    /// project has no custom icon (SF symbol / letter avatars render
    /// natively, per the §7 display order) or the capability is absent.
    ///
    /// - Parameter project: The project whose icon to fetch.
    /// - Returns: The icon's PNG bytes, or `nil`.
    public func iconPNGData(for project: SupermuxProjectDTO) async -> Data? {
        guard capabilities.supportsProjects, project.hasCustomIcon == true else { return nil }
        let cached = await iconCache.entry(forProjectID: project.id)
        do {
            let response = try await client.projectIcon(projectID: project.id, etag: cached?.etag)
            if response.notModified == true, let cached {
                return cached.pngData
            }
            guard let etag = response.etag, let pngData = response.pngData else {
                return cached?.pngData
            }
            await iconCache.store(.init(etag: etag, pngData: pngData), forProjectID: project.id)
            return pngData
        } catch {
            return cached?.pngData
        }
    }

    // MARK: - Write actions (optimistic-free: send, await result, refetch)

    /// `mobile.supermux.project.create`: registers the folder at `rootPath`
    /// on the Mac (which imports a repo-shipped `config.json` exactly like
    /// the desktop add path, and returns the existing record for an
    /// already-registered folder). Refetches the list on success; errors
    /// rethrow for the editor sheet to display.
    ///
    /// - Parameter rootPath: Absolute folder path on the Mac (trimmed here;
    ///   existence is validated Mac-side and surfaces as `invalid_params`).
    /// - Returns: The created (or pre-existing) record.
    public func createProject(rootPath: String) async throws -> SupermuxProjectDTO {
        guard capabilities.supportsProjects else { throw SupermuxMacUnavailableError() }
        let response = try await client.projectCreate(SupermuxProjectCreateRequest(
            rootPath: rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        await refetch()
        return response.project
    }

    /// `mobile.supermux.project.update`: applies a present-key patch built by
    /// ``SupermuxProjectEditorDraft/patch(from:)``. Refetches on success;
    /// errors (e.g. `invalid_params` for a config-managed field) rethrow for
    /// the editor sheet to display.
    ///
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - patch: The present-key patch (only changed fields).
    /// - Returns: The updated record.
    public func updateProject(projectID: String, patch: SupermuxProjectPatch) async throws -> SupermuxProjectDTO {
        guard capabilities.supportsProjects else { throw SupermuxMacUnavailableError() }
        let response = try await client.projectUpdate(SupermuxProjectUpdateRequest(
            projectID: projectID,
            patch: patch
        ))
        await refetch()
        return response.project
    }

    /// `mobile.supermux.project.delete`: unregisters the project (worktrees
    /// and the repository stay on the Mac's disk — desktop semantics; the
    /// confirmation dialog lives on the phone). Refetches on success.
    /// - Parameter projectID: The project's UUID string.
    public func deleteProject(projectID: String) async throws {
        guard capabilities.supportsProjects else { throw SupermuxMacUnavailableError() }
        _ = try await client.projectDelete(SupermuxProjectDeleteRequest(projectID: projectID))
        await refetch()
    }

    /// `mobile.supermux.projects.set_section_collapsed`: persists the
    /// section's collapse state Mac-side (the same shared mutation path the
    /// desktop header uses). Adopts the Mac's answer on success; a failure
    /// surfaces through ``lastErrorDescription`` (the local toggle keeps the
    /// section responsive either way).
    /// - Parameter collapsed: The collapse state to persist.
    public func setSectionCollapsed(_ collapsed: Bool) async {
        guard capabilities.supportsProjects else { return }
        do {
            let response = try await client.projectsSetSectionCollapsed(
                SupermuxProjectsSetSectionCollapsedRequest(collapsed: collapsed)
            )
            isSectionCollapsed = response.sectionCollapsed ?? collapsed
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// `mobile.supermux.preset.create`: appends a launchable terminal preset
    /// (the Mac assigns the identity and requires non-empty name + command —
    /// build the request via ``SupermuxPresetDraft/createRequest()``).
    /// Refetches the list on success (presets travel on `projects.list`).
    /// - Parameter request: The typed create request.
    /// - Returns: The created record.
    public func createPreset(_ request: SupermuxPresetCreateRequest) async throws -> SupermuxTerminalPresetDTO {
        guard capabilities.supportsPresets else { throw SupermuxMacUnavailableError() }
        let preset = try await client.presetCreate(request).preset
        await refetch()
        return preset
    }

    /// `mobile.supermux.preset.update`: applies a present-key patch built by
    /// ``SupermuxPresetDraft/patch(from:)``. Refetches the list on success.
    /// - Parameters:
    ///   - presetID: The preset's UUID string.
    ///   - patch: The present-key patch (only changed fields).
    /// - Returns: The updated record.
    public func updatePreset(presetID: String, patch: SupermuxPresetPatch) async throws -> SupermuxTerminalPresetDTO {
        guard capabilities.supportsPresets else { throw SupermuxMacUnavailableError() }
        let preset = try await client.presetUpdate(SupermuxPresetUpdateRequest(
            presetID: presetID,
            patch: patch
        )).preset
        await refetch()
        return preset
    }

    /// `mobile.supermux.preset.delete`: removes a preset from the Mac's bar
    /// (the confirmation dialog lives on the phone). Refetches the list on
    /// success.
    /// - Parameter presetID: The preset's UUID string.
    public func deletePreset(presetID: String) async throws {
        guard capabilities.supportsPresets else { throw SupermuxMacUnavailableError() }
        _ = try await client.presetDelete(SupermuxPresetDeleteRequest(presetID: presetID))
        await refetch()
    }

    private func refetch() async {
        do {
            let response = try await client.projectsList()
            projects = response.projects
            presets = response.presets ?? []
            listCarriesPresets = response.presets != nil
            if let sectionCollapsed = response.sectionCollapsed {
                isSectionCollapsed = sectionCollapsed
            }
            hasLoaded = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
