import Testing
@testable import SupermuxZeronUI

/// The slash menu's trigger rule, filter + ranking, and keyboard model.
struct SupermuxZeronSlashMenuTests {
    typealias State = SupermuxZeronSlashState

    private let commands = [
        SupermuxZeronSlashCommand(name: "compact", description: "Compact the session"),
        SupermuxZeronSlashCommand(name: "goal", description: "Set a goal", inputHint: "the goal"),
        SupermuxZeronSlashCommand(name: "clear", description: "Clear the transcript"),
        SupermuxZeronSlashCommand(name: "recompact"),
    ]

    // MARK: - The trigger rule

    @Test("the slash must be at offset 0 — a mid-prompt slash never opens the menu")
    func triggerRequiresPrefix() {
        #expect(State.token(in: "/comp", caret: 5) != nil)
        #expect(State.token(in: "fix /comp", caret: 9) == nil)
        #expect(State.token(in: " /comp", caret: 6) == nil)
        #expect(State.token(in: "", caret: 0) == nil)
        // The caret at offset 0 is BEFORE the slash: nothing to complete.
        #expect(State.token(in: "/comp", caret: 0) == nil)
    }

    @Test("the token ends at the first whitespace and closes once the caret passes it")
    func triggerTokenRange() {
        let token = try? #require(State.token(in: "/goal ship it", caret: 5))
        #expect(token?.range == 0 ..< 5)
        #expect(token?.query == "goal")
        // Typing the argument closes the popup.
        #expect(State.token(in: "/goal ship it", caret: 6) == nil)
        #expect(State.token(in: "/goal ship it", caret: 13) == nil)
        // A newline is whitespace too.
        #expect(State.token(in: "/goal\nmore", caret: 5)?.range == 0 ..< 5)
    }

    @Test("a typed path never opens the menu")
    func triggerRejectsPaths() {
        #expect(State.token(in: "/usr/bin", caret: 8) == nil)
        #expect(State.token(in: "/usr", caret: 4) != nil, "one slash is still a command token")
    }

    // MARK: - Filter + rank

    @Test("prefix matches rank above substring matches, stable within each rank")
    func filterRanking() {
        let labels = commands.map(\.name)
        // "compact" prefixes; "recompact" only contains.
        #expect(State.filterIndices(query: "comp", labels: labels) == [0, 3])
        // Both "clear" and "compact" prefix on "c"; input order is preserved.
        #expect(State.filterIndices(query: "c", labels: labels) == [0, 2, 3])
        #expect(State.filterIndices(query: "zzz", labels: labels).isEmpty)
    }

    @Test("an empty query matches everything at rank 1, in input order")
    func filterEmptyQuery() {
        let labels = commands.map(\.name)
        #expect(State.filterIndices(query: "", labels: labels) == [0, 1, 2, 3])
        #expect(State.filterIndices(query: "   ", labels: labels) == [0, 1, 2, 3])
    }

    @Test("matching is case-insensitive on both sides")
    func filterCaseInsensitive() {
        #expect(State.matchRank(query: "COMP", label: "compact") == 0)
        #expect(State.matchRank(query: "comp", label: "Compact") == 0)
        #expect(State.matchRank(query: "PACT", label: "compact") == 1)
        #expect(State.matchRank(query: "x", label: "compact") == nil)
    }

    // MARK: - Keyboard model

    @Test("active resets to row 0 on EVERY refilter")
    func activeResetsOnRefilter() {
        var state = State()
        state.sync(text: "/c", caret: 2, commands: commands)
        #expect(state.active == 0)
        state.move(by: 2)
        #expect(state.active == 2)
        // One more keystroke and the highlight is back at the top.
        state.sync(text: "/co", caret: 3, commands: commands)
        #expect(state.active == 0)
        #expect(state.filtered == [0, 3])
    }

    @Test("arrow navigation wraps at both ends and enters at the matching edge")
    func stepWraps() {
        #expect(State.step(active: nil, count: 3, delta: 1) == 0)
        #expect(State.step(active: nil, count: 3, delta: -1) == 2)
        #expect(State.step(active: 0, count: 3, delta: -1) == 2)
        #expect(State.step(active: 2, count: 3, delta: 1) == 0)
        #expect(State.step(active: 1, count: 3, delta: 1) == 2)
        #expect(State.step(active: nil, count: 0, delta: 1) == nil, "an empty menu stays nil")
        #expect(State.step(active: 0, count: 0, delta: 1) == nil)
    }

    @Test("an empty result set leaves nothing highlighted")
    func emptyResultsHaveNoActive() {
        var state = State()
        state.sync(text: "/zzz", caret: 4, commands: commands)
        #expect(state.isOpen, "the card still mounts, to show 'No matching commands'")
        #expect(state.filtered.isEmpty)
        #expect(state.active == nil)
    }

    @Test("Escape keeps the SAME token closed but any edit re-enables completion")
    func dismissStickiness() {
        var state = State()
        state.sync(text: "/comp", caret: 5, commands: commands)
        #expect(state.isOpen)
        state.dismiss()
        #expect(!state.isOpen)
        // Re-syncing the identical token stays closed.
        state.sync(text: "/comp", caret: 5, commands: commands)
        #expect(!state.isOpen)
        // Editing it reopens.
        state.sync(text: "/compa", caret: 6, commands: commands)
        #expect(state.isOpen)
    }

    // MARK: - Accept

    @Test("accept replaces the whole token range with /name")
    func accept() {
        var state = State()
        state.sync(text: "/comp", caret: 5, commands: commands)
        let applied = try? #require(state.accept(in: "/comp", commands: commands))
        #expect(applied?.text == "/compact")
        #expect(applied?.caret == 8)
    }

    @Test("accept preserves the argument that follows the token")
    func acceptKeepsArgument() {
        var state = State()
        // The caret is still inside the token, so the popup is live.
        state.sync(text: "/go ship it", caret: 3, commands: commands)
        #expect(state.filtered == [1])
        let applied = try? #require(state.accept(in: "/go ship it", commands: commands))
        #expect(applied?.text == "/goal ship it")
        #expect(applied?.caret == 5)
    }

    @Test("clicking a row selects it, then accepts that row")
    func selectThenAccept() {
        var state = State()
        state.sync(text: "/c", caret: 2, commands: commands)
        state.select(row: 2)
        #expect(state.acceptedCommand(from: commands)?.name == "recompact")
        // An out-of-range row is ignored rather than crashing a click handler.
        state.select(row: 99)
        #expect(state.active == 2)
    }

    // MARK: - Row copy

    @Test("the hint is concatenated into the description with a middle dot")
    func detailText() {
        #expect(commands[1].detailText == "Set a goal · <the goal>")
        #expect(commands[0].detailText == "Compact the session")
        #expect(commands[3].detailText.isEmpty)
        #expect(
            SupermuxZeronSlashCommand(name: "x", inputHint: "arg").detailText == "<arg>",
            "a hint with no description stands alone"
        )
        #expect(commands[0].displayName == "/compact")
    }
}
