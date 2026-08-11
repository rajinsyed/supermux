public import Foundation

/// Decides what goes on each line of a notification row.
///
/// This exists because there are two rows. The notifications **panel** and the
/// titlebar **popover** list the same notifications from the same store, and
/// before this each composed its own lines — so they disagreed about whether the
/// headline was the workspace or the notification's title, and a redesign of one
/// left the other untouched. Under the fork's shared-behavior rule a behavior
/// with several entrypoints gets one implementation; this is it for the row's
/// content, as ``SupermuxNotificationRowBody`` is for its layout.
///
/// Pure string logic with no UI dependency, so it is unit-testable here rather
/// than only through a rendered view.
public enum SupermuxNotificationRowPresentation: Sendable {
    /// The row's primary line: the workspace it fired in when known, otherwise
    /// the notification's own title.
    ///
    /// The workspace wins because it answers "where do I go" — the question a
    /// notification list exists to answer — and because one agent's title
    /// ("Claude Code") repeats down every row while the workspace does not.
    ///
    /// - Parameters:
    ///   - title: The notification's title.
    ///   - tabName: The workspace/tab title, when known.
    /// - Returns: The headline to render.
    public static func headline(title: String, tabName: String?) -> String {
        SupermuxNotificationProvenance.normalized(tabName) ?? title
    }

    /// The secondary line: the project, then the notification's own title when
    /// the headline did not already say it.
    ///
    /// - Parameters:
    ///   - projectName: The owning project's name, or `nil` when the row sits
    ///     under a project section header that already shows it.
    ///   - title: The notification's title.
    ///   - headline: The row's primary line.
    /// - Returns: The line, or `nil` when every segment would restate something
    ///   already on screen.
    public static func provenance(
        projectName: String?,
        title: String,
        headline: String
    ) -> String? {
        // The headline goes in as the FIRST segment purely so the shared
        // de-duplication measures the others against it — a workspace named
        // after its project must not yield "supermux · supermux". It is then
        // dropped, because it is already rendered on the line above.
        //
        // Dropped from the SEGMENTS, never by splitting the joined string: a
        // workspace title may itself contain the separator.
        let rest = SupermuxNotificationProvenance
            .accepted([headline, projectName, title])
            .dropFirst()
        guard !rest.isEmpty else { return nil }
        return rest.joined(separator: SupermuxNotificationProvenance.separator)
    }

    /// The message preview: the body, or the subtitle when the body adds
    /// nothing. The subtitle was carried end-to-end but rendered nowhere in the
    /// app before the redesign.
    ///
    /// - Parameters:
    ///   - body: The notification's body.
    ///   - subtitle: The notification's subtitle.
    ///   - redundant: Lines already on screen, which the preview must not repeat.
    /// - Returns: The preview, or `nil` when nothing adds information.
    public static func preview(
        body: String?,
        subtitle: String?,
        redundant: [String?]
    ) -> String? {
        let shown = redundant.compactMap { SupermuxNotificationProvenance.normalized($0) }
        for candidate in [body, subtitle] {
            guard let normalized = SupermuxNotificationProvenance.normalized(candidate) else {
                continue
            }
            guard !shown.contains(where: { SupermuxNotificationProvenance.matches(normalized, $0) })
            else { continue }
            return normalized
        }
        return nil
    }
}
