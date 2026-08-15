import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// The tool-group row model: consecutive calls collapse into ONE row with a
/// summary line, a guide rail, and an analytic height.
///
/// The summary rules are ported verbatim from zeron's `tool_group_summary`
/// (`crates/proto/src/view.rs`) and its `tool_group_summaries` unit test, so
/// the two products name the same turn identically.
struct SupermuxHarnessToolGroupTests {
    // MARK: - Fixtures

    private func call(
        _ id: String,
        _ name: String,
        _ input: [String: ClaudeJSONValue],
        status: SupermuxHarnessToolCall.Status = .succeeded
    ) -> SupermuxHarnessToolCall {
        SupermuxHarnessToolCall(id: id, name: name, input: .object(input), status: status)
    }

    private func exec(_ command: String, failed: Bool = false) -> SupermuxHarnessToolCall {
        call(
            "x-\(command)", "Bash", ["command": .string(command)],
            status: failed ? .failed : .succeeded
        )
    }

    private func edit(_ path: String) -> SupermuxHarnessToolCall {
        call("e-\(path)", "Edit", ["file_path": .string(path)])
    }

    private func group(_ tools: [SupermuxHarnessToolCall]) -> SupermuxHarnessToolGroup {
        SupermuxHarnessToolGroup(id: "g", tools: tools, autoOpen: false)
    }

    private func line(_ json: String) -> ClaudeStreamLine {
        let value = try! JSONDecoder().decode(ClaudeJSONValue.self, from: Data(json.utf8))
        return ClaudeStreamLine.decode(value)
    }

    // MARK: - Grouping

