public import Foundation

/// A persisted account-specific Claude model catalog for one resolved executable path.
public struct SupermuxHarnessModelCatalogSnapshot: Equatable, Sendable {
    /// Model objects returned by Claude Code's initialize control response.
    public let models: [SupermuxHarnessJSONObject]
    /// When the catalog was persisted.
    public let storedAt: Date

    /// Creates a persisted model catalog snapshot.
    ///
    /// - Parameters:
    ///   - models: Model objects from an initialize response.
    ///   - storedAt: When the catalog was persisted.
    public init(models: [SupermuxHarnessJSONObject], storedAt: Date) {
        self.models = models
        self.storedAt = storedAt
    }
}
