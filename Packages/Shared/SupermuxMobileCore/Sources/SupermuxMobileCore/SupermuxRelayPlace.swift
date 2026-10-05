import Foundation

/// Stub until the classifier lands.
public struct SupermuxRelayPlace: Equatable, Sendable {
    public enum Confidence: String, Equatable, Sendable { case confirmed, bestEffort = "best_effort", unknown }
    public let id: String
    public let city: String?
    public let region: String?
    public let confidence: Confidence

    public init(id: String) {
        self.id = id
        city = nil
        region = nil
        confidence = .unknown
    }

    public var displayName: String { id }
}
