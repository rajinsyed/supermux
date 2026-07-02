import Foundation
import SupermuxKit
import Testing

/// Unit tests for `SupermuxWorkspaceSwitcherItem.terminalPreviewLines`: the pure
/// cleanup that turns raw terminal viewport text into the compact mini-terminal
/// preview lines shown on each switcher card.
struct SupermuxWorkspaceSwitcherPreviewTests {
    private func lines(_ text: String, maxLines: Int = 8, maxLineLength: Int = 240) -> [String] {
        SupermuxWorkspaceSwitcherItem.terminalPreviewLines(
            fromViewport: text, maxLines: maxLines, maxLineLength: maxLineLength
        )
    }

    @Test func emptyTextYieldsNoLines() {
        #expect(lines("") == [])
    }

    @Test func whitespaceOnlyYieldsNoLines() {
        #expect(lines("   \n\t\n  \n") == [])
    }

    @Test func dropsTrailingBlankLinesSoPromptAnchorsTheBottom() {
        #expect(lines("$ ls\nfile.txt\n$ \n\n\n") == ["$ ls", "file.txt", "$ "])
    }

    @Test func keepsOnlyTheLastMaxLines() {
        let input = (1...20).map { "line \($0)" }.joined(separator: "\n")
        #expect(lines(input, maxLines: 3) == ["line 18", "line 19", "line 20"])
    }

    @Test func preservesInteriorBlankLines() {
        #expect(lines("a\n\nb") == ["a", "", "b"])
    }

    @Test func expandsTabsToSpaces() {
        #expect(lines("a\tb") == ["a  b"])
    }

    @Test func stripsCarriageReturns() {
        #expect(lines("a\r\nb\r\n") == ["a", "b"])
    }

    @Test func capsLineLength() {
        let long = String(repeating: "x", count: 500)
        let result = lines(long, maxLineLength: 240)
        #expect(result.count == 1)
        #expect(result[0].count == 240)
    }

    @Test func withPreviewLinesReplacesOnlyThePreview() {
        let item = SupermuxWorkspaceSwitcherItem(
            id: UUID(),
            title: "build",
            subtitle: "main",
            accentColorHex: "#FF0000",
            iconSymbol: "hammer",
            monogram: "B",
            projectId: UUID(),
            projectName: "cmux",
            isCurrent: true,
            previewLines: [],
            activity: .working
        )
        let filled = item.withPreviewLines(["$ make", "ok"])
        #expect(filled.previewLines == ["$ make", "ok"])
        #expect(filled.id == item.id)
        #expect(filled.title == item.title)
        #expect(filled.subtitle == item.subtitle)
        #expect(filled.accentColorHex == item.accentColorHex)
        #expect(filled.iconSymbol == item.iconSymbol)
        #expect(filled.monogram == item.monogram)
        #expect(filled.projectId == item.projectId)
        #expect(filled.projectName == item.projectName)
        #expect(filled.isCurrent == item.isCurrent)
        #expect(filled.activity == item.activity)
    }
}
