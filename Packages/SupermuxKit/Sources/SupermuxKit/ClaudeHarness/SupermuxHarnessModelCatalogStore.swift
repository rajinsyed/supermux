internal import CryptoKit
public import Foundation

/// Persists Claude model catalogs independently for each resolved executable path.
///
/// Isolation: this stateless value holds an immutable `UserDefaults` reference, whose API is
/// documented thread-safe. Callers may therefore use the store from controller and probe tasks.
public struct SupermuxHarnessModelCatalogStore: Sendable {
    private static let keyPrefix = "supermux.harness.modelCatalog."

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a model catalog store for the supplied defaults suite.
    ///
    /// - Parameter defaults: The defaults suite in which model catalogs should be persisted.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Loads the cached model catalog for a resolved Claude executable.
    ///
    /// Corrupt or incomplete entries are treated as cache misses so callers can probe again.
    ///
    /// - Parameter binaryPath: The resolved executable path that owns the catalog.
    /// - Returns: The cached snapshot, or `nil` when none can be decoded.
    public func snapshot(forBinaryPath binaryPath: String) -> SupermuxHarnessModelCatalogSnapshot? {
        let modelsKey = modelsKey(forBinaryPath: binaryPath)
        guard let data = defaults.data(forKey: modelsKey),
              let storedAt = defaults.object(forKey: storedAtKey(forBinaryPath: binaryPath)) as? NSNumber,
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let models = values.compactMap { try? SupermuxHarnessJSONObject(rawValue: $0) }
        guard models.count == values.count else { return nil }
        return SupermuxHarnessModelCatalogSnapshot(
            models: models,
            storedAt: Date(timeIntervalSince1970: storedAt.doubleValue)
        )
    }

    /// Persists model objects under the resolved executable's path-derived cache key.
    ///
    /// - Parameters:
    ///   - models: Model objects from an initialize response.
    ///   - binaryPath: The resolved executable path that owns the catalog.
    ///   - storedAt: The timestamp to persist for diagnostics and freshness policy.
    /// - Throws: A Foundation JSON serialization error.
    public func store(
        _ models: [SupermuxHarnessJSONObject],
        forBinaryPath binaryPath: String,
        storedAt: Date = Date()
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: models.map(\.rawValue),
            options: [.sortedKeys]
        )
        defaults.set(data, forKey: modelsKey(forBinaryPath: binaryPath))
        defaults.set(storedAt.timeIntervalSince1970, forKey: storedAtKey(forBinaryPath: binaryPath))
    }

    /// Removes every Claude harness model catalog while preserving unrelated defaults.
    public func invalidateAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func modelsKey(forBinaryPath binaryPath: String) -> String {
        Self.keyPrefix + pathDigest(binaryPath) + ".models"
    }

    private func storedAtKey(forBinaryPath binaryPath: String) -> String {
        Self.keyPrefix + pathDigest(binaryPath) + ".storedAt"
    }

    private func pathDigest(_ binaryPath: String) -> String {
        let standardized = URL(fileURLWithPath: binaryPath, isDirectory: false)
            .standardizedFileURL
            .path
        return SHA256.hash(data: Data(standardized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
