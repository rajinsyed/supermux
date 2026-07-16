public import SupermuxMobileCore

/// Typed result values for the `mobile.supermux.files.*` methods.
/// `files.list` entries decode straight into
/// `SupermuxMobileCore.SupermuxFileEntryDTO`; every field is optional so old
/// peers tolerate additions.

/// Result of `mobile.supermux.files.list`: `{path, entries}`.
public struct SupermuxFilesListResponse: Codable, Sendable, Equatable {
    /// The listed directory's root-relative path (empty for the root).
    public var path: String?
    /// The directory's children in the Mac's order (directories first,
    /// case-insensitive name order, dotfiles excluded — desktop parity).
    public var entries: [SupermuxFileEntryDTO]?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - path: Optional root-relative directory path.
    ///   - entries: Optional directory children.
    public init(path: String? = nil, entries: [SupermuxFileEntryDTO]? = nil) {
        self.path = path
        self.entries = entries
    }
}

/// Result of `mobile.supermux.files.create`/`rename`/`duplicate`/`trash`:
/// `{ok, path?}` — `path` is the affected entry's (new) root-relative path
/// for the single-entry mutations; `trash` answers `{ok}` alone.
public struct SupermuxFilesMutationResponse: Codable, Sendable, Equatable {
    /// Whether the mutation applied.
    public var ok: Bool?
    /// The affected entry's (new) root-relative path, when the method
    /// reports one.
    public var path: String?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - ok: Optional success flag.
    ///   - path: Optional affected root-relative path.
    public init(ok: Bool? = nil, path: String? = nil) {
        self.ok = ok
        self.path = path
    }
}
