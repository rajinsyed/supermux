import Testing

@testable import SupermuxKit

struct SupermuxChangesRowSelectionTests {
    private let change = SupermuxGitFileChange(path: "src/main.swift", oldPath: nil, kind: .modified)

    @Test func theStagedAndUnstagedRowsOfOneFileAreDistinctSelections() {
        #expect(
            SupermuxChangesRowSelection(change, staged: true)
                != SupermuxChangesRowSelection(change, staged: false)
        )
    }

    @Test func theSameRowClickedTwiceIsOneSelection() {
        #expect(
            SupermuxChangesRowSelection(change, staged: false)
                == SupermuxChangesRowSelection(change, staged: false)
        )
    }
}
