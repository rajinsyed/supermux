public import CmuxMobileRPC
import Observation
public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// Owns the phone's usage session on behalf of the toolbar gauge.
///
/// **Why the button does not own this.** The gauge renders inside the
/// workspace list's `showsNavigationToolbar` branch, which goes false on every
/// navigation push — so a store held in the button's own `@State` is destroyed
/// when you open a workspace and rebuilt when you come back, losing the
/// last-good snapshot and restarting the poll from scratch after routine
/// navigation. This model is held by the list itself (a stable view) and
/// driven by ``SwiftUICore/View/supermuxUsageDriver(model:connection:)``,
/// exactly like ``SupermuxProjectsSectionModel`` and its section driver.
///
/// One session runs per `(connection identity, capability snapshot)` pair, so
/// a reconnect — or capabilities arriving after the `mobile.host.status`
/// round trip — replaces the store instead of polling a dead client.
@MainActor
@Observable
public final class SupermuxUsageSectionModel {
    /// The live usage session, or `nil` while disconnected.
    public private(set) var store: SupermuxMobileUsageStore?

    /// Whether the toolbar gauge renders: a live session whose host
    /// advertises `supermux.usage.v1`.
    public var showsButton: Bool { store?.showsUsage == true }

    /// The tightest window across both providers, driving the ring's fill.
    public var tightestWindow: SupermuxUsageWindowDTO? { store?.tightestWindow }

    /// Creates an idle model. The driver installs a session.
    public init() {}

    /// Runs one connection's usage session until cancelled.
    ///
    /// Cancellation (a navigation push covering the list) stops the poll loop
    /// but KEEPS the store installed, so the gauge keeps showing its last
    /// snapshot and a pop resumes polling against the same session rather
    /// than flashing an empty ring.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam for this connection.
    ///   - hostCapabilities: The host's raw advertised capability strings.
    ///   - connectionID: The driver's task identity for this connection.
    public func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable?
    ) async {
        if connectionID != sessionConnectionID || store == nil {
            store = SupermuxMobileUsageStore(
                client: client,
                capabilities: SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
            )
            sessionConnectionID = connectionID
        }
        await store?.run()
    }

    /// Drops the session (the connection went away), so the gauge hides
    /// rather than showing numbers from a Mac that is no longer paired.
    public func endSession() {
        store = nil
        sessionConnectionID = nil
    }

    @ObservationIgnored private var sessionConnectionID: AnyHashable?
}

extension View {
    /// Drives a ``SupermuxUsageSectionModel`` from the shell's connection
    /// seam. Attach to a STABLE view (the list itself), never inside the
    /// toolbar branch or a lazy row — the session's structured `.task` must
    /// outlive a navigation push.
    ///
    /// - Parameters:
    ///   - model: The usage model the fence's `@State` owns.
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (the gauge hides).
    @MainActor
    public func supermuxUsageDriver(
        model: SupermuxUsageSectionModel,
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    ) -> some View {
        let connectionKey = SupermuxUsageConnectionKey(connection: connection)
        return task(id: connectionKey) {
            guard let connection else {
                model.endSession()
                return
            }
            await model.runSession(
                client: SupermuxMacClient(client: connection.rpcClient),
                hostCapabilities: connection.hostCapabilities,
                connectionID: connectionKey
            )
        }
    }
}

/// Hashable identity for one usage session: the RPC client's object identity
/// plus the capability snapshot it arrived with, mirroring
/// ``SupermuxProjectsConnectionKey``.
struct SupermuxUsageConnectionKey: Hashable {
    let clientID: ObjectIdentifier?
    let hostCapabilities: Set<String>?

    init(connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?) {
        self.clientID = connection.map { ObjectIdentifier($0.rpcClient) }
        self.hostCapabilities = connection?.hostCapabilities
    }
}
