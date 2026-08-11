import AppKit
import Foundation
import SupermuxKit
import SupermuxMobileCore
import UserNotifications

/// Applies a notification's project identity to the macOS banner: a provenance
/// subtitle, a per-project `threadIdentifier` so Notification Center stacks a
/// project's banners together, and a circular project-avatar attachment.
///
/// The avatar is what makes a stack of banners from four repos scannable
/// instead of four identical rectangles.
///
/// **Why this is synchronous.** An earlier version rendered off the main actor
/// and scheduled the banner from the completion. That was wrong twice over: it
/// made banner ordering depend on raster completion order, and it required
/// assuming main-actor isolation inside an authorization callback that is not
/// guaranteed to be main-actor (a wrong assumption there traps, losing the
/// notification *and* the app). Rendering is instead a few milliseconds of Core
/// Graphics, memoized per project, on a path that runs at most a few times a
/// second — the same path that already performs XPC to `usernotificationsd`.
///
/// Failure degrades: any render or write problem returns an undecorated banner
/// rather than dropping the notification.
enum SupermuxBannerProjectDecorator {
    /// Directory the transient avatar files are written to.
    ///
    /// `UNNotificationAttachment` MOVES the file it is handed into its own
    /// store, so every attachment needs its own disposable copy — a shared
    /// cached path would be consumed by the first banner and missing for the
    /// second. Only the decoded PNG *bytes* are cached; the file is per-banner.
    private static let avatarDirectory: URL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("supermux-notification-avatars", isDirectory: true)

    private static let renderer = SupermuxProjectAvatarRenderer()

    /// Rendered avatar bytes per project, keyed by the identity that produced
    /// them, so repeated notifications from one project rasterize once. A changed
    /// rendered identity adds a new entry; notification volume alone does not.
    @MainActor private static var avatarCache: [AvatarKey: Data] = [:]

    private struct AvatarKey: Hashable {
        let projectID: String
        let colorHex: String?
        let iconSymbol: String?
        let iconETag: String?
        let avatarLetter: String
    }

    /// Decorates `content` in place.
    ///
    /// Takes the project snapshot rather than the notification so the caller can
    /// capture a plain `Sendable` value into the delivery closure instead of the
    /// whole model.
    ///
    /// - Parameters:
    ///   - content: The banner content upstream already built.
    ///   - project: The notification's owning project, or `nil`.
    ///   - tabName: The workspace title, for the provenance subtitle.
    @MainActor
    static func decorate(
        _ content: UNMutableNotificationContent,
        project: SupermuxNotificationProject?,
        tabName: String?
    ) {
        let decoration = SupermuxBannerDecoration.resolve(
            project: project,
            existingSubtitle: content.subtitle,
            tabName: tabName
        )
        if let subtitle = decoration.subtitle {
            content.subtitle = subtitle
        }
        if let threadIdentifier = decoration.threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        guard decoration.rendersAvatar,
              let project,
              let attachment = attachment(for: project) else { return }
        content.attachments = [attachment]
    }

    /// Builds the avatar attachment, or `nil` when it cannot be produced.
    @MainActor
    private static func attachment(
        for project: SupermuxNotificationProject
    ) -> UNNotificationAttachment? {
        guard let data = avatarData(for: project) else { return nil }
        let fileManager = FileManager.default
        let url = avatarDirectory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try fileManager.createDirectory(at: avatarDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        guard let attachment = try? UNNotificationAttachment(
            identifier: "supermux.project.avatar",
            url: url,
            options: nil
        ) else {
            // Nothing took ownership of the file, so clean it up now rather
            // than leaving it for the launch sweep.
            try? fileManager.removeItem(at: url)
            return nil
        }
        return attachment
    }

    /// The project's rendered avatar bytes, memoized.
    @MainActor
    private static func avatarData(for project: SupermuxNotificationProject) -> Data? {
        let uuid = UUID(uuidString: project.id)
        let image = uuid.flatMap { SupermuxComposition.projectIconStore.image(for: $0) }
        let key = AvatarKey(
            projectID: project.id,
            colorHex: project.colorHex,
            iconSymbol: project.iconSymbol,
            // Included so replacing a project's icon file re-renders instead of
            // serving the previous logo forever.
            iconETag: project.iconETag,
            // The generated letter path rasterizes this glyph. A rename that
            // changes the initial must not reuse the old banner chip.
            avatarLetter: project.avatarLetter
        )
        if let cached = avatarCache[key] { return cached }
        guard let data = renderer.pngData(for: project, image: image) else { return nil }
        // Keyed by project identity, so the cache is bounded by the number of
        // registered projects, not by notification volume.
        avatarCache[key] = data
        return data
    }

    /// Removes avatar files left behind by banners that failed to schedule.
    /// Cheap and best-effort; call once at launch.
    static func sweepOrphanedAvatars() {
        let directory = avatarDirectory
        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            let cutoff = Date().addingTimeInterval(-3600)
            for url in urls {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
