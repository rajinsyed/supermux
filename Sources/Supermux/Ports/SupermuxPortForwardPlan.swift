import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Which of another Mac's ports this Mac forwards: one pure decision, made
/// again on every change (``SupermuxPortForwards`` executes it).
///
/// - Automatic: with the setting on, every listed port ≥ 1024 of a workspace
///   mirrored here. A port the user stopped stays stopped (dismissed) until it
///   leaves that Mac's listing.
/// - Manual: kept until the user stops it, whatever the listing says.
/// - A Mac with no listing (offline, or not fetched yet) keeps its forwards as
///   they are, so they come back once it does; one the user stops meanwhile
///   goes at once (still dismissed, it comes back stopped if listed).
enum SupermuxPortForwardPlan {
    struct Key: Hashable, Sendable, CustomStringConvertible {
        let machine: SurfaceMachineID
        let remotePort: Int

        var description: String { "\(machine.rawValue):\(remotePort)" }
    }

    /// One Mac's port listing, reduced to what the plan needs.
    struct Listing {
        /// Each listed port's workspaces (canonical remote workspace ids).
        var workspaces: [Int: Set<String>]
    }

    struct Input {
        var autoForward: Bool
        /// Listings of the Macs whose ports are known (an unavailable but
        /// connected Mac lists nothing).
        var listings: [SurfaceMachineID: Listing]
        /// Remote workspaces with a mirror on this Mac.
        var mirrored: Set<SupermuxRemoteWorkspaceRef>
        var manual: Set<Key>
        var dismissed: Set<Key>
        /// The forwards that exist now.
        var existing: Set<Key>
    }

    struct Decision: Equatable {
        /// Forwards that should listen (when their Mac is available).
        var run: Set<Key> = []
        /// Automatic forwards the user stopped: kept, not listening.
        var paused: Set<Key> = []
        /// Existing forwards of Macs without a listing that the user did not
        /// stop: kept as they are.
        var held: Set<Key> = []
        /// The dismissed set, minus ports that left their Mac's listing.
        var dismissed: Set<Key> = []

        /// Every forward that should exist.
        var kept: Set<Key> { run.union(paused).union(held) }
    }

    /// Ports below this are never forwarded automatically (system services).
    static let lowestAutomaticPort = 1024

    static func decide(_ input: Input) -> Decision {
        var automatic: Set<Key> = []
        if input.autoForward {
            for (machine, listing) in input.listings {
                for (port, workspaces) in listing.workspaces where port >= lowestAutomaticPort {
                    let shown = workspaces.contains {
                        input.mirrored.contains(SupermuxRemoteWorkspaceRef(machine: machine, workspaceID: $0))
                    }
                    if shown { automatic.insert(Key(machine: machine, remotePort: port)) }
                }
            }
        }
        let dismissed = input.dismissed.filter { key in
            guard let listing = input.listings[key.machine] else { return true }
            return listing.workspaces[key.remotePort] != nil
        }
        var decision = Decision(dismissed: dismissed)
        decision.run = automatic.subtracting(dismissed).union(input.manual)
        decision.paused = automatic.intersection(dismissed).subtracting(input.manual)
        decision.held = input.existing.filter { input.listings[$0.machine] == nil && !dismissed.contains($0) }
        return decision
    }
}
