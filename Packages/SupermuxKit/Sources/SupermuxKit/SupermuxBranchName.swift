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
    /// collapsed; per-component git ref rules are enforced (no component may
    /// begin with `.` or end with `.lock`); the result is capped at
    /// ``maxLength``. The literal name `HEAD`, which git reserves, maps to `nil`.
    /// - Parameter raw: Free-form user input such as "Fix login bug".
    /// - Returns: A valid branch name, or `nil` when nothing usable remains.
    public func sanitize(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: " ", with: "-")
        name = String(name.unicodeScalars.filter { Self.allowedScalars.contains($0) })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }
        while name.contains("//") { name = name.replacingOccurrences(of: "//", with: "/") }
        name = name.trimmingCharacters(in: Self.edgeSeparators)
        name = Self.normalizeRefComponents(name)
        if name.count > Self.maxLength {
            name = String(name.prefix(Self.maxLength))
            name = name.trimmingCharacters(in: Self.edgeSeparators)
            // Truncation can cut a component right at a ".lock" boundary.
            name = Self.normalizeRefComponents(name)
        }
        // Exact match only: `git check-ref-format --branch` rejects "HEAD"
        // but accepts "head" and "HEAD/x".
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    /// Enforces git's per-component ref rules that character filtering misses
    /// (`git check-ref-format`): a slash-separated component may not begin
    /// with `.` or end with `.lock`. Empty components are dropped.
    private static func normalizeRefComponents(_ name: String) -> String {
        name.split(separator: "/")
            .compactMap { rawComponent -> String? in
                var component = rawComponent
                var changed = true
                while changed {
                    changed = false
                    while component.hasPrefix(".") {
                        component = component.dropFirst()
                        changed = true
                    }
                    while component.hasSuffix(".lock") {
                        component = component.dropLast(".lock".count)
                        changed = true
                    }
                }
                return component.isEmpty ? nil : String(component)
            }
            .joined(separator: "/")
    }

    /// Generates a friendly, readable two-word branch name like
    /// `cheerful-umbrella`, for when the user leaves the branch field blank.
    ///
    /// The name is not guaranteed unique on its own — callers should pass the
    /// result through ``deduplicate(_:existing:takenDirectories:)`` against
    /// the repository's branches (as ``SupermuxGitWorktreeService`` does).
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
    ///
    /// A name only counts as free when both the branch name itself and its
    /// ``directoryComponent(for:)`` are unclaimed: branches like `a/b` and
    /// `a-b` flatten to the same worktree directory, so callers pass the
    /// directory names already in use to avoid a doomed `git worktree add`.
    /// - Parameters:
    ///   - candidate: A sanitized branch name.
    ///   - existing: Branch names already present in the repository.
    ///   - takenDirectories: Worktree directory names already in use.
    /// - Returns: A unique branch name within ``maxLength``.
    public func deduplicate(
        _ candidate: String,
        existing: [String],
        takenDirectories: Set<String> = []
    ) -> String {
        let takenBranches = Set(existing.map { $0.lowercased() })
        let takenDirs = Set(takenDirectories.map { $0.lowercased() })
        func isFree(_ name: String) -> Bool {
            !takenBranches.contains(name.lowercased())
                && !takenDirs.contains(directoryComponent(for: name).lowercased())
        }
        if isFree(candidate) { return candidate }
        var base = candidate
        if base.count > Self.maxLength - Self.suffixReserve {
            base = String(base.prefix(Self.maxLength - Self.suffixReserve))
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        for n in 2...9999 {
            let attempt = "\(base)-\(n)"
            if isFree(attempt) { return attempt }
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

    private static let edgeSeparators = CharacterSet(charactersIn: "-./")
}
