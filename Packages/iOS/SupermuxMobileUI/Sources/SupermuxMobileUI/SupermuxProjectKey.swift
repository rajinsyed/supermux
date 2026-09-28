import Foundation

/// A project's identity on the phone: the owning Mac pairing plus the
/// project's Mac-local id.
///
/// Project ids are only unique on their own Mac, so everything the Projects
/// section keys by project (rows, expansion, detail route, the flat-list hide
/// filter) uses this key. Its ``rawValue`` is the section row id:
/// `<pairingID>` + U+001F + `<projectID>`, or the bare project id when no
/// pairing is known (a single legacy session), which keeps single-Mac
/// behavior and persisted state unchanged.
public struct SupermuxProjectKey: Hashable, Sendable {
    private static let separator: Character = "\u{1F}"

    /// The owning pairing's id (`SupermuxMacSeam.pairingID`), or empty.
    public let pairingID: String
    /// The project's Mac-local UUID string.
    public let projectID: String

    /// Creates a key.
    /// - Parameters:
    ///   - pairingID: The owning pairing's id, or empty when unknown.
    ///   - projectID: The project's Mac-local UUID string.
    public init(pairingID: String, projectID: String) {
        self.pairingID = pairingID
        self.projectID = projectID
    }

    /// Parses a row id. A pairing id may itself contain the separator
    /// (`device` + U+001F + `tag`), so the split is on the LAST one — project
    /// ids never contain it.
    /// - Parameter rawValue: A section row id.
    public init(rawValue: String) {
        guard let index = rawValue.lastIndex(of: Self.separator) else {
            self.init(pairingID: "", projectID: rawValue)
            return
        }
        self.init(
            pairingID: String(rawValue[..<index]),
            projectID: String(rawValue[rawValue.index(after: index)...])
        )
    }

    /// The section row id for this key.
    public var rawValue: String {
        pairingID.isEmpty ? projectID : "\(pairingID)\(Self.separator)\(projectID)"
    }
}
