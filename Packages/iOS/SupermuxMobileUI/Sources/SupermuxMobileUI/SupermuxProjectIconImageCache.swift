import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Decoded project icons, keyed by the etag that produced them, readable
/// **synchronously** from a view body.
///
/// This exists because of where the sidebar's avatars live. The phone's
/// Projects section is hosted in one `UIHostingConfiguration` cell of the
/// shell's `UITableView`, and any update that changes a row's measured height
/// sends the whole cell through `reloadRows` — which destroys the SwiftUI
/// subtree and builds a fresh one. A decoded icon held only in the avatar's
/// `@State` does not survive that: the rebuilt avatar starts at `nil`, and the
/// existing `SupermuxProjectIconCache` is an `actor`, so even a guaranteed hit
/// costs an `await` and therefore at least one frame. The visible result is
/// every project icon blanking and popping back whenever something unrelated
/// is tapped.
///
/// A synchronous cache removes the frame: a rebuilt avatar reads its last
/// decoded image during `body` and paints it immediately, and the async task
/// behind it only ever has to run on a genuine miss.
///
/// Deliberately NOT `@Observable`. Views below the shell's list boundary must
/// not hold an observable store (the issue-2586 rule), and nothing here needs
/// to invalidate a body: entries are written from the same `.task` that then
/// assigns the view's own state, so the repaint already happens.
@MainActor
final class SupermuxProjectIconImageCache {
    /// The process-wide cache. One instance, because the whole point is to
    /// outlive the views — a per-view cache would die with the subtree it was
    /// meant to protect.
    static let shared = SupermuxProjectIconImageCache()

    /// A cached icon and the identity of the bytes it was decoded from.
    private struct Entry {
        /// The icon identity these pixels belong to. Held so a project whose
        /// icon was replaced Mac-side never paints the previous image: a
        /// changed etag misses, and the avatar falls back to its gradient
        /// while the new bytes are fetched.
        let identity: SupermuxProjectIconIdentity
        let image: Image
    }

    private var entries: [String: Entry] = [:]

    /// Bounds the cache. Projects are few — a user with more registered
    /// projects than this is far outside the design point — but an unbounded
    /// dictionary of decoded images in a long-lived singleton is a leak, so it
    /// evicts rather than growing forever.
    private static let capacity = 64

    private init() {}

    /// The decoded icon for an identity, or `nil` when nothing matching is
    /// cached. Safe to call from a view body: no `await`, no state write.
    /// - Parameter identity: The avatar's icon-fetch identity.
    func image(for identity: SupermuxProjectIconIdentity) -> Image? {
        guard let entry = entries[identity.projectID], entry.identity == identity else {
            return nil
        }
        return entry.image
    }

    /// The decoded icon cached for a project, whatever identity produced it.
    ///
    /// Deliberately identity-agnostic, unlike ``image(for:)``. A notification
    /// carries a frozen snapshot of its project taken when it fired, so its
    /// icon token is often older than whatever the Projects list last fetched —
    /// an exact-identity match would then miss on every notification and drop
    /// the row to a letter avatar even though the correct logo is sitting in
    /// this cache. For a notification row the right answer is "this project's
    /// icon"; a marginally stale logo is strictly better than none, and the
    /// Projects list keeps this entry current anyway.
    ///
    /// Never use this where the exact bytes matter (the Projects avatar's own
    /// fetch) — there, a stale hit would suppress a re-fetch.
    /// - Parameter projectID: The project's UUID string.
    func anyImage(forProjectID projectID: String) -> Image? {
        entries[projectID]?.image
    }

    /// Stores a freshly decoded icon.
    /// - Parameters:
    ///   - image: The decoded image.
    ///   - identity: The identity the bytes were fetched under.
    func store(_ image: Image, for identity: SupermuxProjectIconIdentity) {
        if entries[identity.projectID] == nil, entries.count >= Self.capacity {
            // Arbitrary victim: with a working set this far below capacity,
            // eviction is a safety valve, not a hot path worth ordering for.
            entries.removeValue(forKey: entries.keys.first ?? "")
        }
        entries[identity.projectID] = Entry(identity: identity, image: image)
    }

    /// Forgets a project's icon (it no longer has a custom one).
    /// - Parameter projectID: The project's UUID string.
    func removeImage(forProjectID projectID: String) {
        entries[projectID] = nil
    }

    /// Decodes PNG bytes into a SwiftUI image.
    /// - Parameter data: The icon's PNG bytes.
    static func decode(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        nil
        #endif
    }
}
