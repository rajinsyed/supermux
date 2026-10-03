import Foundation

/// A device-independent key for "the same repository" across Macs.
///
/// Two Macs register their own copy of a repo as separate projects with
/// separate ids and paths; the origin URL is the one thing they share. The key
/// folds the spellings git accepts for one remote (scp-style SSH, `ssh://`,
/// `https://`, credentials, ports, `.git`, trailing slash, host case) into
/// `host/owner/repo`, while keeping owner and repo case, so forks never match.
public enum SupermuxGitRemoteIdentity {
    /// The normalized key for a remote URL, or `nil` when it carries no identity.
    public static func normalized(_ remote: String?) -> String? {
        guard let trimmed = remote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return pathKey(trimmed) }
        if trimmed.lowercased().hasPrefix("file://") { return pathKey(String(trimmed.dropFirst(7))) }
        if trimmed.contains("://") { return urlKey(trimmed) }
        return scpKey(trimmed)
    }

    private static func urlKey(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return join(host: host, path: components.path)
    }

    /// `user@host:owner/repo.git` (git's scp-like syntax).
    private static func scpKey(_ value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let authority = value[..<colon]
        let host = (authority.split(separator: "@").last.map(String.init) ?? "").lowercased()
        guard !host.isEmpty else { return nil }
        return join(host: host, path: String(value[value.index(after: colon)...]))
    }

    private static func join(host: String, path: String) -> String? {
        let repoPath = trimmedRepoPath(path)
        guard !repoPath.isEmpty else { return nil }
        return host + "/" + repoPath
    }

    private static func pathKey(_ path: String) -> String? {
        let repoPath = trimmedRepoPath(path)
        return repoPath.isEmpty ? nil : "/" + repoPath
    }

    private static func trimmedRepoPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
