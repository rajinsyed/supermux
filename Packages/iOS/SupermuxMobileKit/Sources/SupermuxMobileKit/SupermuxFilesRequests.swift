import SupermuxMobileCore

/// Typed request values for the `mobile.supermux.files.*` methods.
///
/// Each value owns its exact wire shape (`wireMethod` + `wireParams`), so the
/// SAME mapping that ``SupermuxMacClient`` sends is what fakes record and
/// tests assert against (UI-05: recorded calls match architecture §2
/// exactly). Every path is root-relative; the Mac confines it to the request's
/// root (architecture §10) and rejects escapes with `invalid_params`.

/// The confined root a files request browses: a workspace's current directory
/// or a project's `root_path` — the same two roots the desktop file explorer
/// binds to. Exactly ONE selector travels on the wire (the Mac rejects
/// both/neither with `invalid_params`), and the selector decides the ticket
/// scope: `workspace_id` is workspace-scoped-permitted, `project_id` requires
/// a Mac-wide ticket (architecture §4).
public enum SupermuxFilesRoot: Equatable, Sendable {
    /// The workspace's current directory (`workspace_id` on the wire).
    case workspace(id: String)
    /// The project's `root_path` (`project_id` on the wire).
    case project(id: String)

    /// The selector's contribution to a request's wire params.
    var wireParams: [String: Any] {
        switch self {
        case let .workspace(id): ["workspace_id": id]
        case let .project(id): ["project_id": id]
        }
    }
}

/// `mobile.supermux.files.list`: `{workspace_id|project_id, path?}` — the
/// children of the directory at root-relative `path` (absent = the root).
public struct SupermuxFilesListRequest: Equatable, Sendable {
    /// The confined root to browse.
    public let root: SupermuxFilesRoot
    /// Root-relative directory path; `nil` or empty lists the root itself.
    public let path: String?

    /// Creates the request.
    /// - Parameters:
    ///   - root: The confined root to browse.
    ///   - path: Root-relative directory path; `nil`/empty lists the root.
    public init(root: SupermuxFilesRoot, path: String? = nil) {
        self.root = root
        self.path = path
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.filesList.rawValue }

    /// The exact wire params (`path` omitted at the root).
    public var wireParams: [String: Any] {
        var params = root.wireParams
        if let path, !path.isEmpty {
            params["path"] = path
        }
        return params
    }
}

/// `mobile.supermux.files.create`: `{workspace_id|project_id, path, kind}` —
/// creates an empty file or a folder at root-relative `path`.
public struct SupermuxFilesCreateRequest: Equatable, Sendable {
    /// What `files.create` makes: an empty file or a folder.
    public enum Kind: String, Equatable, Sendable {
        /// An empty file.
        case file
        /// A folder.
        case folder
    }

    /// The confined root the path resolves against.
    public let root: SupermuxFilesRoot
    /// Root-relative path of the entry to create (parent must exist).
    public let path: String
    /// Whether to create a file or a folder.
    public let kind: Kind

    /// Creates the request.
    /// - Parameters:
    ///   - root: The confined root the path resolves against.
    ///   - path: Root-relative path of the entry to create.
    ///   - kind: Whether to create a file or a folder.
    public init(root: SupermuxFilesRoot, path: String, kind: Kind) {
        self.root = root
        self.path = path
        self.kind = kind
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.filesCreate.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        var params = root.wireParams
        params["path"] = path
        params["kind"] = kind.rawValue
        return params
    }
}

/// `mobile.supermux.files.rename`: `{workspace_id|project_id, path, new_name}`
/// — renames the entry at root-relative `path` to a new single-component name.
public struct SupermuxFilesRenameRequest: Equatable, Sendable {
    /// The confined root the path resolves against.
    public let root: SupermuxFilesRoot
    /// Root-relative path of the entry to rename.
    public let path: String
    /// The new name (a single path component, no `/`).
    public let newName: String

    /// Creates the request.
    /// - Parameters:
    ///   - root: The confined root the path resolves against.
    ///   - path: Root-relative path of the entry to rename.
    ///   - newName: The new single-component name.
    public init(root: SupermuxFilesRoot, path: String, newName: String) {
        self.root = root
        self.path = path
        self.newName = newName
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.filesRename.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        var params = root.wireParams
        params["path"] = path
        params["new_name"] = newName
        return params
    }
}

/// `mobile.supermux.files.duplicate`: `{workspace_id|project_id, path}` —
/// duplicates the entry at root-relative `path` with a Finder-style " copy"
/// name chosen Mac-side.
public struct SupermuxFilesDuplicateRequest: Equatable, Sendable {
    /// The confined root the path resolves against.
    public let root: SupermuxFilesRoot
    /// Root-relative path of the entry to duplicate.
    public let path: String

    /// Creates the request.
    /// - Parameters:
    ///   - root: The confined root the path resolves against.
    ///   - path: Root-relative path of the entry to duplicate.
    public init(root: SupermuxFilesRoot, path: String) {
        self.root = root
        self.path = path
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.filesDuplicate.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        var params = root.wireParams
        params["path"] = path
        return params
    }
}

/// `mobile.supermux.files.trash`: `{workspace_id|project_id, paths}` — moves
/// the entries at root-relative `paths` to the Trash (batch-validated
/// Mac-side: one escaping path rejects the whole request with no effect).
public struct SupermuxFilesTrashRequest: Equatable, Sendable {
    /// The confined root the paths resolve against.
    public let root: SupermuxFilesRoot
    /// Root-relative paths of the entries to trash (non-empty).
    public let paths: [String]

    /// Creates the request.
    /// - Parameters:
    ///   - root: The confined root the paths resolve against.
    ///   - paths: Root-relative paths of the entries to trash.
    public init(root: SupermuxFilesRoot, paths: [String]) {
        self.root = root
        self.paths = paths
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.filesTrash.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        var params = root.wireParams
        params["paths"] = paths
        return params
    }
}
