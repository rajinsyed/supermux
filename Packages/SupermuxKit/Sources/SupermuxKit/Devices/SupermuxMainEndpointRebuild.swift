public import Foundation

/// Red stub (review T1): not implemented yet.
public enum SupermuxMainEndpointRebuild {
    public enum Outcome: String, Equatable, Sendable {
        case rebuilt
        case rebuiltAfterRefresh = "rebuilt-after-refresh"
        case noEndpoint = "no-endpoint"
        case keptExpiredCredentials = "kept-expired-credentials"
    }

    public struct Steps: Sendable {
        public var hasEndpoint: @Sendable () async -> Bool
        public var credentialsUsable: @Sendable () async -> Bool
        public var refreshCredentials: @Sendable () async throws -> Void
        public var rebuild: @Sendable () async -> Void

        public init(
            hasEndpoint: @escaping @Sendable () async -> Bool,
            credentialsUsable: @escaping @Sendable () async -> Bool,
            refreshCredentials: @escaping @Sendable () async throws -> Void,
            rebuild: @escaping @Sendable () async -> Void
        ) {
            self.hasEndpoint = hasEndpoint
            self.credentialsUsable = credentialsUsable
            self.refreshCredentials = refreshCredentials
            self.rebuild = rebuild
        }
    }

    public static func run(_ steps: Steps, limit: Duration, retryDelay: Duration = .milliseconds(500)) async -> Outcome {
        guard await steps.hasEndpoint() else { return .noEndpoint }
        guard await steps.credentialsUsable() else { return .keptExpiredCredentials }
        await steps.rebuild()
        return .rebuilt
    }
}
