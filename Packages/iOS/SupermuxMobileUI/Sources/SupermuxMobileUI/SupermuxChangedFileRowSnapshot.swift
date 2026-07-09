public import SupermuxMobileCore

/// Immutable value snapshot of one changed-file row on the changes screen.
///
/// Rows below the `List` boundary render exclusively from these values plus
/// closure action bundles — no store reference crosses the boundary, per the
/// repo's snapshot-boundary rule. Paths are repo-root-relative (the Mac's
/// wire contract) and displayed as-is with the filename emphasized.
public struct SupermuxChangedFileRowSnapshot: Identifiable, Hashable, Sendable {
    /// Which status bucket the file sits in (drives the row's actions and
    /// which side of the diff opens).
    public enum Area: String, Hashable, Sendable {
        /// Staged in the index.
        case staged
        /// Tracked, changed in the working tree, not staged.
        case unstaged
        /// Not tracked by git yet.
        case untracked
    }

    /// The file's bucket.
    public let area: Area
    /// Repo-root-relative path (the row's stable identity within its area).
    public let path: String
    /// Repo-root-relative source path for renames/copies, when reported.
    public let oldPath: String?
    /// The raw change kind string from the wire (`modified`, `added`, …).
    public let kind: String?

    /// Creates a row snapshot.
    /// - Parameters:
    ///   - area: The file's bucket.
    ///   - path: Repo-root-relative path.
    ///   - oldPath: Optional rename/copy source path.
    ///   - kind: Optional raw change kind.
    public init(area: Area, path: String, oldPath: String? = nil, kind: String? = nil) {
        self.area = area
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
    }

    /// Stable identity: the same path can appear in two areas at once
    /// (e.g. partially staged), so the area participates.
    public var id: String { "\(area.rawValue)|\(path)" }

    /// The emphasized display name: the path's last component.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The de-emphasized directory prefix, or `nil` for root-level files.
    public var directory: String? {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    /// A compact, symbolic status letter (git convention: M/A/D/R/C/U/…);
    /// not localized, like the desktop's status column.
    public var kindBadge: String {
        switch kind {
        case "modified": "M"
        case "added": "A"
        case "deleted": "D"
        case "renamed": "R"
        case "copied": "C"
        case "untracked": "U"
        case "conflicted": "!"
        case "typeChanged": "T"
        default: "•"
        }
    }

    /// Whether opening this row's diff reads the staged (index) side.
    public var diffIsStaged: Bool { area == .staged }

    /// Projects one wire bucket onto row snapshots (order preserved).
    /// - Parameters:
    ///   - files: The bucket's wire entries; `nil` (old peers) yields no rows.
    ///   - area: The bucket the rows belong to.
    public static func rows(
        from files: [SupermuxChangedFileDTO]?,
        area: Area
    ) -> [SupermuxChangedFileRowSnapshot] {
        (files ?? []).map { file in
            SupermuxChangedFileRowSnapshot(
                area: area,
                path: file.path,
                oldPath: file.oldPath,
                kind: file.kind
            )
        }
    }
}
