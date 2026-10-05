import CmuxMobileHost
import Foundation

/// Sends a phone connection `terminal.render_grid` only for the terminals it
/// shows (STREAM.md H4; touchpoints #1045–#1048).
///
/// The host captured every terminal and sent every frame to every phone, so
/// on a slow relay hidden terminals' frames filled the phone's one event
/// buffer and shed the focused terminal's. The Mac already hears which
/// terminals each connection shows, with no new wire key (an installed phone
/// is fixed by a Mac update alone): a phone mounts a terminal with a replay,
/// then a dedicated, sticky `mobile.terminal.viewport` report, and clears
/// that report when it unmounts the terminal or its app goes inactive.
/// ``SupermuxRenderGridWatchState`` turns those into each connection's set,
/// and each connection's event queue refuses the other terminals' frames.
/// A terminal that joins a set gets a full frame (its next delta would
/// build on frames the phone skipped).
@MainActor
enum SupermuxMobileRenderGridWatch {
    private static var state = SupermuxRenderGridWatchState()

    /// The viewport reports changed (any write, clear or expiry). Only the
    /// sticky reports a phone connection wrote count.
    static func reportsChanged(_ reportsBySurfaceID: [UUID: [String: TerminalController.MobileViewportReport]]) {
        var reports = Set<SupermuxRenderGridWatchState.Report>()
        for (surfaceID, reportsByClient) in reportsBySurfaceID {
            for report in reportsByClient.values where report.sticky {
                guard let connectionID = report.connectionID else { continue }
                reports.insert(.init(surfaceID: surfaceID, connectionID: connectionID))
            }
        }
        apply(state.reportsChanged(reports, isOpen: isOpen))
    }

    /// A replay of `surfaceID` is served on the running request's phone
    /// connection, before its capture: the frames after it must reach it.
    static func replayServed(surfaceID: UUID) {
        guard let connectionID = SupermuxMobileConnectionContext.controlConnectionID else { return }
        apply(state.replayServed(surfaceID: surfaceID, connectionID: connectionID, isOpen: isOpen))
    }

    private static func isOpen(_ connectionID: UUID) -> Bool {
        MobileHostConnectionRegistry.shared.connection(id: connectionID) != nil
    }

    private static func apply(_ changes: [SupermuxRenderGridWatchState.Change]) {
        guard !changes.isEmpty else { return }
        var joined = Set<String>()
        for change in changes {
            MobileHostConnectionRegistry.shared.connection(id: change.connectionID)?.eventQueue
                .supermuxShowRenderGrid(surfaceIDs: Set(change.surfaceIDs.map(\.uuidString)))
            joined.formUnion(change.joined.map(\.uuidString))
        }
        MobileTerminalRenderObserver.requestRenderGridFullResync(surfaceIDStrings: joined)
    }
}
