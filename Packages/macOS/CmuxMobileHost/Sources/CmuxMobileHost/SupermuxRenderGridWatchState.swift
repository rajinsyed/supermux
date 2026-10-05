// SUPERMUX:begin render-grid-watch (which terminals each phone connection is sent render frames for — see SUPERMUX-TOUCHPOINTS.md)
public import Foundation

/// Which terminals each phone connection shows, from what the Mac already
/// hears: its dedicated viewport reports and the replays it asks for.
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

    public init() {}

    public mutating func reportsChanged(_ reports: Set<Report>, isOpen: (UUID) -> Bool) -> [Change] {
        []
    }

    public mutating func replayServed(surfaceID: UUID, connectionID: UUID, isOpen: (UUID) -> Bool) -> [Change] {
        []
    }
}
// SUPERMUX:end render-grid-watch
