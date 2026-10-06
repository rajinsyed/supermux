// SUPERMUX:begin render-grid-watch (which terminals each phone connection is sent render frames for — see SUPERMUX-TOUCHPOINTS.md)
public import Foundation

/// Which terminals each phone connection shows, from what the Mac already
/// hears: its dedicated viewport reports and the replays it asks for.
///
/// The host captured every terminal and sent every frame to every phone
/// (STREAM.md H4). A phone mounts a terminal with a replay, then a dedicated
/// `mobile.terminal.viewport` report (sticky for the connection's life), and
/// clears that report when it unmounts the terminal or its app goes inactive
/// (a terminal under another tab keeps its report). So:
/// - A connection is limited once it has written a dedicated report; one
///   that never has (an older phone, a Mac) keeps every terminal.
/// - Its set is the terminals it holds a dedicated report for, plus those it
///   asked a replay of since, until their report goes (a mount's replay
///   comes before its report; an unmount clears the report).
/// - Each change names the terminals that joined a limited connection's set:
///   the caller asks the producer for a full frame of each, since the
///   connection skipped frames their next delta would build on.
public struct SupermuxRenderGridWatchState: Sendable {
    /// A sticky viewport report: `connectionID` wrote one for `surfaceID`.
    public struct Report: Hashable, Sendable {
        public let surfaceID: UUID
        public let connectionID: UUID

        public init(surfaceID: UUID, connectionID: UUID) {
            self.surfaceID = surfaceID
            self.connectionID = connectionID
        }
    }

    /// A connection's new set, and the terminals that joined it.
    public struct Change: Hashable, Sendable {
        public let connectionID: UUID
        public let surfaceIDs: Set<UUID>
        public let joined: Set<UUID>

        public init(connectionID: UUID, surfaceIDs: Set<UUID>, joined: Set<UUID>) {
            self.connectionID = connectionID
            self.surfaceIDs = surfaceIDs
            self.joined = joined
        }
    }

    /// Terminals each connection holds a dedicated report for. A connection
    /// stays here (limited) once it wrote one, with an empty set after clears.
    private var reported: [UUID: Set<UUID>] = [:]
    /// Terminals each connection asked a replay of, until their report goes.
    private var replayed: [UUID: Set<UUID>] = [:]
    /// The set each limited connection was last given.
    private var given: [UUID: Set<UUID>] = [:]
    /// Every sticky report last heard of, render-grid connection or not.
    private var heard: Set<Report> = []

    public init() {}

    /// Every sticky report now held; only those of connections that
    /// `takesRenderGrid` (subscribed to `terminal.render_grid`) count. Runs
    /// on every report write, so an unchanged set stops at the comparison.
    public mutating func reportsHeard(
        _ reports: Set<Report>, takesRenderGrid: (UUID) -> Bool, isOpen: (UUID) -> Bool
    ) -> [Change] {
        guard reports != heard else { return [] }
        heard = reports
        return subscriptionsChanged(takesRenderGrid: takesRenderGrid, isOpen: isOpen)
    }

    /// A connection subscribed to or left `terminal.render_grid`: the reports
    /// it wrote before count, or stop counting, now.
    public mutating func subscriptionsChanged(takesRenderGrid: (UUID) -> Bool, isOpen: (UUID) -> Bool) -> [Change] {
        reportsChanged(heard.filter { takesRenderGrid($0.connectionID) }, isOpen: isOpen)
    }

    /// The dedicated reports now held (every connection's).
    public mutating func reportsChanged(_ reports: Set<Report>, isOpen: (UUID) -> Bool) -> [Change] {
        var current: [UUID: Set<UUID>] = [:]
        for report in reports { current[report.connectionID, default: []].insert(report.surfaceID) }
        for (connectionID, surfaceIDs) in reported {
            let gone = surfaceIDs.subtracting(current[connectionID] ?? [])
            replayed[connectionID]?.subtract(gone)
            // Once limited, a connection stays limited (an inactive phone
            // clears every report and must get nothing, not everything).
            if current[connectionID] == nil { current[connectionID] = [] }
        }
        reported = current
        return changes(isOpen: isOpen)
    }

    /// A replay of `surfaceID` was served on `connectionID`.
    public mutating func replayServed(surfaceID: UUID, connectionID: UUID, isOpen: (UUID) -> Bool) -> [Change] {
        replayed[connectionID, default: []].insert(surfaceID)
        return changes(isOpen: isOpen)
    }

    private mutating func changes(isOpen: (UUID) -> Bool) -> [Change] {
        for connectionID in Set(reported.keys).union(replayed.keys) where !isOpen(connectionID) {
            reported[connectionID] = nil
            replayed[connectionID] = nil
            given[connectionID] = nil
        }
        var changes: [Change] = []
        for (connectionID, surfaceIDs) in reported {
            let shown = surfaceIDs.union(replayed[connectionID] ?? [])
            let previous = given[connectionID]
            guard shown != previous else { continue }
            given[connectionID] = shown
            // A connection limited just now got every frame until now.
            let joined = previous.map { shown.subtracting($0) } ?? []
            changes.append(Change(connectionID: connectionID, surfaceIDs: shown, joined: joined))
        }
        return changes
    }
}
// SUPERMUX:end render-grid-watch
