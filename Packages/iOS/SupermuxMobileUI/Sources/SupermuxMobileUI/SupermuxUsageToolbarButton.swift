public import CmuxMobileRPC
import SupermuxMobileKit
public import SwiftUI

/// The workspace list's usage-gauge toolbar button — the phone's twin of the
/// Mac sidebar footer button (touchpoint #146).
///
/// The ring fills to the tightest Claude/Codex limit and tapping it presents
/// ``SupermuxUsageScreen``. Renders nothing unless the host advertises
/// `supermux.usage.v1`, so a fork phone paired with an upstream cmux Mac
/// shows exactly upstream's toolbar.
///
/// The button keeps its own lightweight store so the gauge can fill while the
/// sheet is closed; the sheet builds its own session for its poll loop.
public struct SupermuxUsageToolbarButton: View {
    private let connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?

    /// The gauge's own store, rebuilt per connection identity.
    @State private var store: SupermuxMobileUsageStore?
    @State private var isPresented = false

    /// Creates the toolbar button.
    /// - Parameter connection: The live RPC client + host-capability
    ///   snapshot, or `nil` while disconnected (the button hides).
    public init(connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?) {
        self.connection = connection
    }

    public var body: some View {
        if SupermuxUsageEntry.showsButton(hostCapabilities: connection?.hostCapabilities) {
            Button {
                isPresented = true
            } label: {
                SupermuxUsageGauge(window: store?.tightestWindow)
            }
            .accessibilityLabel(String(
                localized: "supermux.usage.title",
                defaultValue: "Usage Limits",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxUsageToolbarButton")
            // The sheet renders THIS store rather than building its own: one
            // session means the gauge and the sheet can never show different
            // numbers, and presenting the sheet adds no second poll loop.
            .sheet(isPresented: $isPresented) {
                SupermuxUsageScreen(store: store)
            }
            // Drives the ring, and keeps driving it while the sheet is up
            // (the toolbar button stays mounted behind the presentation).
            // Keyed on the connection so a reconnect — or capabilities
            // arriving after the host-status round trip — rebuilds the store
            // instead of polling a dead client.
            .task(id: SupermuxUsageConnectionKey(connection: connection)) {
                let store = makeStore()
                self.store = store
                guard let store else { return }
                await store.run()
            }
        }
    }

    /// Builds a usage session against the CURRENT connection, or `nil` while
    /// disconnected (the sheet shows its not-connected placeholder).
    @MainActor
    private func makeStore() -> SupermuxMobileUsageStore? {
        guard let connection else { return nil }
        return SupermuxMobileUsageStore(
            client: SupermuxMacClient(client: connection.rpcClient),
            capabilities: SupermuxMobileCapabilities(hostCapabilities: connection.hostCapabilities)
        )
    }
}

/// Pure visibility logic for the usage entry point, kept off the view so the
/// capability gate is package-unit-testable (UI-02 for this mount).
/// lint:allow namespace-enum — stateless capability-gate predicate kept off the view so the mount's visibility rule is package-unit-testable.
public enum SupermuxUsageEntry {
    /// Whether the toolbar gauge shows: a live connection whose host
    /// advertises `supermux.usage.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    public static func showsButton(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsUsage
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
