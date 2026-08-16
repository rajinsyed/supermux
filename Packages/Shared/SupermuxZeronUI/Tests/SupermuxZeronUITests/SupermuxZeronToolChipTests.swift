//
//  SupermuxZeronToolChipTests.swift
//  SupermuxZeronUITests
//
//  The chip / group / diff geometry, checked against the RENDERED frames rather
//  than against the constants that produced them (plan R4).
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import SupermuxClaudeHarness
@testable import SupermuxZeronUI

@Suite("Zeron tool chips")
@MainActor
struct SupermuxZeronToolChipTests {
    private typealias Chips = SupermuxZeronMetrics.Chips
    private typealias DiffM = SupermuxZeronMetrics.Diff

    // MARK: - Fixtures

    private func exec(
        _ id: String,
        _ command: String,
        result: String? = nil,
        failed: Bool = false
    ) -> SupermuxHarnessToolCall {
        SupermuxHarnessToolCall(
            id: id,
            name: "Bash",
            input: .object(["command": .string(command)]),
            status: failed ? .failed : .succeeded,
            resultText: result
        )
    }

    private func todo(_ id: String) -> SupermuxHarnessToolCall {
        SupermuxHarnessToolCall(
            id: id,
            name: "TodoWrite",
            input: .object([
                "todos": .array([
                    .object(["content": .string("first"), "status": .string("completed")]),
                    .object(["content": .string("second"), "status": .string("pending")]),
                ]),
            ]),
            status: .succeeded
        )
    }

    /// The `s4-details.png` edit: a one-hunk patch over `/w/src/resolve.rs`
    /// with 3 context, 3 deletions, 2 additions and 1 trailing context line.
    private func editWithDiff(_ id: String) -> SupermuxHarnessToolCall {
        let lines: [ClaudeJSONValue] = [
            .string(" "),
            .string(" /// Locate the agent binary."),
            .string(" fn resolve(exe: &str) -> Option<PathBuf> {"),
            .string("-        std::env::var_os(\"PATH\")"),
            .string("-            .map(PathBuf::from)"),
            .string("-            .filter(|p| p.exists())"),
            .string("+        let dirs = std::env::split_paths(&std::env::var_os(\"PATH\")?);"),
            .string("+        dirs.map(|d| d.join(exe)).find(|p| p.exists())"),
            .string(" }"),
        ]
        return SupermuxHarnessToolCall(
            id: id,
            name: "Edit",
            input: .object(["file_path": .string("/w/src/resolve.rs")]),
            status: .succeeded,
            toolUseResult: .object([
                "structuredPatch": .array([
                    .object([
                        "oldStart": .number(2),
                        "newStart": .number(2),
                        "lines": .array(lines),
                    ]),
                ]),
            ])
        )
    }

    private func group(
        _ tools: [SupermuxHarnessToolCall],
        autoOpen: Bool = false
    ) -> SupermuxHarnessToolGroup {
        SupermuxHarnessToolGroup(id: "row#g0", tools: tools, autoOpen: autoOpen)
    }

    private func openFolds(
        group: Bool,
        details: [Bool],
        toggledAt: Date? = nil
    ) -> SupermuxZeronToolGroupFolds {
        SupermuxZeronToolGroupFolds(
            group: SupermuxZeronFold(open: group, epoch: toggledAt == nil ? 0 : 1, toggledAt: toggledAt),
            details: details.map {
                SupermuxZeronFold(open: $0, epoch: toggledAt == nil ? 0 : 1, toggledAt: toggledAt)
            }
        )
    }

    // MARK: - Analytic vs rendered: the chip row

