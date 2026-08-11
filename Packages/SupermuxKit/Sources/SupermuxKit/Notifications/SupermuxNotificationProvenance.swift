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
        line(segments: [projectName, tabName, surfaceName])
    }

    /// Composes a provenance line from an ordered list of candidate segments.
    ///
    /// The general form behind ``line(projectName:tabName:surfaceName:)``: rows
    /// differ in WHICH facts end up on the secondary line (a row whose headline
    /// is already the workspace name puts the notification's own title there
    /// instead), but they must never differ in how segments are trimmed,
    /// de-duplicated, or joined — that is what makes two surfaces look like two
    /// different apps.
    ///
    /// - Parameter segments: Candidates in display order; `nil` and blank
    ///   entries are skipped, and any entry restating an earlier one is dropped.
    /// - Returns: The composed line, or `nil` when nothing is worth showing.
    public static func line(segments: [String?]) -> String? {
        let accepted = accepted(segments)
        guard !accepted.isEmpty else { return nil }
        return accepted.joined(separator: separator)
    }

    /// The segments ``line(segments:)`` would join, before joining them.
    ///
    /// Exposed because a caller sometimes needs to drop a leading segment it
    /// only supplied to seed the de-duplication (a row measures the project and
    /// title against its own headline, then renders the rest). Splitting the
    /// joined string back apart would be wrong: a workspace title may itself
    /// contain the separator.
    ///
    /// - Parameter segments: Candidates in display order.
    /// - Returns: Trimmed, de-duplicated segments; empty when nothing survives.
    public static func accepted(_ segments: [String?]) -> [String] {
        var accepted: [String] = []
        for candidate in segments {
            guard let normalized = normalized(candidate) else { continue }
            // Compare against everything already accepted, not just the
            // previous segment: a pane named after the project (with the tab
            // named something else in between) is just as redundant.
            guard !accepted.contains(where: { matches($0, normalized) }) else { continue }
            accepted.append(normalized)
        }
        return accepted
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
