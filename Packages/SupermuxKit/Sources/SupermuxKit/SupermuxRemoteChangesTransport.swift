/// What the Mac that owns a mirrored workspace reported about its repository.
public enum SupermuxRemoteChangesEvent: Sendable, Equatable {
    /// The host's watcher saw the repository change (`supermux.changes.updated`).
    case changed
    /// The link to that Mac came back; everything cached may be stale and the
    /// host forgot this Mac's watch lease.
    case reconnected
}

/// The link a ``SupermuxRemoteChangesBackend`` talks through: RPCs to the Mac
/// that owns one remote workspace, and that workspace's change events.
///
/// The app target implements it over its device facade; tests use a fake.
@MainActor
public protocol SupermuxRemoteChangesTransport: AnyObject, Sendable {
    /// The owning Mac's id for the workspace. Every call is keyed by this id,
    /// never by the local mirror's id.
    var remoteWorkspaceID: String { get }

    /// One `mobile.supermux.*` call; returns the host's result object. The
    /// reply deadline is the method's own (``SupermuxDeviceReplyDeadline``).
    /// - Parameters:
    ///   - method: The wire method.
    ///   - params: The params object (the backend adds `workspace_id`).
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]

    /// The host's error code for a failed ``request(_:params:)``
    /// (e.g. `ai_unavailable`, `stale_root`), when it sent one.
    func errorCode(_ error: any Error) -> String?

    /// Change and reconnect events for this workspace; one stream per call.
    func events() -> AsyncStream<SupermuxRemoteChangesEvent>
}
