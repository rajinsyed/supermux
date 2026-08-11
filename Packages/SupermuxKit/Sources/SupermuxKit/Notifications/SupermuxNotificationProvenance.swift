public import Foundation
public import SupermuxMobileCore

/// Builds the one-line "where did this come from" string every notification
/// surface shows under the title: the project, then the tab it fired in.
///
/// One implementation, four consumers (macOS banner subtitle, macOS panel row,
/// iOS feed row, APNs push subtitle) — because the moment each surface composes
/// its own, they disagree about separators, about what to drop when a field is
/// missing, and about what to do when the tab name merely repeats the project
/// name. All of that is decided here once.
///
/// Pure value logic with no UI dependency, so it is unit-testable and usable
/// from a notification service extension.
public enum SupermuxNotificationProvenance: Sendable {
    /// The separator between provenance segments: a thin-space-padded middle
    /// dot, the same divider the sidebar and usage popover use.
    public static let separator = " · "

    /// Composes the provenance line.
    ///
    /// Segments are dropped when empty, and a segment that merely restates the
    /// one before it is dropped too — a workspace named after its repo is the
    /// common case, and "supermux · supermux" is noise, not information.
    ///
    /// - Parameters:
    ///   - projectName: The owning project's name, or `nil` when the workspace
    ///     belongs to no project.
    ///   - tabName: The workspace/tab title, when known.
    ///   - surfaceName: The pane/terminal title, when it adds anything.
    /// - Returns: The composed line, or `nil` when nothing is worth showing.
    public static func line(
        projectName: String?,
        tabName: String?,
        surfaceName: String? = nil
    ) -> String? {
        var segments: [String] = []
        for candidate in [projectName, tabName, surfaceName] {
            guard let normalized = normalized(candidate) else { continue }
            // Compare against everything already accepted, not just the
            // previous segment: a pane named after the project (with the tab
            // named something else in between) is just as redundant.
            guard !segments.contains(where: { matches($0, normalized) }) else { continue }
            segments.append(normalized)
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: separator)
    }

    /// Trims a candidate segment, returning `nil` for blank input.
    public static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Whether two segments say the same thing, ignoring case, diacritics, and
    /// internal whitespace runs.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
