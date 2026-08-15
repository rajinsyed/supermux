import Foundation

/// Consecutive tool invocations, collapsed into one railed transcript row.
///
/// A lone call is a group of one. Modelling it that way — rather than as a
/// second, flatter row kind — is what lets the guide rail, the summary line and
/// the analytic `2 + 38N` height share one implementation.
public struct SupermuxHarnessToolGroup: Sendable, Equatable, Identifiable {
    /// `"{entryID}#g{groupIndex}"`.
    public let id: String
    public var tools: [SupermuxHarnessToolCall]
    /// True only while the message streams AND this group is its last part.
    ///
    /// A trailing group auto-expands mid-run so the user watches the work, and
    /// collapses again when the turn completes.
    public var autoOpen: Bool

    public init(id: String, tools: [SupermuxHarnessToolCall], autoOpen: Bool = false) {
        self.id = id
        self.tools = tools
        self.autoOpen = autoOpen
    }

    /// The one-line tally, e.g. `"Ran 3 commands · edited 2 files · 1 failed"`.
    public var summary: String {
        SupermuxHarnessToolGroupSummary.summary(for: tools)
    }

    /// The expanded chip stack's height — analytic, never measured, so a fold
    /// tween interpolates two known numbers instead of waiting for layout.
    public var chipsHeight: CGFloat {
        tools.isEmpty ? 0 : SupermuxHarnessChipMetrics.chipsTopPad
            + CGFloat(tools.count) * SupermuxHarnessChipMetrics.rowHeight
    }
}

/// Chip geometry the row model itself needs, so heights stay analytic without
/// the data layer depending on the UI package.
/// lint:allow namespace-enum, namespace-type — chip geometry the row model needs to stay analytic without depending on the UI package.
public enum SupermuxHarnessChipMetrics {
    /// The chip row's pitch. The 30 pt card is centered inside it.
    public static let rowHeight: CGFloat = 38
    /// Rows stack with no gap; the breathing room is the card's own inset.
    public static let rowGap: CGFloat = 0
    public static let chipsTopPad: CGFloat = 2
    /// One line of a mono detail body.
    public static let outputLineHeight: CGFloat = 18
    /// A detail body's vertical padding (6 pt top + 6 pt bottom).
    public static let outputBodyPad: CGFloat = 12
    /// The hairline between a chip's header row and a detail body.
    public static let detailSeparator: CGFloat = 1
    /// Verbatim output lines per detail before the counted tail row.
    public static let outputMaxLines = 24
    /// Columns an invocation line hard-wraps at. Char-counted, not measured —
    /// block heights must be analytic.
    public static let callWrapColumns = 80
    /// Lines an inline tool diff renders before the truncation notice.
    public static let diffMaxLines = 600
    public static let diffLineHeight: CGFloat = 21
    public static let hunkHeaderHeight: CGFloat = 28
    public static let noticeHeight: CGFloat = 24
    public static let diffBodyBottomPad: CGFloat = 8
}

/// The group summary line.
///
/// Seven ordered slots joined `" · "`, then a fallback when nothing matched,
/// then the failure count — always last. Only the FIRST character of the whole
/// joined string is uppercased, which is why every segment is authored in lower
/// case. Ported from zeron's `tool_group_summary`
/// (`crates/proto/src/view.rs`) so both products name a turn identically.
///
/// lint:allow namespace-type — pure formatting rule; nothing to inject.
public enum SupermuxHarnessToolGroupSummary {
    public static func summary(for tools: [SupermuxHarnessToolCall]) -> String {
        var commands = 0
        /// Deduped by exact path string: editing one file twice counts once.
        var edited: [String] = []
        var reads = 0
        var searches = 0
        var fetches = 0
        var todos = 0
        var other = 0
        var failed = 0

        for tool in tools {
            if tool.status == .failed { failed += 1 }
            switch tool.chipKind {
            case .exec:
                commands += 1
            case .writeFile, .editFile, .applyPatch:
                let path = tool.editedPathForSummary
                if !edited.contains(path) { edited.append(path) }
            case .readFile:
                reads += 1
            case .search, .glob, .webSearch:
                searches += 1
            case .webFetch:
                fetches += 1
            case .todo:
                todos += 1
            case .mcp, .unknown:
                other += 1
            }
        }

        var segments: [String] = []
        if commands > 0 { segments.append(ran(commands)) }
        if !edited.isEmpty { segments.append(self.edited(edited.count)) }
        if reads > 0 { segments.append(read(reads)) }
        if searches > 0 { segments.append(searched(searches)) }
        if fetches > 0 { segments.append(fetched(fetches)) }
        if todos > 0 { segments.append(updatedTodos) }
        if other > 0 { segments.append(called(other)) }
        // No slot matched at all: fall back to a bare tool count.
        if segments.isEmpty { segments.append(toolCount(tools.count)) }
        if failed > 0 { segments.append(self.failed(failed)) }

        let joined = segments.joined(separator: " · ")
        guard let first = joined.first else { return joined }
        return String(first).uppercased() + joined.dropFirst()
    }

    // MARK: - Segments
    //
    // Each slot is one localized format so a translation can reorder the count
    // inside its own phrase; the slot ORDER and the separator are structural.

    private static func ran(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.ran.one",
                defaultValue: "ran %lld command"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.ran.other",
                defaultValue: "ran %lld commands"
            )
        )
    }

    private static func edited(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.edited.one",
                defaultValue: "edited %lld file"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.edited.other",
                defaultValue: "edited %lld files"
            )
        )
    }

    private static func read(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.read.one",
                defaultValue: "read %lld file"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.read.other",
                defaultValue: "read %lld files"
            )
        )
    }

    private static func searched(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.searched.one",
                defaultValue: "searched %lld time"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.searched.other",
                defaultValue: "searched %lld times"
            )
        )
    }

    private static func fetched(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.fetched.one",
                defaultValue: "fetched %lld page"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.fetched.other",
                defaultValue: "fetched %lld pages"
            )
        )
    }

    /// Never pluralized — the tally is "the to-do list changed", not a count.
    private static var updatedTodos: String {
        String(
            localized: "supermux.harness.toolGroup.updatedTodos",
            defaultValue: "updated todos"
        )
    }

    private static func called(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.called.one",
                defaultValue: "called %lld tool"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.called.other",
                defaultValue: "called %lld tools"
            )
        )
    }

    private static func toolCount(_ n: Int) -> String {
        format(
            n,
            one: String(
                localized: "supermux.harness.toolGroup.tools.one",
                defaultValue: "%lld tool"
            ),
            other: String(
                localized: "supermux.harness.toolGroup.tools.other",
                defaultValue: "%lld tools"
            )
        )
    }

    private static func failed(_ n: Int) -> String {
        String(
            format: String(
                localized: "supermux.harness.toolGroup.failed",
                defaultValue: "%lld failed"
            ),
            Int64(n)
        )
    }

    private static func format(_ n: Int, one: String, other: String) -> String {
        String(format: n == 1 ? one : other, Int64(n))
    }
}

private extension SupermuxHarnessToolCall {
    /// The dedupe key of an edit slot.
    ///
    /// A patch that names no file counts as the literal `"patch"` — one
    /// unnamed patch, not one per call — which is deliberately *not* the
    /// chip's `"workspace"` subject.
    var editedPathForSummary: String {
        if chipKind == .applyPatch, subject == nil { return "patch" }
        return subject ?? name
    }
}
