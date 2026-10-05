import Foundation

/// Where a cmux relay is, from its id (`apne1`).
///
/// Three ids are confirmed from the field (Tokyo, Singapore, Taiwan). The US
/// and EU cities are assumed from GCP-style ids and not confirmed with the
/// relay owner, so those show their catalog region
/// (`config/iroh/managed-relay-catalog.json`) instead of a city that may be
/// wrong. An unknown id shows itself, upper-cased.
///
/// The names are English and stable; UI localizes them by ``id``.
public struct SupermuxRelayPlace: Equatable, Sendable {
    /// How sure the table is of the city.
    public enum Confidence: String, Equatable, Sendable {
        /// Seen in the field.
        case confirmed
        /// Assumed from the id; the region is right, the city may not be.
        case bestEffort = "best_effort"
        /// Not in the table.
        case unknown
    }

    /// The relay id, lower-cased.
    public let id: String
    /// The city, when the table has one.
    public let city: String?
    /// The catalog's broad region, when the table has one.
    public let region: String?
    /// How sure the table is of ``city``.
    public let confidence: Confidence

    private struct Entry {
        let city: String
        let region: String
        let confirmed: Bool
    }

    private static let table: [String: Entry] = [
        "apne1": Entry(city: "Tokyo", region: "Asia Pacific Northeast", confirmed: true),
        "apse1": Entry(city: "Singapore", region: "Asia Pacific Southeast", confirmed: true),
        "ape1": Entry(city: "Taiwan", region: "Asia Pacific East", confirmed: true),
        "usc1": Entry(city: "Iowa", region: "US Central", confirmed: false),
        "usw1": Entry(city: "Oregon", region: "US West", confirmed: false),
        "use4": Entry(city: "Virginia", region: "US East", confirmed: false),
        "euw4": Entry(city: "Netherlands", region: "Europe West", confirmed: false),
    ]

    /// Looks up a relay id.
    /// - Parameter id: The relay id, any case.
    public init(id: String) {
        let key = id.lowercased()
        self.id = key
        let entry = Self.table[key]
        city = entry?.city
        region = entry?.region
        confidence = entry.map { $0.confirmed ? .confirmed : .bestEffort } ?? .unknown
    }

    /// What to show: the city when confirmed, the region when the city is
    /// only assumed, else the id upper-cased.
    public var displayName: String {
        switch confidence {
        case .confirmed: city ?? id.uppercased()
        case .bestEffort: region ?? id.uppercased()
        case .unknown: id.uppercased()
        }
    }
}
