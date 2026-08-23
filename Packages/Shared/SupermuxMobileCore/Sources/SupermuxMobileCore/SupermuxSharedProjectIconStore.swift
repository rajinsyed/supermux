public import Foundation

/// Project icon PNGs on disk in the app-group container, so the notification
/// service extension can paint the real project logo on a push banner.
///
/// **Why this exists.** The extension renders the avatar itself, in-process,
/// because it cannot open the app's encrypted RPC session to the Mac. The first
/// implementation therefore drew a gradient chip from the identity carried in
/// the payload — which is all the payload *can* carry: APNs caps a notification
/// at 4096 bytes, and a real project icon is an order of magnitude past that
/// (`ryne`'s favicon is 15 KB raw, ~20 KB base64). No amount of payload tuning
/// reaches the actual logo; the bytes have to arrive out of band.
///
/// So the app persists every icon it fetches into a container both processes
/// can read, and the extension reads it from there. The app group is the only
/// sanctioned shared surface: keychain-group sharing with the main install is
/// explicitly forbidden in this fork (the Iroh stores half-share and mutually
/// wipe each other's relay credentials).
///
/// **Both sides must agree on the layout, and only one of them links this
/// file.** An app extension links its own copy of every dependency it imports,
/// so pulling the mobile package graph into a process with a hard execution
/// budget would cost launch time the extension does not have. The extension
/// therefore re-declares its reader, exactly as it already re-declares the push
/// payload struct and the accent palette. ``relativePath(forProjectID:)`` is the
/// contract between them, and `SupermuxSharedProjectIconStoreTests` pins it so
/// the two cannot drift silently.
/// lint:allow namespace-enum — shared app/extension storage contract with no runtime state.
public enum SupermuxSharedProjectIconStore: Sendable {
    /// The app group both the app and its notification service extension join.
    ///
    /// Hardcoded rather than read from the bundle: the extension has no access
    /// to the app's Info.plist, and a mismatched identifier fails by silently
    /// returning an empty container rather than by erroring.
    public static let appGroupIdentifier = "group.com.supermux.ios"

    /// Subdirectory holding one PNG per project.
    public static let directoryName = "project-icons"

    /// The container-relative path for a project's icon.
    ///
    /// The project id is a UUID string, so it is already path-safe; it is
    /// sanitized anyway because a malformed id must not be able to escape the
    /// directory. Returns `nil` when nothing usable survives sanitization.
    /// - Parameter projectID: The project's UUID string.
    public static func relativePath(forProjectID projectID: String) -> String? {
        guard let sanitized = sanitized(projectID) else { return nil }
        return "\(directoryName)/\(sanitized).png"
    }

    /// The app group container, or `nil` when the entitlement is absent.
    ///
    /// A build signed without the app group (the personal-team dogfood lane)
    /// gets `nil` here and degrades to the generated avatar — the same result as
    /// before this store existed, never a crash.
    public static func containerURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// The on-disk URL for a project's icon, or `nil` when unavailable.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - fileManager: Injected for tests.
    public static func iconURL(
        forProjectID projectID: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let container = containerURL(fileManager: fileManager),
              let relative = relativePath(forProjectID: projectID) else { return nil }
        return container.appending(path: relative)
    }

    /// Reads a project's cached icon bytes, or `nil` when none is stored.
    ///
    /// The read side of the contract — what the extension does, and all it does.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - fileManager: Injected for tests.
    public static func iconData(
        forProjectID projectID: String,
        fileManager: FileManager = .default
    ) -> Data? {
        guard let url = iconURL(forProjectID: projectID, fileManager: fileManager) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Writes a project's icon bytes for the extension to read.
    ///
    /// Written atomically: the extension may be reading at any moment, and a
    /// half-written PNG would decode to garbage rather than to nothing.
    ///
    /// Best-effort by design — a failed write costs a generated avatar on the
    /// next banner, which is not worth propagating an error to a caller whose
    /// actual job is rendering a projects list.
    /// - Parameters:
    ///   - data: The icon's PNG bytes.
    ///   - projectID: The project's UUID string.
    ///   - fileManager: Injected for tests.
    /// - Returns: Whether the bytes were stored.
    @discardableResult
    public static func store(
        _ data: Data,
        forProjectID projectID: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !data.isEmpty,
              let url = iconURL(forProjectID: projectID, fileManager: fileManager) else {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Forgets a project's icon — it no longer has a custom one, or the project
    /// is gone. Without this the container would accumulate logos for deleted
    /// projects forever.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - fileManager: Injected for tests.
    public static func removeIcon(
        forProjectID projectID: String,
        fileManager: FileManager = .default
    ) {
        guard let url = iconURL(forProjectID: projectID, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Drops stored icons for projects that no longer exist.
    ///
    /// Called after a projects refresh. Keyed on the live id set rather than on
    /// age, because an icon for a live project must never be evicted — the
    /// banner has no way to re-fetch it.
    /// - Parameters:
    ///   - liveProjectIDs: Every currently-registered project id.
    ///   - fileManager: Injected for tests.
    public static func pruneIcons(
        keeping liveProjectIDs: Set<String>,
        fileManager: FileManager = .default
    ) {
        guard let container = containerURL(fileManager: fileManager) else { return }
        let directory = container.appending(path: directoryName)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let live = Set(liveProjectIDs.compactMap { sanitized($0) })
        for entry in entries where entry.pathExtension == "png" {
            guard !live.contains(entry.deletingPathExtension().lastPathComponent) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Restricts an id to characters that cannot traverse or escape the
    /// directory. A UUID string passes through unchanged.
    private static func sanitized(_ projectID: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = projectID.unicodeScalars.filter { allowed.contains($0) }
        guard !filtered.isEmpty else { return nil }
        return String(String.UnicodeScalarView(filtered))
    }
}
