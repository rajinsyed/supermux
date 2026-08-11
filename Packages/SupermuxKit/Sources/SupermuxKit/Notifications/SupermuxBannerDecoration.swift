public import Foundation
public import SupermuxMobileCore

/// The project-derived additions a macOS notification banner carries, computed
/// as a value so the decision is testable without UserNotifications.
///
/// Split from the code that applies it because the interesting part is the
/// policy — what the subtitle should say, when to group, whether an avatar is
/// worth rendering — and that policy should be assertable in a unit test rather
/// than only observable by squinting at a real banner.
public struct SupermuxBannerDecoration: Sendable, Equatable {
    /// The provenance line for the banner's subtitle (`project · tab`), or
    /// `nil` to leave whatever subtitle the notification already carried.
    public let subtitle: String?
    /// The banner's `threadIdentifier`, which is what makes macOS stack a
    /// project's notifications into one group in Notification Center instead of
    /// scattering them among every other workspace's.
    public let threadIdentifier: String?
    /// Whether a project avatar should be rendered and attached.
    public let rendersAvatar: Bool

    /// Creates a decoration.
    /// - Parameters:
    ///   - subtitle: The provenance line, or `nil`.
    ///   - threadIdentifier: The grouping key, or `nil`.
    ///   - rendersAvatar: Whether to render and attach an avatar.
    public init(subtitle: String?, threadIdentifier: String?, rendersAvatar: Bool) {
        self.subtitle = subtitle
        self.threadIdentifier = threadIdentifier
        self.rendersAvatar = rendersAvatar
    }

    /// The no-op decoration: what a project-less notification gets, leaving the
    /// banner exactly as upstream built it.
    public static let none = SupermuxBannerDecoration(
        subtitle: nil,
        threadIdentifier: nil,
        rendersAvatar: false
    )

    /// Decides how to decorate one notification's banner.
    ///
    /// - Parameters:
    ///   - project: The notification's owning project, or `nil`.
    ///   - existingSubtitle: The subtitle the notification already carries.
    ///     A subtitle the agent explicitly set is content and is never
    ///     overwritten; provenance only fills an empty one.
    ///   - tabName: The workspace title, when known.
    /// - Returns: The decoration to apply.
    public static func resolve(
        project: SupermuxNotificationProject?,
        existingSubtitle: String,
        tabName: String?
    ) -> SupermuxBannerDecoration {
        guard let project else {
            // No project: still worth naming the tab, since "which of my twelve
            // terminals was that?" is the question a bare banner never answers.
            guard SupermuxNotificationProvenance.normalized(existingSubtitle) == nil,
                  let line = SupermuxNotificationProvenance.line(
                      projectName: nil, tabName: tabName
                  ) else { return .none }
            return SupermuxBannerDecoration(
                subtitle: line,
                threadIdentifier: nil,
                rendersAvatar: false
            )
        }

        let subtitle: String?
        if SupermuxNotificationProvenance.normalized(existingSubtitle) == nil {
            subtitle = SupermuxNotificationProvenance.line(
                projectName: project.name,
                tabName: tabName
            )
        } else {
            subtitle = nil
        }

        return SupermuxBannerDecoration(
            // Namespaced so a project id can never collide with a thread
            // identifier some other part of cmux sets.
            subtitle: subtitle,
            threadIdentifier: "supermux.project.\(project.id)",
            rendersAvatar: true
        )
    }
}
