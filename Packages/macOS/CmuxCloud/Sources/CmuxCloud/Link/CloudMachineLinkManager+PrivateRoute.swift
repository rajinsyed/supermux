import Foundation
import Network

extension CloudMachineLinkManager {
    // SUPERMUX:begin runtime-cloud-route-startup-seam
    struct ResolvedPrivateRoute: Sendable {
        let route: String
        let deadline: ContinuousClock.Instant?
    }

    private func routeOperations() -> CloudMachineLinkManagerPrivateRouteOperations {
        let connector = privateRouteConnector
        let liveHub = hub
        return CloudMachineLinkManagerPrivateRouteOperations(
            now: { ContinuousClock.now },
            probe: { hub, target, timeout in
                var connector = connector
                if let timeout { connector.timeout = timeout }
                let connected = try await connector.connect(
                    endpoint: .unix(path: hub.socketPath), target: target,
                    queue: DispatchQueue.global(qos: .userInitiated)
                )
                connected.connection.cancel()
                return connected.host
            },
            readyRouting: { try await liveHub?.readyRouting(anyOf: $0) },
            refreshUnanswered: { try await liveHub?.refreshAfterUnansweredRoute() }
        )
    }

    /// The startup callback takes lease ownership; selection failures release it here.
    func startPrivateRoute<Value: Sendable>(
        machineID: String,
        through hub: CloudWireGuardHub.Ready,
        timeout: Duration,
        operations: CloudMachineLinkManagerPrivateRouteOperations? = nil,
        releaseLease: @Sendable () async -> Void,
        start: @Sendable (String, Duration) async throws -> Value
    ) async throws -> Value {
        let operations = operations ?? routeOperations()
        let deadline = await operations.now() + timeout
        let resolved: ResolvedPrivateRoute
        do {
            resolved = try await CloudOperationContext.phase(.route) {
                try await self.resolvePrivateRoute(
                    machineID: machineID, through: hub, deadline: deadline, operations: operations
                )
            }
            try Task.checkCancellation()
        } catch {
            await releaseLease()
            throw error
        }
        return try await start(resolved.route, max(deadline - (await operations.now()), .zero))
    }
    // SUPERMUX:end runtime-cloud-route-startup-seam

    /// The probe budget after a dead tunnel was re-enrolled and its hub restarted.
    static let unansweredRouteRetryBudget: Duration = .seconds(10)

    /// Selects a working family using the same SOCKS connector as port forwards.
    /// The probe sends no daemon request and closes its stream before the real
    /// encrypted link starts. Failed probes propagate to the caller's retry policy,
    /// so the next attempt considers every current family again.
    ///
    /// `timeout` is the caller's remaining connect budget. A link passes what is
    /// left of its own deadline, so address selection and the link share one
    /// budget. Selection used to stop at the connector's default 15 s while the
    /// link allowed 60 s: a machine restored from a cold snapshot opened its
    /// listener at ~13 s after create and New Machine failed in selection.
    public func resolvedPrivateRoute(
        machineID: String,
        through hub: CloudWireGuardHub.Ready,
        fallbackRoute: String? = nil,
        addresses freshAddresses: [String] = [],
        refreshIfNeeded: Bool = true,
        timeout: Duration? = nil
    ) async throws -> String {
        // SUPERMUX:begin runtime-cloud-route-resolution-seam
        let operations = routeOperations()
        let now = await operations.now()
        return try await resolvePrivateRoute(
            machineID: machineID, through: hub, fallbackRoute: fallbackRoute,
            addresses: freshAddresses, refreshIfNeeded: refreshIfNeeded,
            deadline: timeout.map { now + $0 }, operations: operations
        ).route
    }

