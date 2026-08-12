import CMUXMobileCore
import Foundation
import SupermuxClaudeHarness
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.claude.*` handlers backed by the desktop harness registry.
extension TerminalController {
    @MainActor
    func v2SupermuxClaudeSessionsList(params: [String: Any]) async -> V2CallResult {
        let harness = SupermuxClaudeHarnessRegistry.shared
        let records = await harness.store.loadAll()
        var snapshots: [SupermuxClaudeSessionDTO] = []
        for record in records {
            snapshots.append(await supermuxClaudeSnapshot(record: record,
                session: harness.sessions.session(id: record.stableSurfaceID)))
        }
        snapshots.sort { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
        return supermuxClaudeOK(SupermuxClaudeSessionsDTO(
            sessions: snapshots, stateVersion: harness.sessions.latestRevision
        ))
    }

    @MainActor
    func v2SupermuxClaudeSessionCreate(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeSessionCreateRequestDTO = supermuxClaudeDecode(params) else {
            return .err(code: "invalid_params", message: "Invalid Claude session parameters", data: nil)
        }
        let cwd = ((request.cwd as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .err(code: "invalid_params", message: "cwd must be an existing absolute directory", data: nil)
        }
        let launcher: ClaudeLauncher
        do { launcher = try supermuxClaudeResolveLauncher(request.launcher) }
        catch { return .err(code: "unavailable", message: "Claude launcher is unavailable", data: ["detail": "\(error)"]) }

        let id = UUID()
        var record = SupermuxHarnessSessionRecord(
            stableSurfaceID: id, launcher: launcher, workingDirectory: cwd,
            projectID: request.projectID, model: request.model, effortLevel: request.effort,
            fastMode: request.fastMode, maxThinkingTokens: request.thinkingBudget
        )
        do { try await SupermuxClaudeHarnessRegistry.shared.store.save(record) }
        catch { return .err(code: "unavailable", message: "Failed to persist Claude session", data: nil) }

        let session: ClaudeSession
        do {
            session = try await SupermuxClaudeHarnessRegistry.shared.sessions.create(
                configuration: .init(
                    id: id, launcher: launcher, workingDirectory: cwd,
                    identity: .new(sessionID: UUID().uuidString.lowercased()),
                    model: request.model, effort: request.effort
                ),
                persistence: SupermuxHarnessSessionPersistence(
                    store: SupermuxClaudeHarnessRegistry.shared.store, stableSurfaceID: id
                )
            )
        } catch {
            await SupermuxClaudeHarnessRegistry.shared.store.remove(stableSurfaceID: id)
            return .err(code: "unavailable", message: "Failed to start Claude session", data: ["detail": "\(error)"])
        }

        guard await supermuxClaudeWaitForStartup(session) else {
            let snapshot = await supermuxClaudeSnapshot(record: record, session: session)
            return supermuxClaudeOK(SupermuxClaudeSessionResultDTO(
                session: snapshot, stderrExcerpt: await session.stderrTail
            ))
        }
        do {
            try await supermuxClaudeApplyRuntimeControls(
                session: session, fastMode: request.fastMode, thinkingBudget: request.thinkingBudget
            )
        } catch {
            // The create RPC is reporting failure, so nothing may survive it:
            // a live process or a persisted record here would leak a hidden
            // session that every retry silently duplicates.
            await SupermuxClaudeHarnessRegistry.shared.sessions.remove(id: id)
            await SupermuxClaudeHarnessRegistry.shared.store.remove(stableSurfaceID: id)
            return .err(code: "unavailable", message: "Claude rejected an initial option", data: ["detail": "\(error)"])
        }
        if let prompt = request.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            await session.enqueue(text: prompt)
            record = await SupermuxClaudeHarnessRegistry.shared.store.load(stableSurfaceID: id) ?? record
            record.derivedTitle = String(prompt.prefix(80))
            try? await SupermuxClaudeHarnessRegistry.shared.store.save(record)
        }
        return supermuxClaudeOK(SupermuxClaudeSessionResultDTO(
            session: await supermuxClaudeSnapshot(record: record, session: session)
        ))
    }

    @MainActor
    func v2SupermuxClaudeSessionGet(params: [String: Any]) async -> V2CallResult {
        guard let id = supermuxClaudeSessionID(params) else { return supermuxClaudeInvalidSessionID() }
        let harness = SupermuxClaudeHarnessRegistry.shared
        guard let record = await harness.store.load(stableSurfaceID: id) else {
            return .err(code: "not_found", message: "Claude session not found", data: nil)
        }
        return supermuxClaudeOK(SupermuxClaudeSessionResultDTO(
            session: await supermuxClaudeSnapshot(record: record, session: harness.sessions.session(id: id)),
            stderrExcerpt: record.redactedDiagnostic
        ))
    }

    @MainActor
    func v2SupermuxClaudeSessionResume(params: [String: Any]) async -> V2CallResult {
        guard let id = supermuxClaudeSessionID(params) else { return supermuxClaudeInvalidSessionID() }
        let harness = SupermuxClaudeHarnessRegistry.shared
        guard var record = await harness.store.load(stableSurfaceID: id) else {
            return .err(code: "not_found", message: "Claude session not found", data: nil)
        }
        if let live = harness.sessions.session(id: id) {
            switch await live.processPhase {
            case .dormant, .spawning, .handshaking, .running, .stopping:
                return supermuxClaudeOK(SupermuxClaudeSessionResultDTO(
                    session: await supermuxClaudeSnapshot(record: record, session: live)
                ))
            case .exited, .failed:
                await harness.sessions.remove(id: id)
            }
        }
        guard let providerID = record.claudeSessionID, !providerID.isEmpty else {
            return .err(code: "unavailable", message: "Claude session has no resume identifier", data: nil)
        }
        let session: ClaudeSession
        do {
            session = try await harness.sessions.create(
                configuration: .init(
                    id: id, launcher: record.launcher, workingDirectory: record.workingDirectory,
                    identity: .resume(sessionID: providerID), model: record.model,
                    effort: record.effortLevel
                ),
                persistence: SupermuxHarnessSessionPersistence(store: harness.store, stableSurfaceID: id)
            )
        } catch {
            return .err(code: "unavailable", message: "Failed to resume Claude session", data: ["detail": "\(error)"])
        }
        if await supermuxClaudeWaitForStartup(session) {
            // Fast mode and thinking budget are runtime controls, not spawn
            // flags: a resumed process starts WITHOUT them, so re-apply the
            // persisted values or the snapshot below would report settings
            // that are not actually active. A rejection clears the persisted
            // value so the phone shows the truth rather than the wish.
            var reconciled = record
            do {
                try await supermuxClaudeApplyRuntimeControls(
                    session: session, fastMode: record.fastMode, thinkingBudget: record.maxThinkingTokens
                )
            } catch {
                reconciled.fastMode = false
                reconciled.maxThinkingTokens = nil
                try? await harness.store.save(reconciled)
                record = reconciled
            }
        }
        await session.resumeQueue()
        return supermuxClaudeOK(SupermuxClaudeSessionResultDTO(
            session: await supermuxClaudeSnapshot(record: record, session: session),
            stderrExcerpt: await session.stderrTail
        ))
    }

    @MainActor
    func v2SupermuxClaudeSessionEnd(params: [String: Any]) async -> V2CallResult {
        guard let id = supermuxClaudeSessionID(params) else { return supermuxClaudeInvalidSessionID() }
        guard await SupermuxClaudeHarnessRegistry.shared.store.load(stableSurfaceID: id) != nil else {
            return .err(code: "not_found", message: "Claude session not found", data: nil)
        }
        if let session = SupermuxClaudeHarnessRegistry.shared.sessions.session(id: id) {
            await session.terminate()
        }
        return supermuxClaudeOK(SupermuxClaudeAcknowledgementDTO(acknowledged: true))
    }

    @MainActor
    func v2SupermuxClaudeSessionDelete(params: [String: Any]) async -> V2CallResult {
        guard let id = supermuxClaudeSessionID(params) else { return supermuxClaudeInvalidSessionID() }
        let harness = SupermuxClaudeHarnessRegistry.shared
        guard await harness.store.load(stableSurfaceID: id) != nil else {
            return .err(code: "not_found", message: "Claude session not found", data: nil)
        }
        await harness.sessions.remove(id: id)
        await harness.store.remove(stableSurfaceID: id)
        return supermuxClaudeOK(SupermuxClaudeAcknowledgementDTO(acknowledged: true))
    }

    @MainActor
    func v2SupermuxClaudeSend(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeSendRequestDTO = supermuxClaudeDecode(params),
              let id = UUID(uuidString: request.sessionID) else {
            return .err(code: "invalid_params", message: "Invalid Claude send parameters", data: nil)
        }
        guard request.attachments?.isEmpty != false else {
            return .err(code: "unsupported", message: "Claude image attachments are not supported yet", data: nil)
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .err(code: "invalid_params", message: "text must not be empty", data: nil) }
        guard let session = SupermuxClaudeHarnessRegistry.shared.sessions.session(id: id) else {
            return .err(code: "not_found", message: "Claude session is not running", data: nil)
        }
        let wasIdle = await session.turnPhase == .idle
        await session.enqueue(text: text)
        let store = SupermuxClaudeHarnessRegistry.shared.store
        if var record = await store.load(stableSurfaceID: id), record.derivedTitle == nil {
            record.claudeSessionID = await session.claudeSessionID ?? record.claudeSessionID
            record.derivedTitle = String(text.prefix(80))
            record.lastActiveAt = Date()
            try? await store.save(record)
        }
        let queueCount = await session.queuedInputs.filter { $0.state == .queued }.count
        return supermuxClaudeOK(SupermuxClaudeSendResultDTO(
            queued: !wasIdle, queuePosition: wasIdle ? nil : max(queueCount, 1)
        ))
    }

    @MainActor
    func v2SupermuxClaudeInterrupt(params: [String: Any]) async -> V2CallResult {
        guard let id = supermuxClaudeSessionID(params) else { return supermuxClaudeInvalidSessionID() }
        guard let session = SupermuxClaudeHarnessRegistry.shared.sessions.session(id: id) else {
            return .err(code: "not_found", message: "Claude session is not running", data: nil)
        }
        do { try await session.interrupt() }
        catch { return .err(code: "unavailable", message: "Claude did not accept the interrupt", data: ["detail": "\(error)"]) }
        return supermuxClaudeOK(SupermuxClaudeAcknowledgementDTO(acknowledged: true))
    }

    @MainActor
    func v2SupermuxClaudeSetOption(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeSetOptionRequestDTO = supermuxClaudeDecode(params),
              let id = UUID(uuidString: request.sessionID) else {
            return .err(code: "invalid_params", message: "Invalid Claude option parameters", data: nil)
        }
        let harness = SupermuxClaudeHarnessRegistry.shared
        guard let session = harness.sessions.session(id: id),
              var record = await harness.store.load(stableSurfaceID: id) else {
            return .err(code: "not_found", message: "Claude session is not running", data: nil)
        }
        let control: ClaudeOutboundControl
        switch (request.option, request.value) {
        case (.model, .string(let value)):
            control = .setModel(value); record.model = value
        case (.effort, .string(let value)):
            control = .setEffort(value); record.effortLevel = value
        case (.fastMode, .bool(let value)):
            control = .setFastMode(value); record.fastMode = value
        case (.thinkingBudget, .integer(let value)) where value >= 0:
            control = .setMaxThinkingTokens(value); record.maxThinkingTokens = value
        default:
            return .err(code: "invalid_params", message: "Option value has the wrong type", data: nil)
        }
        do {
            try await supermuxClaudeRequireSuccess(session.sendControl(control))
            try await harness.store.save(record)
        } catch {
            return .err(code: "unavailable", message: "Claude rejected the option", data: ["detail": "\(error)"])
        }
        return supermuxClaudeOK(SupermuxClaudeSetOptionResultDTO(appliedValue: request.value))
    }

    @MainActor
    func v2SupermuxClaudeOptions(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeOptionsRequestDTO = supermuxClaudeDecode(params) else {
            return .err(code: "invalid_params", message: "Invalid Claude options parameters", data: nil)
        }
        var models: [ClaudeModelDescriptor] = []
        var slashCommands: [String] = []
        let harness = SupermuxClaudeHarnessRegistry.shared
        var session: ClaudeSession?
        if let value = request.sessionID {
            guard let id = UUID(uuidString: value), let live = harness.sessions.session(id: id) else {
                return .err(code: "not_found", message: "Claude session is not running", data: nil)
            }
            session = live
        } else {
            // A GLOBAL options request (the new-session sheet, the section
            // model's connection-scoped fetch) still deserves a catalog: the
            // model list and slash commands are launcher-global, not
            // per-session, so any initialized live session can answer. With
            // no session running the arrays stay empty and the phone falls
            // back to launcher defaults.
            for id in harness.sessions.sessionIDs {
                guard let candidate = harness.sessions.session(id: id) else { continue }
                if await candidate.systemInitialization != nil {
                    session = candidate
                    break
                }
            }
        }
        if let session {
            slashCommands = await session.systemInitialization?.slashCommands ?? []
            if let response = try? await session.sendControl(.listModels), response.isSuccess {
                models = ClaudeModelDescriptor.models(from: response.payload)
            }
        }
        let modelDTOs = models.map {
            SupermuxClaudeModelOptionDTO(
                value: $0.value, resolvedModel: $0.resolvedModel, displayName: $0.displayName,
                description: $0.description, supportedEffortLevels: $0.supportedEffortLevels,
                supportsFastMode: $0.supportsFastMode ?? false
            )
        }
        let effort = Array(Set(modelDTOs.flatMap(\.supportedEffortLevels))).sorted()
        let launchers = supermuxClaudeLauncherAvailability()
        return supermuxClaudeOK(SupermuxClaudeOptionsDTO(
            models: modelDTOs, supportedEffortLevels: effort,
            supportsFastMode: modelDTOs.contains(where: \.supportsFastMode),
            slashCommands: slashCommands, launchers: launchers
        ))
    }

    @MainActor
    func v2SupermuxClaudeHistory(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeHistoryRequestDTO = supermuxClaudeDecode(params),
              let id = UUID(uuidString: request.sessionID), request.limit > 0 else {
            return .err(code: "invalid_params", message: "Invalid Claude history parameters", data: nil)
        }
        guard let session = SupermuxClaudeHarnessRegistry.shared.sessions.session(id: id) else {
            return .err(code: "not_found", message: "Claude session is not running", data: nil)
        }
        let projection = SupermuxMobileClaudeProjection(lines: await session.transcriptLines)
        let eligible = projection.messages.filter { message in
            request.beforeSeq.map { message.seq < $0 } ?? true
        }
        let limit = min(request.limit, 200)
        var page = Array(eligible.suffix(limit))
        // The next-page cursor is strict (`seq < before_seq`), so a page
        // boundary must never split a group of messages sharing one seq —
        // the siblings left outside would be excluded by every later page.
        // Widen the page to include the whole oldest-seq group.
        if let boundarySeq = page.first?.seq, page.count < eligible.count {
            var start = eligible.count - page.count
            while start > 0, eligible[start - 1].seq == boundarySeq { start -= 1 }
            page.insert(contentsOf: eligible[start..<(eligible.count - page.count)], at: 0)
        }
        return supermuxClaudeOK(SupermuxClaudeHistoryPageDTO(
            messages: page, hasMore: eligible.count > page.count
        ))
    }

    @MainActor
    func v2SupermuxClaudeToolPayload(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeToolPayloadRequestDTO = supermuxClaudeDecode(params),
              let id = UUID(uuidString: request.sessionID) else {
            return .err(code: "invalid_params", message: "Invalid Claude tool payload parameters", data: nil)
        }
        guard let session = SupermuxClaudeHarnessRegistry.shared.sessions.session(id: id) else {
            return .err(code: "not_found", message: "Claude session is not running", data: nil)
        }
        let projection = SupermuxMobileClaudeProjection(lines: await session.transcriptLines)
        guard let data = projection.toolPayloads[request.messageID] else {
            return .err(code: "not_found", message: "Claude tool payload not found", data: nil)
        }
        let offset = request.offset ?? 0
        guard offset >= 0, offset <= Int64(data.count) else {
            return .err(code: "invalid_params", message: "offset is outside the payload", data: nil)
        }
        // The 3 MiB limit is PER CHUNK, not per payload: larger payloads are
        // served across multiple offset-cursor round trips (the client loops
        // until `eof`), keeping every reply under the transport frame ceiling.
        let start = Int(offset)
        let end = min(start + SupermuxClaudeToolPayloadChunkDTO.maximumDataBytes, data.count)
        let chunk = data.subdata(in: start..<end)
        do {
            return supermuxClaudeOK(try SupermuxClaudeToolPayloadChunkDTO(
                data: chunk, offset: offset, totalSize: Int64(data.count), eof: end == data.count
            ))
        } catch {
            return .err(code: "unavailable", message: "Failed to encode Claude tool payload", data: nil)
        }
    }

    @MainActor
    func v2SupermuxClaudeWatch(params: [String: Any]) async -> V2CallResult {
        guard let request: SupermuxClaudeWatchRequestDTO = supermuxClaudeDecode(params),
              !request.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Invalid Claude watch parameters", data: nil)
        }
        SupermuxMobileHostGlue.activateIfNeeded()
        guard let registry = SupermuxMobileHostGlue.claudeWatchRegistry else {
            return .err(code: "unavailable", message: "Claude observer is unavailable", data: nil)
        }
        if request.enable {
            let expiration = registry.watch(clientID: request.clientID)
            return supermuxClaudeOK(SupermuxClaudeWatchResultDTO(
                enabled: true, leaseExpiresAt: expiration.timeIntervalSince1970
            ))
        }
        registry.unwatch(clientID: request.clientID)
        return supermuxClaudeOK(SupermuxClaudeWatchResultDTO(
            enabled: registry.isWatching, leaseExpiresAt: nil
        ))
    }

    // MARK: - Shared mapping

    @MainActor
    private func supermuxClaudeSnapshot(
        record: SupermuxHarnessSessionRecord,
        session: ClaudeSession?
    ) async -> SupermuxClaudeSessionDTO {
        let result = await session?.latestResult
        let process = await session?.processPhase
        let turn = await session?.turnPhase
        let state: SupermuxClaudeSessionState
        if let process, let turn {
            state = SupermuxMobileClaudeObserver.mobileState(process: process, turn: turn)
        } else {
            state = record.redactedDiagnostic == nil ? .ended : .failed
        }
        let providerSessionID = await session?.claudeSessionID
        let initializedModel = await session?.systemInitialization?.model
        let liveQueue = await session?.queuedInputs
        let liveRevision = await session?.latestRevision
        return SupermuxClaudeSessionDTO(
            sessionID: record.stableSurfaceID.uuidString.lowercased(),
            claudeSessionID: providerSessionID ?? record.claudeSessionID,
            title: record.derivedTitle ?? URL(fileURLWithPath: record.workingDirectory).lastPathComponent,
            cwd: record.workingDirectory, projectID: record.projectID,
            launcher: supermuxClaudeWireLauncher(record.launcher),
            model: record.model ?? initializedModel,
            effort: record.effortLevel, fastMode: record.fastMode,
            thinkingBudget: record.maxThinkingTokens, state: state,
            cost: .init(
                totalUSD: result?.totalCostUSD ?? record.lastTotalCostUSD ?? 0,
                turns: result?.numTurns ?? 0,
                durationMS: Int64(result?.durationMs ?? 0)
            ),
            queuedCount: liveQueue?.filter { $0.state == .queued }.count
                ?? record.queueEntries.filter { $0.state == .queued }.count,
            lastActivityAt: record.lastActiveAt.timeIntervalSince1970,
            version: liveRevision ?? 0
        )
    }

    private func supermuxClaudeDecode<T: Decodable>(_ params: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func supermuxClaudeOK<T: Encodable>(_ value: T) -> V2CallResult {
        guard let payload = SupermuxMobileClaudeObserver.object(value) else {
            return .err(code: "unavailable", message: "Failed to encode Claude response", data: nil)
        }
        return .ok(payload)
    }

    private func supermuxClaudeSessionID(_ params: [String: Any]) -> UUID? {
        guard let request: SupermuxClaudeSessionReferenceDTO = supermuxClaudeDecode(params) else { return nil }
        return UUID(uuidString: request.sessionID)
    }

    private func supermuxClaudeInvalidSessionID() -> V2CallResult {
        .err(code: "invalid_params", message: "Missing or invalid session_id", data: nil)
    }

    private func supermuxClaudeResolveLauncher(_ launcher: SupermuxClaudeLauncher) throws -> ClaudeLauncher {
        let resolver = ClaudeLauncherResolver()
        switch launcher {
        case .claude: return try resolver.resolve(kind: .claude)
        case .ccx:
            do { return try resolver.resolve(kind: .ccx) }
            catch {
                let fallback = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/ccx").path
                return try resolver.resolve(kind: .ccx, explicitPath: fallback)
            }
        case .custom(let path): return try resolver.resolve(kind: .custom, explicitPath: path)
        }
    }

    private func supermuxClaudeWireLauncher(_ launcher: ClaudeLauncher) -> SupermuxClaudeLauncher {
        switch launcher.kind {
        case .claude: return .claude
        case .ccx: return .ccx
        case .custom: return .custom(path: launcher.executablePath)
        }
    }

    private func supermuxClaudeLauncherAvailability() -> [SupermuxClaudeLauncherAvailabilityDTO] {
        [SupermuxClaudeLauncher.claude, .ccx].map { launcher in
            do {
                _ = try supermuxClaudeResolveLauncher(launcher)
                return .init(launcher: launcher, available: true,
                             displayName: launcher == .claude ? "Claude Code" : "ccx")
            } catch {
                return .init(launcher: launcher, available: false,
                             displayName: launcher == .claude ? "Claude Code" : "ccx",
                             unavailableReason: "Launcher not found")
            }
        }
    }

    private func supermuxClaudeWaitForStartup(_ session: ClaudeSession) async -> Bool {
        if await session.systemInitialization != nil { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let changes = await session.changes()
                for await _ in changes {
                    if await session.systemInitialization != nil { return true }
                    switch await session.processPhase {
                    case .failed, .exited: return false
                    default: break
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func supermuxClaudeRequireSuccess(
        _ response: ClaudeControlResponseEnvelope
    ) throws {
        guard response.isSuccess else {
            throw SupermuxClaudeControlRejected(message: response.errorMessage ?? "Control rejected")
        }
    }

    /// Applies the runtime-only session controls (fast mode, thinking
    /// budget), which are not spawn flags and therefore must be sent after
    /// EVERY process start — initial create and resume alike.
    private func supermuxClaudeApplyRuntimeControls(
        session: ClaudeSession,
        fastMode: Bool,
        thinkingBudget: Int?
    ) async throws {
        if fastMode {
            try await supermuxClaudeRequireSuccess(session.sendControl(.setFastMode(true)))
        }
        if let thinkingBudget {
            try await supermuxClaudeRequireSuccess(session.sendControl(.setMaxThinkingTokens(thinkingBudget)))
        }
    }
}

private struct SupermuxClaudeControlRejected: Error {
    let message: String
}
