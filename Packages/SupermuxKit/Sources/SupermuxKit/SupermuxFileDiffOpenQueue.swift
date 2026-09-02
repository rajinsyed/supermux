public import Foundation

/// Per-workspace bookkeeping for a host's file diff viewer.
///
/// A host opens the viewer through a CLI whose surface id only arrives when
/// the process exits, so at most one open runs per workspace at a time. A
/// click that lands while one is in flight is not dropped and does not open
/// a second tab: it is queued, and only the last-queued patch launches when
/// the flight ends (latest wins). The queue also remembers the viewer surface
/// the host last opened and the pane it was split from, so a replacement
/// lands in the same spot.
///
/// Pure value type; the host owns the process and the workspace model.
public struct SupermuxFileDiffOpenQueue: Sendable, Equatable {
    /// One workspace's state.
    public struct WorkspaceState: Sendable, Equatable {
        /// The viewer surface last opened here, if still tracked.
        public var openedSurface: UUID?
        /// The pane the viewer was last split from.
        public var sourceSurface: UUID?
        /// Whether a CLI open is running.
        public var isInFlight = false
        /// The patch clicked most recently during the current flight.
        public var pending: SupermuxFileDiffPatch?

        /// Creates an idle state.
        public init(openedSurface: UUID? = nil, sourceSurface: UUID? = nil) {
            self.openedSurface = openedSurface
            self.sourceSurface = sourceSurface
        }
    }

    private var states: [UUID: WorkspaceState] = [:]

    /// Creates an empty queue.
    public init() {}

    /// The state for `workspace` (idle when never seen).
    public func state(for workspace: UUID) -> WorkspaceState {
        states[workspace] ?? WorkspaceState()
    }

    /// Registers a click. Returns `true` when the caller must launch `patch`
    /// now (the workspace is marked in flight); `false` when an open is
    /// already running — `patch` is then queued, replacing any earlier
    /// queued patch, and launches from ``finishOpen(in:openedSurface:)`` or
    /// ``abandonOpen(in:)``.
    public mutating func requestOpen(_ patch: SupermuxFileDiffPatch, in workspace: UUID) -> Bool {
        var state = state(for: workspace)
        defer { states[workspace] = state }
        if state.isInFlight {
            state.pending = patch
            return false
        }
        state.isInFlight = true
        return true
    }

    /// Records the viewer being replaced (`nil` once the user closed it) and
    /// the pane the launch splits from.
    public mutating func recordLaunch(previousSurface: UUID?, sourceSurface: UUID?, in workspace: UUID) {
        var state = state(for: workspace)
        state.openedSurface = previousSurface
        state.sourceSurface = sourceSurface
        states[workspace] = state
    }

    /// Ends a successful flight: `openedSurface` is the viewer it produced
    /// (`nil` when the CLI reported none, which stops tracking). Returns the
    /// queued patch to launch next, already marked in flight, or `nil`.
    public mutating func finishOpen(in workspace: UUID, openedSurface: UUID?) -> SupermuxFileDiffPatch? {
        var state = state(for: workspace)
        state.openedSurface = openedSurface
        return endFlight(&state, in: workspace)
    }

    /// Ends a failed flight, keeping the previously tracked viewer. Returns
    /// the queued patch to launch next, already marked in flight, or `nil`.
    public mutating func abandonOpen(in workspace: UUID) -> SupermuxFileDiffPatch? {
        var state = state(for: workspace)
        return endFlight(&state, in: workspace)
    }

    private mutating func endFlight(_ state: inout WorkspaceState, in workspace: UUID) -> SupermuxFileDiffPatch? {
        let next = state.pending
        state.pending = nil
        state.isInFlight = next != nil
        states[workspace] = state
        return next
    }
}
