//
//  SupermuxZeronChipMetricParityTests.swift
//  SupermuxZeronUITests
//
//  Two chip-metric tables exist and they are NOT linked:
//
//    * `SupermuxHarnessChipMetrics` — in the DATA layer
//      (`Packages/Shared/SupermuxClaudeHarness/.../Rows/SupermuxHarnessToolGroup.swift`),
//      so `SupermuxHarnessToolGroup.chipsHeight` and
//      `SupermuxHarnessChipDetail.height` stay analytic without the row model
//      depending on the UI package.
//    * `SupermuxZeronMetrics.Chips` / `.Diff` — in the UI layer, the plan's
//      §1.4 constant table.
//
//  They agree today, by hand. Nothing tested that, and the failure is silent
//  and severe: the DATA layer computes the fold's target height and the UI
//  layer paints the rows, so a one-point drift between them means every open
//  tool group clips its last chip — the exact "tool calls cut off at the bottom"
//  bug §0.3 C9 exists to prevent, reintroduced from the other side.
//
//  The right long-term fix is to delete one table. Until the data layer can
//  import the design system (it deliberately cannot — the dependency runs the
//  other way), this suite is the link.
//

import CoreGraphics
import Testing

@testable import SupermuxClaudeHarness
@testable import SupermuxZeronUI

@Suite("Chip metric table parity")
struct SupermuxZeronChipMetricParityTests {
    private typealias Data = SupermuxHarnessChipMetrics
    private typealias UI = SupermuxZeronMetrics.Chips
    private typealias UIDiff = SupermuxZeronMetrics.Diff

    @Test("Every shared chip constant is identical in both tables")
    func chipConstantsAgree() {
        #expect(Data.rowHeight == UI.rowHeight, "the 38 pt row / rail segment pitch")
        #expect(Data.rowGap == UI.gap, "0 — rows stack flush so the rail reads continuous")
        #expect(Data.chipsTopPad == UI.topPad)
        #expect(Data.outputLineHeight == UI.outputLineHeight)
        #expect(Data.outputBodyPad == UI.outputBodyPad, "py 6 × 2")
        #expect(Data.detailSeparator == UI.detailSeparator)
        #expect(Data.outputMaxLines == UI.outputMaxLines)
        #expect(Data.callWrapColumns == UI.callWrapCols)
        #expect(Data.diffMaxLines == UI.diffMaxLines)
    }

    @Test("Every shared diff constant is identical in both tables")
    func diffConstantsAgree() {
        #expect(Data.diffLineHeight == UIDiff.lineHeight)
        #expect(Data.hunkHeaderHeight == UIDiff.hunkHeaderHeight)
        #expect(Data.noticeHeight == UIDiff.noticeHeight)
        #expect(Data.diffBodyBottomPad == UIDiff.bodyBottomPad)
    }

    @Test("chipsHeight agrees across the layers for every group size")
    func chipsHeightAgrees() {
        for count in 0 ... 32 {
            let tools = (0 ..< count).map {
                SupermuxHarnessToolCall(
                    id: "t\($0)", name: "Bash", input: .object([:]), status: .succeeded
                )
            }
            let group = SupermuxHarnessToolGroup(id: "g", tools: tools)
            #expect(
                group.chipsHeight == UI.chipsHeight(count),
                "count=\(count): the data layer computes the fold target the UI paints"
            )
        }
    }

    @Test("Detail heights agree across the layers")
    func detailHeightsAgree() {
        // Output, with and without a counted tail.
        let plain = SupermuxHarnessChipDetail.output(lines: ["a", "b", "c"], truncatedBy: 0)
        #expect(plain.height == UI.lineDetailHeight(lines: 3))

        let truncated = SupermuxHarnessChipDetail.output(
            lines: (0 ..< 24).map(String.init), truncatedBy: 7
        )
        #expect(truncated.height == UI.lineDetailHeight(lines: 24, extraRows: 1))

        // Stats — same shell, and never a counted tail.
        let stats = SupermuxHarnessChipDetail.stats([
            SupermuxHarnessDiffStat(path: "a", additions: 1, deletions: 0),
            SupermuxHarnessDiffStat(path: "b", additions: 0, deletions: 2),
        ])
        #expect(stats.height == UI.lineDetailHeight(lines: 2))

        // Diff.
        let diff = SupermuxHarnessDiff(
            hunks: [
                SupermuxHarnessDiff.Hunk(
                    id: "h",
                    oldStart: 1,
                    newStart: 1,
                    lines: (0 ..< 9).map {
                        SupermuxHarnessDiff.Line(
                            id: "l\($0)",
                            kind: .context,
                            oldNumber: $0 + 1,
                            newNumber: $0 + 1,
                            text: "x"
                        )
                    },
                    isSynthetic: false
                ),
            ],
            notices: ["New file"]
        )
        let detail = SupermuxHarnessChipDetail.diff(diff)
        #expect(detail.height == UIDiff.detailHeight(notices: 1, hunks: 1, lines: 9))
        // …and the UI's own painted-body accessor is that minus the separator.
        #expect(
            SupermuxZeronDiffBody.bodyHeight(of: diff) == detail.height - UI.detailSeparator
        )
        #expect(SupermuxZeronChipDetail.bodyHeight(of: detail) == detail.height - UI.detailSeparator)
    }

    @Test("Both tables are pinned to the SPEC literals, not to each other")
    func bothTablesMatchTheSpec() {
        // Equality alone would pass if both tables drifted the same way. These
        // are spec 03 §9 / spec 06 §2 verbatim, so a coordinated edit still
        // fails here.
        #expect(Data.rowHeight == 38 && UI.rowHeight == 38)
        #expect(Data.rowGap == 0 && UI.gap == 0)
        #expect(Data.chipsTopPad == 2 && UI.topPad == 2)
        #expect(Data.outputLineHeight == 18 && UI.outputLineHeight == 18)
        #expect(Data.outputBodyPad == 12 && UI.outputBodyPad == 12)
        #expect(Data.detailSeparator == 1 && UI.detailSeparator == 1)
        #expect(Data.outputMaxLines == 24 && UI.outputMaxLines == 24)
        #expect(Data.callWrapColumns == 80 && UI.callWrapCols == 80)
        #expect(Data.diffMaxLines == 600 && UI.diffMaxLines == 600)
        #expect(Data.diffLineHeight == 21 && UIDiff.lineHeight == 21)
        #expect(Data.hunkHeaderHeight == 28 && UIDiff.hunkHeaderHeight == 28)
        #expect(Data.noticeHeight == 24 && UIDiff.noticeHeight == 24)
        #expect(Data.diffBodyBottomPad == 8 && UIDiff.bodyBottomPad == 8)

        // The card height lives ONLY in the UI table — the data layer never
        // needs it, because the row pitch is what its analytic heights use.
        #expect(UI.cardHeight == 30, "§0.3 C9: 30 INCLUDING the 1 pt border")
        #expect(UI.rowHeight - UI.cardHeight == 8)
    }
}