    @Test("A closed chip row paints exactly 38 pt — the rail's segment pitch")
    func closedChipRowIsThirtyEight() throws {
        let tool = exec("t1", "cargo test -p comet-harness")
        let content = SupermuxZeronChipContent(tool: tool)
        #expect(SupermuxZeronToolChip.rowHeight(content: content, isOpen: false) == Chips.rowHeight)

        let view = SupermuxZeronToolChip(
            tool: tool,
            content: content,
            isOpen: false,
            fold: .settled,
            theme: .dark
        )
        #expect(
            SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(Chips.rowHeight),
            "38 − 30 = 8, split 4 pt of rail above and below"
        )
    }

    @Test("A chip's 30 pt card INCLUDES its 1 pt border (§0.3 C9)")
    func cardHeightIncludesItsBorder() throws {
        // The bug this fixes: an auto-height card adds 2 pt of border on top of
        // the 30 pt header, so N chips overflow the group's analytic height by
        // 2N and the last chips clip. `strokeBorder` draws INWARD, so the card
        // stays exactly 30 and the row stays exactly 38.
        let content = SupermuxZeronChipContent(tool: exec("t1", "ls"))
        #expect(content.closedCardHeight == 30)
        #expect(Chips.rowHeight - content.closedCardHeight == 8)

        // Three closed chips must stack to exactly 3 × 38 with no drift.
        let three = group([exec("a", "one"), exec("b", "two"), exec("c", "three")])
        #expect(three.chipsHeight == Chips.chipsHeight(3))
        #expect(three.chipsHeight == 116)
    }

    @Test("An expanded chip's rendered card matches 30 + invocation + detail")
    func expandedChipMatchesItsAnalyticHeight() throws {
        // "cargo test" with 6 output lines: the s4-details.png card 1 shape.
        let tool = exec(
            "t1",
            "cargo test -p comet-harness",
            result: """
                   Compiling comet-harness v0.1.21
                    Finished `dev` profile [unoptimized] in 2.41s
                     Running tests/acp.rs

                running 13 tests
                test result: ok. 13 passed; 0 failed; 0 ignored
                """
        )
        let content = SupermuxZeronChipContent(tool: tool)
        let invocation = try #require(content.invocation)
        let detail = try #require(content.detail)

        // Invocation = the one-line command: 1 + 1×18 + 12 = 31.
        #expect(invocation.height == 31)
        // Output = 6 lines: 1 + 6×18 + 12 = 121, the spec's measured value.
        #expect(detail.height == 121)
        let card1Open: CGFloat = 30 + 31 + 121
        #expect(content.openCardHeight == card1Open)

        let view = SupermuxZeronToolChip(
            tool: tool,
            content: content,
            isOpen: true,
            fold: .settled,
            theme: .dark
        )
        #expect(
            SupermuxZeronRenderProbe.height(of: view)
                .matchesAnalytic(SupermuxZeronToolChip.rowHeight(content: content, isOpen: true)),
            "content must never exceed the analytic box — every body row is a fixed 18 pt line"
        )
    }

    @Test("A 24-line-capped output paints its counted tail inside the box")
    func countedTailFitsTheAnalyticBox() throws {
        let body = (1 ... 40).map { "line \($0)" }.joined(separator: "\n")
        let tool = exec("t1", "seq 40", result: body)
        let detail = try #require(tool.detail)
        guard case .output(let lines, let truncatedBy) = detail else {
            Issue.record("expected an output detail")
            return
        }
        #expect(lines.count == 24)
        #expect(truncatedBy == 16)
        // 24 body rows + 1 tail row.
        let cappedHeight: CGFloat = 1 + 25 * 18 + 12
        #expect(detail.height == cappedHeight)
        #expect(SupermuxZeronChipDetail.countedTailLabel(16) == "\u{2026} 16 more lines")

        let view = SupermuxZeronChipDetail(detail: detail, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view)
                .matchesAnalytic(SupermuxZeronChipDetail.bodyHeight(of: detail)),
            "content cannot exceed the analytic box"
        )
    }

    @Test("A stats body paints one 18 pt row per file and no counted tail")
    func statsBodyHeight() throws {
        let detail = SupermuxHarnessChipDetail.stats([
            SupermuxHarnessDiffStat(path: "a.swift", additions: 4, deletions: 1),
            SupermuxHarnessDiffStat(path: "b.swift", additions: 0, deletions: 9),
        ])
        let statsHeight: CGFloat = 1 + 2 * 18 + 12
        #expect(detail.height == statsHeight)

        let view = SupermuxZeronChipDetail(detail: detail, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view)
                .matchesAnalytic(SupermuxZeronChipDetail.bodyHeight(of: detail)),
            "content cannot exceed the analytic box"
        )
    }

    // MARK: - The group

    @Test("The summary line is the group's own, first character only capitalized")
    func summaryLineRendering() {
        // The s3-group.png header, verbatim.
        let s3 = group([
            exec("a", "cargo test -p comet-harness"),
            SupermuxHarnessToolCall(
                id: "b",
                name: "Edit",
                input: .object(["file_path": .string("/w/src/resolve.rs")]),
                status: .succeeded
            ),
            todo("c"),
        ])
        #expect(s3.summary == "Ran 1 command · edited 1 file · updated todos")

        // A failure is counted, appended LAST, and never reddens the header.
        let failed = group([exec("a", "false", failed: true)])
        #expect(failed.summary == "Ran 1 command · 1 failed")
    }

    @Test("A collapsed group paints exactly its 26 pt header")
    func collapsedGroupIsHeaderOnly() throws {
        let g = group([exec("a", "one"), exec("b", "two"), exec("c", "three")])
        let folds = SupermuxZeronToolGroupFolds.settled(count: 3)
        #expect(
            SupermuxZeronToolGroupView.rowHeight(group: g, folds: folds)
                == Chips.groupHeaderHeight
        )

        let view = SupermuxZeronToolGroupView(group: g, folds: folds, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(Chips.groupHeaderHeight),
            "a closed fold body is 0 pt, not hidden"
        )
    }

    @Test("An open group with 3 closed chips is 26 + 2 + 3×38 = 142")
    func openGroupWithClosedChips() throws {
        let g = group([exec("a", "one"), exec("b", "two"), exec("c", "three")])
        let folds = openFolds(group: true, details: [false, false, false])
        let openHeight: CGFloat = 26 + 116
        #expect(SupermuxZeronToolGroupView.rowHeight(group: g, folds: folds) == openHeight)

        let view = SupermuxZeronToolGroupView(group: g, folds: folds, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(142),
            "26 header + 2 top pad + 3 x 38"
        )
    }

    @Test("s4-details.png: 2 open chips + 1 closed sums to the screenshot's 463")
    func s4DetailsGeometry() throws {
        let run = exec(
            "run",
            "cargo test -p comet-harness",
            result: """
                   Compiling comet-harness v0.1.21
                    Finished `dev` profile [unoptimized] in 2.41s
                     Running tests/acp.rs

                running 13 tests
                test result: ok. 13 passed; 0 failed; 0 ignored
                """
        )
        let edit = editWithDiff("edit")
        let g = group([run, edit, todo("todo")])

        let runContent = SupermuxZeronChipContent(tool: run)
        let editContent = SupermuxZeronChipContent(tool: edit)

        // Spec 03 §8's verified arithmetic. The screenshot predates the
        // invocation feature, so its card-1 interior is 30 + 121 = 151; the
        // shipped source always emits an invocation block, adding 31.
        #expect(try #require(runContent.detail).height == 121)
        let editDetail = try #require(editContent.detail)
        // 1 + (0 notices×24 + 1 hunk×28 + 9 lines×21 + 8) = 226.
        #expect(editDetail.height == 226)

        let folds = openFolds(group: true, details: [true, true, false])
        let expected = Chips.groupHeaderHeight
            + Chips.chipsHeight(3)
            + runContent.expandedExtraHeight
            + editContent.expandedExtraHeight
        #expect(SupermuxZeronToolGroupView.rowHeight(group: g, folds: folds) == expected)

        // Without the invocation blocks this is the screenshot's 26 + 463.
        let screenshotEquivalent = Chips.groupHeaderHeight + Chips.chipsHeight(3) + 121 + 226
        let s4Total: CGFloat = 26 + 463
        #expect(screenshotEquivalent == s4Total)

        let view = SupermuxZeronToolGroupView(group: g, folds: folds, theme: .dark)
        #expect(
            SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(expected),
            "the fold body clips to the analytic height exactly"
        )
    }

    @Test("A Todo chip is a chip, not a card — no separate Todo renderer exists")
    func todoIsAChipWithCheckboxLines() throws {
        let tool = todo("t")
        #expect(tool.chipKind == .todo)
        #expect(tool.chipSubject == "1/2 done")
        #expect(tool.chipKind.icon == .checklist)

        let invocation = try #require(tool.invocationBlock)
        guard case .output(let lines, _) = invocation else {
            Issue.record("a todo's invocation is an output block of checkbox lines")
            return
        }
        #expect(lines == ["[x] first", "[ ] second"])
    }

    @Test("Every chip kind maps to its spec 03 §3.4 glyph, sharing where zeron shares")
    func chipKindIconTable() {
        let expected: [(SupermuxHarnessToolCall.ChipKind, SupermuxZeronIcon.Name)] = [
            (.exec, .command),
            (.readFile, .document),
            (.writeFile, .documentAdd),
            (.editFile, .pen),
            // Patch deliberately shares Read's page glyph.
            (.applyPatch, .document),
            (.search, .magnifer),
            (.glob, .folderWithFiles),
            (.webFetch, .global),
            // Web shares Fetch's globe.
            (.webSearch, .global),
            (.todo, .checklist),
            (.mcp, .widget),
            // Unknown shares MCP's grid.
            (.unknown, .widget),
        ]
        #expect(expected.count == 12, "all twelve kinds are covered")
        for (kind, icon) in expected {
            #expect(kind.icon == icon, "\(kind)")
        }
    }

    @Test("A chip with no bodies is inert: no chevron, no tap, no extra height")
    func inertChipHasNoChevron() {
        // Nothing to show: an empty command yields no invocation and no detail.
        let bare = SupermuxHarnessToolCall(
            id: "bare",
            name: "Bash",
            input: .object(["command": .string("   ")]),
            status: .succeeded
        )
        let content = SupermuxZeronChipContent(tool: bare)
        #expect(content.invocation == nil)
        #expect(content.detail == nil)
        #expect(!content.isExpandable)
        #expect(content.expandedExtraHeight == 0)
        #expect(content.cardHeight(isOpen: true) == Chips.cardHeight)
    }

    @Test("An identical-text diff renders NOTHING, not an empty box")
    func identicalDiffRendersNothing() {
        let tool = SupermuxHarnessToolCall(
            id: "e",
            name: "Edit",
            input: .object(["file_path": .string("/w/a.swift")]),
            status: .succeeded,
            toolUseResult: .object(["structuredPatch": .array([])])
        )
        #expect(SupermuxZeronChipContent(tool: tool).detail == nil)
    }

    // MARK: - Rail geometry

    @Test("Rail geometry: inset 12, width 1, card at 25 — centered under the tile")
    func railGeometry() {
        #expect(Chips.railInset == 12)
        #expect(Chips.railWidth == 1)
        // 12 (rail inset) + 1 (rail) + 12 (card ml) = 25.
        #expect(Chips.cardLeadingInset == Chips.railInset + Chips.railWidth + Chips.railInset)
        #expect(Chips.cardLeadingInset == 25)

        // The header tile spans [4, 22] so its centre is 13; the rail spans
        // [12, 13] so its centre is 12.5. That half-point offset is zeron's.
        let tileCentre = Chips.groupHeaderPadX + Chips.tileSize / 2
        let railCentre = Chips.railInset + Chips.railWidth / 2
        #expect(tileCentre == 13)
        #expect(railCentre == 12.5)
        #expect(abs(tileCentre - railCentre) == 0.5)

        // s3-group.png: content column x0 = 400, rail at 412, card border at
        // 425, column right edge 1136 → card right border 1135.
        let columnX0: CGFloat = 400
        #expect(columnX0 + Chips.railInset == 412)
        #expect(columnX0 + Chips.cardLeadingInset == 425)
        #expect(columnX0 + SupermuxZeronMetrics.Transcript.maxContentWidth == 1136)
    }

    @Test("The rail reads continuous: CHIP_GAP is literally zero")
    func railIsContinuous() {
        #expect(Chips.gap == 0)
        #expect(Chips.topPad == 2)
        // s3-group.png: header bottom 495, rail top 498 — 2 pt of top pad after
        // the 26 pt header ends at 496.
        #expect(Chips.chipsHeight(3) == 116, "3 × 38, matching the measured 114 + the 2 pt pad")
    }

    // MARK: - The fold tween's arming window

    @Test("A fold animates only inside the 400 ms window")
    func foldArmingWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var fold = SupermuxZeronFold()
        #expect(!fold.isArmed(now: start), "an untouched fold is never armed")

        fold.toggle(from: 0, autoOpen: false, at: start)
        #expect(fold.open == true)
        #expect(fold.epoch == 1)
        #expect(fold.isArmed(now: start))
        #expect(fold.isArmed(now: start.addingTimeInterval(0.399)))
        #expect(!fold.isArmed(now: start.addingTimeInterval(0.401)))
        // The scroll-back case the window exists for.
        #expect(!fold.isArmed(now: start.addingTimeInterval(30)))
        // The exact 0.400 instant is deliberately NOT asserted: `Date`
        // arithmetic puts it a fraction of a microsecond either side of the
        // boundary, and it is behaviourally identical anyway — the 200 ms
        // animation finished 200 ms earlier, so an armed-but-complete tween
        // already renders at its target.

        // THE bug this guards: scrolling a row out and back is identity churn,
        // which re-fires `.animation(_:value:)`. Past the window the fold hands
        // SwiftUI no animation at all, so a remount cannot replay it.
        #expect(fold.animation(now: start) != nil)
        #expect(fold.animation(now: start.addingTimeInterval(30)) == nil)
    }

    @Test("The tween is a pure wall-clock read of (from, to, startedAt)")
    func foldTweenInterpolatesEaseOut() {
        let start = Date(timeIntervalSince1970: 2_000)
        var fold = SupermuxZeronFold()
        fold.toggle(from: 0, autoOpen: false, at: start)

        #expect(fold.height(target: 100, now: start) == 0)
        // 200 ms RESIZE on ease-out(0, 0, 0.58, 1).
        let mid = fold.height(target: 100, now: start.addingTimeInterval(0.100))
        let eased = SupermuxZeronCubicBezier.easeOut.eval(0.5)
        // Sub-hundredth-of-a-point: `Date` arithmetic lands the raw progress a
        // few ulps off 0.5, and the curve's ~1.3 slope there amplifies it. The
        // contract is a height in points, not a bit-exact double.
        #expect(abs(mid - CGFloat(eased) * 100) < 0.01)
        #expect(mid > 50, "ease-out is front-loaded: halfway in time is past halfway in space")
        #expect(fold.height(target: 100, now: start.addingTimeInterval(0.200)) == 100)
        // Past the window it is the static target, whatever `from` said.
        #expect(fold.height(target: 100, now: start.addingTimeInterval(5)) == 100)
    }

    @Test("A second tap inside the window restarts the tween rather than resuming")
    func secondTapRestartsTheTween() {
        let start = Date(timeIntervalSince1970: 3_000)
        var fold = SupermuxZeronFold()
        fold.toggle(from: 0, autoOpen: false, at: start)
        let interrupted = start.addingTimeInterval(0.100)
        let midHeight = fold.height(target: 100, now: interrupted)

        fold.toggle(from: midHeight, autoOpen: false, at: interrupted)
        #expect(fold.epoch == 2, "the epoch keys a FRESH animation")
        #expect(fold.open == false)
        #expect(fold.height(target: 0, now: interrupted) == midHeight)
        #expect(fold.isArmed(now: interrupted.addingTimeInterval(0.399)))
    }

    @Test("Content growth after a toggle snaps: the target is always current")
    func contentGrowthDoesNotReplayAStaleTween() {
        let start = Date(timeIntervalSince1970: 4_000)
        var fold = SupermuxZeronFold()
        fold.toggle(from: 0, autoOpen: false, at: start)
        // The group gained a chip mid-tween. `from` is still the click's value,
        // but the destination is whatever the caller passes NOW.
        let grown = fold.height(target: 154, now: start.addingTimeInterval(0.200))
        #expect(grown == 154)
    }

    @Test("Auto-open follows the group until a user pin overrides it forever")
    func autoOpenIsOverriddenByAPin() {
        var fold = SupermuxZeronFold()
        #expect(fold.isOpen(autoOpen: true), "streaming + trailing renders open")
        #expect(!fold.isOpen(autoOpen: false))

        fold.toggle(from: 40, autoOpen: true, at: Date())
        #expect(fold.open == false)
        #expect(!fold.isOpen(autoOpen: true), "the pin wins even while auto-open says open")
    }

    // MARK: - The coupled tween (§6.3)

    @Test("Tapping a chip arms the GROUP tween without changing its open state")
    func chipTapArmsTheGroupTween() {
        let store = SupermuxZeronFoldStore()
        let g = group([exec("a", "one"), exec("b", "two")])
        let now = Date(timeIntervalSince1970: 5_000)

        store.toggleGroup(SupermuxZeronFoldToggle(key: g.id, from: 0, autoOpen: false), at: now)
        #expect(store.fold(g.id).open == true)

        let detailKey = SupermuxZeronFoldStore.detailKey(rowID: g.id, index: 0)
        let tapped = now.addingTimeInterval(1)
        store.toggleDetail(
            SupermuxZeronFoldToggle(key: detailKey, from: 30, autoOpen: false),
            armGroup: SupermuxZeronFoldToggle(key: g.id, from: 78, autoOpen: false),
            at: tapped
        )

        let groupFold = store.fold(g.id)
        #expect(groupFold.open == true, "the group's OPEN state is untouched")
        #expect(groupFold.from == 78, "…but its tween starts from the pre-tap height")
        #expect(groupFold.isArmed(now: tapped))
        #expect(store.fold(detailKey).open == true)
        // Both tweens share the instant, so the row tracks the card's bottom
        // edge frame-for-frame.
        #expect(store.fold(detailKey).toggledAt == groupFold.toggledAt)
    }

    @Test("The static row height and the painted body agree for every fold state")
    func staticHeightMatchesThePaintedBody() throws {
        let tools = [
            exec("run", "cargo build", result: "one\ntwo\nthree"),
            editWithDiff("edit"),
            todo("todo"),
        ]
        let g = group(tools)

        // All 2³ detail combinations × open/closed group. The static height is
        // what a host uses to pre-size a row; the painted body is what the user
        // sees. A disagreement here IS a clipped last chip.
        for mask in 0 ..< 8 {
            let details = (0 ..< 3).map { mask & (1 << $0) != 0 }
            for groupOpen in [false, true] {
                let folds = openFolds(group: groupOpen, details: details)
                let view = SupermuxZeronToolGroupView(group: g, folds: folds, theme: .dark)
                let expected = SupermuxZeronToolGroupView.rowHeight(group: g, folds: folds)
                #expect(
                    SupermuxZeronRenderProbe.height(of: view).matchesAnalytic(expected),
                    "groupOpen=\(groupOpen) details=\(details)"
                )
            }
        }
    }

    @Test("A closed group's height ignores its chips' detail folds entirely")
    func closedGroupIgnoresChipFolds() {
        let g = group([exec("a", "x", result: "long\noutput\nhere"), editWithDiff("b")])
        let allOpen = openFolds(group: false, details: [true, true])
        #expect(
            SupermuxZeronToolGroupView.rowHeight(group: g, folds: allOpen)
                == Chips.groupHeaderHeight,
            "a collapsed fold body is 0 pt regardless of what is open inside it"
        )
    }

    @Test("A very long diff line does not blow up the row's ideal width")
    func longDiffLineDoesNotWidenTheRow() throws {
        // `.fixedSize(horizontal:)` is what suppresses the ellipsis on a diff
        // line, but it also reports the line's FULL intrinsic width upward. A
        // transcript row that sizes to `fittingSize` would honour it, giving a
        // chat pane thousands of points wide for one long line.
        func body(_ characters: Int) -> SupermuxZeronDiffBody {
            let line = SupermuxHarnessDiff.Line(
                id: "a",
                kind: .addition,
                oldNumber: nil,
                newNumber: 1,
                text: String(repeating: "x", count: characters)
            )
            let hunk = SupermuxHarnessDiff.Hunk(
                id: "h", oldStart: 1, newStart: 1, lines: [line], isSynthetic: false
            )
            return SupermuxZeronDiffBody(diff: SupermuxHarnessDiff(hunks: [hunk]), theme: .dark)
        }

        let short = try #require(SupermuxZeronRenderProbe.idealWidth(of: body(10)))
        let long = try #require(SupermuxZeronRenderProbe.idealWidth(of: body(400)))
        #expect(long == short, "a 400-char line must not ask for more width than a 10-char one")

        // …and the height stays analytic at every width, including absurd ones.
        for width in [300, 120, 60] as [CGFloat] {
            #expect(
                SupermuxZeronRenderProbe.height(of: body(400), width: width)
                    .matchesAnalytic(DiffM.lineHeight + DiffM.hunkHeaderHeight + DiffM.bodyBottomPad),
                "width=\(width)"
            )
        }
    }

    @Test("Reduced motion snaps the fold instead of tweening it")
    func reducedMotionSnapsTheFold() {
        // gpui honors `App::reduce_motion` inside every `with_animation`
        // automatically, so zeron's fold path never mentions the flag and still
        // snaps. SwiftUI has no such automatic honoring — a port that omits the
        // gate animates where zeron does not (spec 07 §6). The group threads
        // ONE decision down to every card so the coupled tween cannot animate
        // on one half and snap on the other.
        let tool = exec("a", "one", result: "out")
        let content = SupermuxZeronChipContent(tool: tool)
        let armed = SupermuxZeronFold(open: true, epoch: 1, from: 30, toggledAt: Date())
        for reduced in [false, true] {
            let chip = SupermuxZeronToolChip(
                tool: tool,
                content: content,
                isOpen: true,
                fold: armed,
                reduceMotion: reduced,
                theme: .dark
            )
            #expect(
                SupermuxZeronRenderProbe.height(of: chip)
                    .matchesAnalytic(SupermuxZeronToolChip.rowHeight(content: content, isOpen: true)),
                "reduceMotion=\(reduced) must still land on the analytic height"
            )
        }
        // The armed window itself is unchanged — reduced motion suppresses the
        // ANIMATION, it does not un-arm the fold or change the destination.
        #expect(armed.isArmed(now: Date()))
    }

    @Test("A loading blob affordance is inert — no tap, no button trait")
    func loadingAffordanceIsInert() {
        let ready = SupermuxZeronBlobAffordance(id: "b", kind: .output, state: .ready(byteCount: 2048))
        let loading = SupermuxZeronBlobAffordance(id: "b", kind: .output, state: .loading)
        let failed = SupermuxZeronBlobAffordance(id: "b", kind: .output, state: .failed)
        #expect(ready.isInteractive)
        #expect(!loading.isInteractive, "zeron attaches no cursor, no hover and no on_click while loading")
        #expect(failed.isInteractive, "a failed fetch stays tappable to retry")
        // The size label rounds UP to whole KB, and switches unit at 1024.
        #expect(SupermuxZeronBlobAffordance.formatBytes(1023).contains("1023"))
        #expect(SupermuxZeronBlobAffordance.formatBytes(1025).contains("2"))
    }

    @Test("The store snapshots a group's folds index-aligned with its tools")
    func storeSnapshotsAGroup() {
        let store = SupermuxZeronFoldStore()
        let g = group([exec("a", "one"), exec("b", "two"), exec("c", "three")])
        let snapshot = store.folds(for: g)
        #expect(snapshot.details.count == 3)
        #expect(snapshot.group == .settled)
        // A group that grew a chip since the snapshot still resolves.
        #expect(snapshot.detail(9) == .settled)
    }
}
