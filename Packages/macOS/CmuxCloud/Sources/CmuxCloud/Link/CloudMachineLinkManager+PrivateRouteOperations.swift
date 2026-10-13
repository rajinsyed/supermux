// SUPERMUX:begin runtime-cloud-route-operations
import Foundation

/// Per-call dependencies for private route selection and its startup deadline.
struct CloudMachineLinkManagerPrivateRouteOperations: Sendable {
    var now: @Sendable () async -> ContinuousClock.Instant
    var probe: @Sendable (CloudWireGuardHub.Ready, CloudPortForwardTarget, Duration?) async throws -> String
    var readyRouting: @Sendable ([String]) async throws -> CloudWireGuardHub.Ready?
    var refreshUnanswered: @Sendable () async throws -> CloudWireGuardHub.Ready?
}
// SUPERMUX:end runtime-cloud-route-operations
