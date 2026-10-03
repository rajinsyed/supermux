import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Which of another Mac's ports this Mac forwards: one pure decision, made
/// again on every change (``SupermuxPortForwards`` executes it).
///
/// - Automatic: with the setting on, every listed port ≥ 1024 of a workspace
///   mirrored here.
/// - On demand: a same-port forward a mirror browser started for a page
///   (``SupermuxPortForwards/forwardOnDemand(machine:remotePort:)``), also of a
///   port in no workspace there (its other loopback ports) and with the setting
///   off. It goes when the port leaves that Mac's listing.
/// - Manual: kept until the user stops it, whatever the listing says.
/// - Stopped (dismissed): a port the user stopped stays stopped until Resume or
///   Forward to This Mac, also while its server restarts (it leaves the listing
///   and comes back): it is forgotten only once that Mac no longer lists it and
///   none of the workspaces that listed it when it was stopped is mirrored here
///   any more. A stop of a port no workspace listed (an other port, a manual
///   forward) lasts until the user forwards it again.
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
        /// Its other loopback ports, in none of its workspaces (`other_ports`).
        var otherPorts: Set<Int> = []

        /// Whether the Mac serves `port`: a workspace's, or another loopback one.
        func lists(_ port: Int) -> Bool {
            workspaces[port] != nil || otherPorts.contains(port)
        }
    }

    struct Input {
        var autoForward: Bool
        /// Listings of the Macs whose ports are known (an unavailable but
        /// connected Mac lists nothing).
        var listings: [SurfaceMachineID: Listing]
        /// Remote workspaces with a mirror on this Mac.
        var mirrored: Set<SupermuxRemoteWorkspaceRef>
        var manual: Set<Key>
        /// Same-port forwards mirror browsers asked for.
        var onDemand: Set<Key> = []
        var dismissed: Set<Key>
        /// The workspaces (canonical ids) that listed each dismissed port when the
        /// user stopped it.
        var stoppedWorkspaces: [Key: Set<String>] = [:]
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
        /// The dismissed set, minus stops that are over (see the type's doc).
        var dismissed: Set<Key> = []
        /// The on-demand set, minus ports that left their Mac's listing.
        var onDemand: Set<Key> = []
        /// The forwards automatic forwarding wants.
        var automatic: Set<Key> = []

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
        // A Mac with no listing (offline, not fetched yet) keeps them as they are.
        func stillListed(_ key: Key) -> Bool {
            input.listings[key.machine]?.lists(key.remotePort) ?? true
        }
        func stopHolds(_ key: Key) -> Bool {
            if stillListed(key) { return true }
            let workspaces = input.stoppedWorkspaces[key] ?? []
            return workspaces.isEmpty || workspaces.contains {
                input.mirrored.contains(SupermuxRemoteWorkspaceRef(machine: key.machine, workspaceID: $0))
            }
        }
        let dismissed = input.dismissed.filter(stopHolds)
        let onDemand = input.onDemand.filter(stillListed)
        let wanted = automatic.union(onDemand)
        var decision = Decision(dismissed: dismissed, onDemand: onDemand, automatic: automatic)
        decision.run = wanted.subtracting(dismissed).union(input.manual)
        decision.paused = wanted.intersection(dismissed).subtracting(input.manual)
        decision.held = input.existing.filter { input.listings[$0.machine] == nil && !dismissed.contains($0) }
        return decision
    }
}
