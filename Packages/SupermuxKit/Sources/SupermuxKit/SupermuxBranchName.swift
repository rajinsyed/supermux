import Foundation

/// Pure helpers for turning user input into safe, unique git branch names.
///
/// Ports the piggycode semantics: sanitize to git-safe characters, cap the
/// length, and deduplicate against existing branches with `-2`, `-3`, …
/// suffixes (case-insensitive).
public struct SupermuxBranchName: Sendable {
    /// Longest branch name supermux will produce.
    public static let maxLength = 100
    /// Characters reserved at the end for a dedup suffix like `-99999`.
    private static let suffixReserve = 6

    /// Creates the helper. It is stateless; a value exists so call sites can
    /// inject alternative naming policies later without a global.
    public init() {}

    /// Sanitizes raw user input into a valid git branch name.
    ///
    /// Spaces become `-`; characters outside `[A-Za-z0-9._/-]` are dropped;
    /// runs of `-`, leading/trailing separators, and `..` sequences are
    /// collapsed; the result is capped at ``maxLength``.
    /// - Parameter raw: Free-form user input such as "Fix login bug".
    /// - Returns: A valid branch name, or `nil` when nothing usable remains.
    public func sanitize(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: " ", with: "-")
        name = String(name.unicodeScalars.filter { Self.allowedScalars.contains($0) })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }
        while name.contains("//") { name = name.replacingOccurrences(of: "//", with: "/") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        if name.count > Self.maxLength {
            name = String(name.prefix(Self.maxLength))
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        }
        return name.isEmpty ? nil : name
    }

    /// Generates a friendly, readable two-word branch name like
    /// `cheerful-umbrella`, for when the user leaves the branch field blank.
    ///
    /// The name is not guaranteed unique on its own — callers should pass the
    /// result through ``deduplicate(_:existing:)`` against the repository's
    /// branches (as ``SupermuxGitWorktreeService`` does).
    /// - Parameter generator: Randomness source; injectable for deterministic tests.
    /// - Returns: A sanitized, git-safe `predicate-object` name.
    public func randomName<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let predicate = SupermuxFriendlyWords.predicates.randomElement(using: &generator) ?? "calm"
        let object = SupermuxFriendlyWords.objects.randomElement(using: &generator) ?? "river"
        return "\(predicate)-\(object)"
    }

    /// Generates a friendly two-word branch name using the system RNG.
    /// - Returns: A sanitized, git-safe `predicate-object` name.
    public func randomName() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomName(using: &generator)
    }

    /// Returns `candidate` or a `-N` suffixed variant that does not collide
    /// with `existing` (compared case-insensitively).
    /// - Parameters:
    ///   - candidate: A sanitized branch name.
    ///   - existing: Branch names already present in the repository.
    /// - Returns: A unique branch name within ``maxLength``.
    public func deduplicate(_ candidate: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(candidate.lowercased()) { return candidate }
        var base = candidate
        if base.count > Self.maxLength - Self.suffixReserve {
            base = String(base.prefix(Self.maxLength - Self.suffixReserve))
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        for n in 2...9999 {
            let attempt = "\(base)-\(n)"
            if !taken.contains(attempt.lowercased()) { return attempt }
        }
        // Pathological collision space: fall back to a time-based suffix.
        let stamp = String(Int(Date().timeIntervalSince1970), radix: 36)
        return "\(base)-\(stamp)"
    }

    /// Converts a branch name into a single safe path component for the
    /// worktree directory (slashes become dashes).
    /// - Parameter branch: A valid branch name.
    /// - Returns: A path component containing no separators.
    public func directoryComponent(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    private static let allowedScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "._/-")
        return set
    }()
}
