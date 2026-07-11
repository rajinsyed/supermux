import Foundation
public import Observation
public import SupermuxMobileCore

/// Main-actor state for one confined directory tree on the phone: the current
/// directory's listing, breadcrumb navigation, and the create/rename/
/// duplicate/trash operations — the phone counterpart of the desktop file
/// explorer, over the `mobile.supermux.files.*` RPCs.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected. Every
/// entry point is hidden (and the store inert) unless the host advertises
/// `supermux.files.v1`.
///
/// The files namespace has no event topic (architecture §2), so the store is
/// pull-only: the screen loads on appear, refreshes on pull, and the store
/// refetches the CURRENT directory after every successful mutation (UI-05).
/// Navigation commits only on success — a failed child listing keeps the
/// current directory and surfaces ``lastErrorDescription``.
@MainActor
@Observable
public final class SupermuxMobileFileBrowserStore {
    /// The current directory as root-relative path segments (empty = root).
    public private(set) var pathSegments: [String] = []

    /// The current directory's children, in the Mac's order.
    public private(set) var entries: [SupermuxFileEntryDTO] = []

    /// Whether at least one listing succeeded (drives placeholder vs list).
    public private(set) var hasLoaded = false

    /// Whether a listing fetch is on the wire.
    public private(set) var isLoading = false

    /// Whether a mutation is on the wire (disables the op affordances).
    public private(set) var isMutating = false

    /// Human-readable description of the most recent failure, for a
    /// non-blocking error surface. Cleared on the next successful fetch.
    public private(set) var lastErrorDescription: String?

    /// The confined root this store browses.
    public let root: SupermuxFilesRoot

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities

    /// Monotonic fetch counter. Each ``fetch(segments:)`` claims the next
    /// value; only the latest may commit its result, so a slower earlier
    /// navigation cannot overwrite a directory the user has since opened.
    @ObservationIgnored private var fetchGeneration = 0

    /// Whether the phone shows file-browser UI at all: gated on the host
    /// advertising `supermux.files.v1`.
    public var showsFileBrowser: Bool { capabilities.supportsFiles }

    /// The current directory's root-relative path (empty for the root).
    public var currentPath: String { pathSegments.joined(separator: "/") }

