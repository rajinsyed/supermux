/// The keys one capture pass decided to write.
///
/// ```swift
/// store.setKeys(plan.ownKeys)     // by stable id, after mapping
/// outbox.send(plan.mirrorKeys)    // each one asks the mirror's owner
/// ```
public struct SupermuxOrderCapturePlan<ID: Hashable & Sendable>: Equatable, Sendable {
    /// New keys for own rows, only where the key changes.
    public var ownKeys: [ID: String]
    /// New keys for moved mirrors, to send to each mirror's owner.
    public var mirrorKeys: [ID: String]

    /// Creates a plan.
    /// - Parameters:
    ///   - ownKeys: New keys for own rows.
    ///   - mirrorKeys: New keys for moved mirrors.
    public init(ownKeys: [ID: String] = [:], mirrorKeys: [ID: String] = [:]) {
        self.ownKeys = ownKeys
        self.mirrorKeys = mirrorKeys
    }

    /// Whether the pass writes nothing.
    public var isEmpty: Bool {
        ownKeys.isEmpty && mirrorKeys.isEmpty
    }
}
