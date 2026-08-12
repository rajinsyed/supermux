public import Foundation
import SupermuxClaudeHarness

/// One registry change event.
public enum ClaudeRegistryChange: Sendable {
    case added(UUID)
    case removed(UUID)
}

/// A session with this ID already exists; creating a duplicate would leak
/// the original Claude process.
public struct ClaudeDuplicateSessionError: Error, Sendable, Equatable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Owns the live ``ClaudeSession`` actors, keyed by local session UUID.
///
/// The registry (not any view) owns session lifetime: a session must survive
/// its panel being hidden, and is torn down only through ``remove(id:)`` or
/// app termination.
@MainActor
public final class ClaudeSessionRegistry {
    private var sessions: [UUID: ClaudeSession] = [:]
    private var revision: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<ClaudeRegistryChange>.Continuation] = [:]
    private let runner: any ClaudeProcessRunning

    public init(runner: any ClaudeProcessRunning = ClaudeProcessRunner()) {
        self.runner = runner
    }

    /// Creates and starts a session for a fresh or resumed configuration.
    ///
    /// Throws ``ClaudeDuplicateSessionError`` when a session with the same ID
    /// is already live — silently overwriting it would leak its process.
    @discardableResult
    public func create(
        configuration: ClaudeSessionConfiguration,
        persistence: (any ClaudeSessionPersisting)? = nil
    ) async throws -> ClaudeSession {
        guard sessions[configuration.id] == nil else {
            throw ClaudeDuplicateSessionError(id: configuration.id)
        }
        let session = ClaudeSession(
            configuration: configuration, runner: runner, persistence: persistence
        )
        sessions[configuration.id] = session
        emit(.added(configuration.id))
        do {
            try await session.start()
        } catch {
            sessions.removeValue(forKey: configuration.id)
            emit(.removed(configuration.id))
            throw error
        }
        return session
    }

    /// The live session for an ID, if any.
    public func session(id: UUID) -> ClaudeSession? {
        sessions[id]
    }

    /// All live session IDs.
    public var sessionIDs: [UUID] {
        Array(sessions.keys)
    }

    /// Monotonic revision incremented when registry membership changes.
    public var latestRevision: UInt64 { revision }

    /// Terminates and removes one session.
    public func remove(id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.terminate()
        await session.finishSubscribers()
        emit(.removed(id))
    }

    /// Terminates every session (app shutdown).
    public func removeAll() async {
        for id in Array(sessions.keys) {
            await remove(id: id)
        }
    }

    /// Synchronous best-effort teardown for `applicationWillTerminate`, where
    /// awaiting the full grace-period escalation would outlive the app. Each
    /// live child gets stdin EOF + SIGTERM immediately (no actor hop — a
    /// spawned task might never run before the app exits).
    public func terminateAllForAppShutdown() {
        for session in sessions.values {
            session.terminateForAppShutdown()
        }
    }

    /// A stream of registry membership changes.
    public func changes() -> AsyncStream<ClaudeRegistryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ClaudeRegistryChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor in
                self.subscribers.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func emit(_ change: ClaudeRegistryChange) {
        revision &+= 1
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }
}