    /// The single behavioral change of the row-model port: a turn that runs
    /// three commands is ONE row with a rail, not three flat rows.
    @Test func consecutive_tool_calls_collapse_into_one_group() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},
        {"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}},
        {"type":"tool_use","id":"t3","name":"Bash","input":{"command":"make"}}]}}
        """))

        #expect(builder.rows.count == 1)
        guard case .toolGroup(let group) = builder.rows[0].kind else {
            Issue.record("expected a tool group, got \(builder.rows[0].kind)")
            return
        }
        #expect(group.tools.count == 3)
        #expect(group.id == "m#g0")
        #expect(group.summary == "Ran 3 commands")
        #expect(builder.rows[0].turnStart)
        #expect(builder.rows[0].entryID == "m")
    }

    /// Prose between two tool runs is a real boundary: the second run opens its
    /// own group so the transcript reads call → answer → call.
    @Test func a_prose_block_between_tools_opens_a_second_group() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},
        {"type":"text","text":"Now I will build."},
        {"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make"}}]}}
        """))

        #expect(builder.rows.count == 3)
        guard case .toolGroup(let first) = builder.rows[0].kind,
              case .assistantProse = builder.rows[1].kind,
              case .toolGroup(let second) = builder.rows[2].kind else {
            Issue.record("expected group / prose / group, got \(builder.rows.map(\.kind))")
            return
        }
        #expect(first.tools.count == 1)
        #expect(second.tools.count == 1)
        #expect(first.id == "m#g0")
        #expect(second.id == "m#g1")
        // Only the entry's FIRST row takes the turn gap.
        #expect(builder.rows[0].turnStart)
        #expect(!builder.rows[1].turnStart)
        #expect(!builder.rows[2].turnStart)
    }

    /// A `"\n\n"` separator block is not prose. The CLI emits these routinely
    /// between tool calls; splitting on them would put every consecutive Claude
    /// tool pair in its own group and defeat the whole feature.
    @Test func blankSeparatorDoesNotSplitAGroup() {
        var builder = SupermuxHarnessRowBuilder()
        builder.consume(line("""
        {"type":"assistant","session_id":"s","message":{"id":"m","role":"assistant",
        "content":[
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},
        {"type":"text","text":"\\n\\n"},
        {"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}}]}}
        """))
        #expect(builder.rows.count == 1)
        guard case .toolGroup(let group) = builder.rows[0].kind else {
            Issue.record("expected one tool group")
            return
        }
        #expect(group.tools.count == 2)
    }

    /// The same shape against a real captured turn rather than hand-written
    /// JSON: thinking, then a Bash call, its result, then more thinking + prose.
    @Test func aCapturedToolTurnProjectsARailedGroup() throws {
        var builder = SupermuxHarnessRowBuilder()
        for line in try FixtureSupport.decode("tool-turn.jsonl").lines {
            builder.consume(line)
        }
        let groups = builder.rows.compactMap { row -> SupermuxHarnessToolGroup? in
            guard case .toolGroup(let group) = row.kind else { return nil }
            return group
        }
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.tools.count == 1)
        #expect(group.tools[0].chipKind == .exec)
        #expect(group.tools[0].status == .succeeded)
        #expect(group.summary == "Ran 1 command")
        // The turn settled, so the group is closed again.
        #expect(!group.autoOpen)
        // Exactly one row per entry carries the timestamp.
        let stamped = builder.rows.filter { $0.timestamp != nil }
        #expect(stamped.count == Set(stamped.map(\.entryID)).count)
    }

    // MARK: - Summary table (ported from zeron `tool_group_summaries`)

    @Test func toolGroupSummaries() {
        // Ported verbatim from crates/ui/src/transcript.rs.
        #expect(
            group([exec("ls"), exec("pwd"), exec("make"), edit("a.rs"), edit("b.rs")]).summary
                == "Ran 3 commands · edited 2 files"
        )
        // Distinct-path dedupe: editing one file twice counts once.
        #expect(group([edit("a.rs"), edit("a.rs")]).summary == "Edited 1 file")
        // Failures append LAST.
        #expect(group([exec("boom", failed: true)]).summary == "Ran 1 command · 1 failed")
        // Reads / searches / misc.
        #expect(
            group([
                call("r", "Read", ["file_path": .string("x")]),
                call("g", "Glob", ["pattern": .string("*.rs")]),
                call("w", "WebSearch", ["query": .string("q")]),
            ]).summary == "Read 1 file · searched 2 times"
        )
    }

    /// The seven slots emit in a fixed order, joined " · ", and ONLY the first
    /// character of the whole joined string is uppercased.
    @Test func summarySlotsEmitInOrder() {
        let all = group([
            exec("ls"),
            edit("a.rs"),
            call("r", "Read", ["file_path": .string("b.rs")]),
            call("s", "Grep", ["pattern": .string("foo")]),
            call("f", "WebFetch", ["url": .string("https://example.com")]),
            call("t", "TodoWrite", ["todos": .array([])]),
            call("m", "mcp__gh__issues", [:]),
        ])
        #expect(
            all.summary
                == "Ran 1 command · edited 1 file · read 1 file · searched 1 time"
                + " · fetched 1 page · updated todos · called 1 tool"
        )
    }

    @Test func updatedTodosIsNeverPluralized() {
        let todos = group([
            call("t1", "TodoWrite", ["todos": .array([])]),
            call("t2", "TodoWrite", ["todos": .array([])]),
        ])
        #expect(todos.summary == "Updated todos")
    }

    /// `ApplyPatch` with no path dedupes on the literal "patch", not on the
    /// chip's "workspace" subject.
    @Test func pathlessPatchesDedupeOnTheLiteralPatch() {
        let a = SupermuxHarnessToolCall(
            id: "p1", name: "ApplyPatch", input: .object([:]), status: .succeeded
        )
        let b = SupermuxHarnessToolCall(
            id: "p2", name: "ApplyPatch", input: .object([:]), status: .succeeded
        )
        #expect(group([a, b]).summary == "Edited 1 file")
        #expect(a.chipSubject == "workspace")
    }

    /// No slot matched at all ⇒ a bare `plural(total, "tool", "tools")`.
    @Test func emptyGroupFallsBackToABareToolCount() {
        #expect(group([]).summary == "0 tools")
    }

    @Test func failuresAlwaysComeLast() {
        let tools = [exec("ls"), edit("a.rs", failed: true)]
        #expect(group(tools).summary == "Ran 1 command · edited 1 file · 1 failed")
    }

    // MARK: - Analytic height

    @Test func chipsHeightIsAnalytic() {
        #expect(group([]).chipsHeight == 0)
        #expect(group([exec("ls")]).chipsHeight == 40)
        #expect(group([exec("ls"), exec("pwd")]).chipsHeight == 78)
        for n in 1...12 {
            let tools = (0..<n).map { exec("c\($0)") }
            #expect(group(tools).chipsHeight == 2 + 38 * CGFloat(n))
        }
    }
}

private extension SupermuxHarnessToolGroupTests {
    func edit(_ path: String, failed: Bool) -> SupermuxHarnessToolCall {
        SupermuxHarnessToolCall(
            id: "e-\(path)", name: "Edit", input: .object(["file_path": .string(path)]),
            status: failed ? .failed : .succeeded
        )
    }
}