    /// Creates a file-browser store for one confined root.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - root: The confined root to browse.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        root: SupermuxFilesRoot
    ) {
        self.client = client
        self.capabilities = capabilities
        self.root = root
    }

    /// Initial fetch of the current directory (the screen's `.task`). A no-op
    /// without `supermux.files.v1` — against an upstream Mac the store never
    /// issues a request.
    public func load() async {
        guard showsFileBrowser else { return }
        _ = await fetch(segments: pathSegments)
    }

    /// Refetches the current directory (pull-to-refresh).
    public func refresh() async {
        guard showsFileBrowser else { return }
        _ = await fetch(segments: pathSegments)
    }

    /// Descends into a child directory. Commits the new path only when its
    /// listing succeeds; a failure keeps the current directory and surfaces
    /// ``lastErrorDescription``.
    /// - Parameter name: The child directory's entry name.
    public func navigate(into name: String) async {
        guard showsFileBrowser else { return }
        _ = await fetch(segments: pathSegments + [name])
    }

    /// Jumps to a breadcrumb ancestor: keeps the first `depth` path segments
    /// (0 = the root). Commits only on a successful listing, like
    /// ``navigate(into:)``.
    /// - Parameter depth: How many leading segments to keep.
    public func navigate(toDepth depth: Int) async {
        guard showsFileBrowser else { return }
        _ = await fetch(segments: Array(pathSegments.prefix(max(0, depth))))
    }

    /// `files.create {path, kind: file}` in the current directory, then
    /// refetches the listing. Invalid names throw
    /// ``SupermuxInvalidFileNameError`` before any RPC.
    /// - Parameter name: The new file's name (single path component).
    public func createFile(named name: String) async throws {
        let validated = try validated(name)
        try await mutate {
            _ = try await self.client.filesCreate(SupermuxFilesCreateRequest(
                root: self.root,
                path: self.wirePath(forEntryNamed: validated),
                kind: .file
            ))
        }
    }

    /// `files.create {path, kind: folder}` in the current directory, then
    /// refetches the listing. Invalid names throw
    /// ``SupermuxInvalidFileNameError`` before any RPC.
    /// - Parameter name: The new folder's name (single path component).
    public func createFolder(named name: String) async throws {
        let validated = try validated(name)
        try await mutate {
            _ = try await self.client.filesCreate(SupermuxFilesCreateRequest(
                root: self.root,
                path: self.wirePath(forEntryNamed: validated),
                kind: .folder
            ))
        }
    }

    /// `files.rename {path, new_name}` for an entry of the current directory,
    /// then refetches the listing. Invalid names throw
    /// ``SupermuxInvalidFileNameError`` before any RPC.
    /// - Parameters:
    ///   - entryName: The entry's current name.
    ///   - newName: The new name (single path component).
    public func rename(entryNamed entryName: String, to newName: String) async throws {
        let validated = try validated(newName)
        try await mutate {
            _ = try await self.client.filesRename(SupermuxFilesRenameRequest(
                root: self.root,
                path: self.wirePath(forEntryNamed: entryName),
                newName: validated
            ))
        }
    }

    /// `files.duplicate {path}` for an entry of the current directory (the
    /// Mac picks the Finder-style " copy" name), then refetches the listing.
    /// - Parameter entryName: The entry's name.
    public func duplicate(entryNamed entryName: String) async throws {
        try await mutate {
            _ = try await self.client.filesDuplicate(SupermuxFilesDuplicateRequest(
                root: self.root,
                path: self.wirePath(forEntryNamed: entryName)
            ))
        }
    }

    /// `files.trash {paths}` for entries of the current directory (one batch
    /// call — the Mac validates every path before touching anything), then
    /// refetches the listing. An empty selection is a no-op.
    /// - Parameter entryNames: The entries' names.
    public func trash(entryNames: [String]) async throws {
        guard !entryNames.isEmpty else { return }
        try await mutate {
            _ = try await self.client.filesTrash(SupermuxFilesTrashRequest(
                root: self.root,
                paths: entryNames.map { self.wirePath(forEntryNamed: $0) }
            ))
        }
    }

    // MARK: - Internals

    /// Runs one mutation with the shared guards (capability gate, `isMutating`
    /// flag) and refetches the current directory on success (UI-05's
    /// refetch-after-op). Errors rethrow for the prompt UI to display.
    private func mutate(_ operation: @MainActor () async throws -> Void) async throws {
        guard showsFileBrowser else { throw SupermuxMacUnavailableError() }
        isMutating = true
        defer { isMutating = false }
        try await operation()
        _ = await fetch(segments: pathSegments)
    }

    /// Fetches one directory's listing and commits it (entries + path) on
    /// success. Returns whether the fetch succeeded.
    private func fetch(segments: [String]) async -> Bool {
        fetchGeneration += 1
        let generation = fetchGeneration
        isLoading = true
        defer { if generation == fetchGeneration { isLoading = false } }
        do {
            let response = try await client.filesList(SupermuxFilesListRequest(
                root: root,
                path: segments.isEmpty ? nil : segments.joined(separator: "/")
            ))
            // Only the most recent navigation commits: an out-of-order response
            // for a directory the user already navigated away from must not
            // replace the current listing/breadcrumb (which later mutations
            // build their paths from).
            guard generation == fetchGeneration else { return false }
            entries = response.entries ?? []
            pathSegments = segments
            hasLoaded = true
            lastErrorDescription = nil
            return true
        } catch {
            guard generation == fetchGeneration else { return false }
            lastErrorDescription = error.localizedDescription
            return false
        }
    }

    /// Trims and validates a user-typed name; throws before any RPC when the
    /// name cannot be a single path component.
    private func validated(_ name: String) throws -> String {
        if let issue = SupermuxFileName.issue(with: name) {
            throw SupermuxInvalidFileNameError(issue: issue, name: name)
        }
        return SupermuxFileName.normalized(name)
    }

    /// The root-relative wire path for an entry of the CURRENT directory.
    private func wirePath(forEntryNamed name: String) -> String {
        pathSegments.isEmpty ? name : currentPath + "/" + name
    }
}