    private func resolvePrivateRoute(
        machineID: String,
        through hub: CloudWireGuardHub.Ready,
        fallbackRoute: String? = nil,
        addresses freshAddresses: [String] = [],
        refreshIfNeeded: Bool = true,
        deadline: ContinuousClock.Instant?,
        operations: CloudMachineLinkManagerPrivateRouteOperations
    ) async throws -> ResolvedPrivateRoute {
        // SUPERMUX:end runtime-cloud-route-resolution-seam
        try Task.checkCancellation()
        let freshAddresses = freshAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let freshFamilies = Set(freshAddresses.map { $0.contains(":") })
        // Attach can omit one family. Preserve that family from discovery, but
        // never retain an old address in a family that attach has replaced.
        let storedAddresses = privateAddresses(for: machineID).filter {
            !freshFamilies.contains($0.contains(":"))
        }
        var seen = Set<String>()
        let candidates = (freshAddresses + storedAddresses).filter { seen.insert($0).inserted }
        let addresses = candidates.filter {
            CloudWireGuardHub.routesHost($0, enrolledRoutes: hub.routes)
        }
        // SUPERMUX:begin runtime-cloud-route-routing-budget
        if refreshIfNeeded, addresses.isEmpty, !candidates.isEmpty,
           let refreshed = try await operations.readyRouting(candidates) {
            // The hub refresh spends part of the caller's budget; pass on what is left.
            return try await resolvePrivateRoute(
                machineID: machineID,
                through: refreshed,
                fallbackRoute: fallbackRoute,
                addresses: freshAddresses,
                refreshIfNeeded: false,
                deadline: deadline,
                operations: operations
            )
        }
        // SUPERMUX:end runtime-cloud-route-routing-budget
        guard let primary = addresses.first else {
            guard candidates.isEmpty,
                  let route = fallbackRoute ?? privateRoute(for: machineID),
                  let host = IPNetworkPrefix.routeHost(route),
                  CloudWireGuardHub.routesHost(host, enrolledRoutes: hub.routes) else {
                throw ManagerError.privateRouteRequired(machineID)
            }
            // SUPERMUX:begin runtime-cloud-route-fallback-expiry
            return ResolvedPrivateRoute(route: route, deadline: deadline)
            // SUPERMUX:end runtime-cloud-route-fallback-expiry
        }
        // Fresh discovery or the enrolled routes can leave a single candidate.
        // Use it directly rather than returning an older address-family route.
        guard addresses.count > 1 else {
            let host = primary.contains(":") ? "[\(primary)]" : primary
            // SUPERMUX:begin runtime-cloud-route-single-expiry
            return ResolvedPrivateRoute(route: "ws://\(host):1337/v1/link", deadline: deadline)
            // SUPERMUX:end runtime-cloud-route-single-expiry
        }
        // SUPERMUX:begin runtime-cloud-route-probe-expiry
        let now = await operations.now()
        let host: String
        do {
            host = try await operations.probe(
                hub,
                CloudPortForwardTarget(host: primary, port: 1337, fallbackHosts: Array(addresses.dropFirst())),
                deadline.map { max($0 - now, .zero) }
            )
        // SUPERMUX:end runtime-cloud-route-probe-expiry
        } catch let error as CloudPortForwardRelay.RelayError where refreshIfNeeded {
            // No routed address answered at all: the hub refuses or resets a
            // host it cannot reach, so a silent hub means its tunnel's peer is
            // gone. Re-enroll once; a new config restarts the hub and the probe
            // runs again, and a revoked sign-in surfaces as that answer.
            // SUPERMUX:begin runtime-cloud-route-recovery-expiry
            guard case .handshakeTimedOut = error,
                  let refreshed = try await operations.refreshUnanswered() else { throw error }
            // The silent probe ran out the caller's budget, so the retry on the
            // new peer gets its own short one; a live hub answers in milliseconds.
            return try await resolvePrivateRoute(
                machineID: machineID, through: refreshed, fallbackRoute: fallbackRoute, addresses: freshAddresses,
                refreshIfNeeded: false,
                deadline: await operations.now() + Self.unansweredRouteRetryBudget,
                operations: operations
            )
            // SUPERMUX:end runtime-cloud-route-recovery-expiry
        }
        // SUPERMUX:begin runtime-cloud-route-selected-expiry
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return ResolvedPrivateRoute(route: "ws://\(formattedHost):1337/v1/link", deadline: deadline)
        // SUPERMUX:end runtime-cloud-route-selected-expiry
    }
}
