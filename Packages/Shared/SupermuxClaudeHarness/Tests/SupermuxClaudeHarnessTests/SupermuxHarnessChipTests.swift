import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// The chip view-model on `SupermuxHarnessToolCall`: kind, verb, subject, the
/// always-built invocation block, and the detail precedence.
struct SupermuxHarnessChipTests {
    private func call(
        _ name: String,
        _ input: [String: ClaudeJSONValue] = [:],
        result: String? = nil,
        toolUseResult: ClaudeJSONValue? = nil,
        status: SupermuxHarnessToolCall.Status = .succeeded
    ) -> SupermuxHarnessToolCall {
        SupermuxHarnessToolCall(
            id: "t", name: name, input: .object(input), status: status,
            resultText: result, toolUseResult: toolUseResult
        )
    }

    // MARK: - Kind / verb / subject

    @Test func claudeToolsMapOntoTheTwelveChipKinds() {
        let expected: [(String, SupermuxHarnessToolCall.ChipKind, String)] = [
            ("Bash", .exec, "Run"),
            ("BashOutput", .exec, "Run"),
            ("KillShell", .exec, "Run"),
            ("Read", .readFile, "Read"),
            ("NotebookRead", .readFile, "Read"),
            ("Write", .writeFile, "Write"),
            ("Edit", .editFile, "Edit"),
            ("MultiEdit", .editFile, "Edit"),
            ("NotebookEdit", .editFile, "Edit"),
            ("Grep", .search, "Search"),
            ("Glob", .glob, "Glob"),
            ("WebFetch", .webFetch, "Fetch"),
            ("WebSearch", .webSearch, "Web"),
            ("TodoWrite", .todo, "Todo"),
            ("mcp__gh__issues", .mcp, "MCP"),
            ("Task", .unknown, "Tool"),
            ("Skill", .unknown, "Tool"),
            ("ExitPlanMode", .unknown, "Tool"),
        ]
        for (name, kind, verb) in expected {
            let subject = call(name)
            #expect(subject.chipKind == kind, "\(name) kind")
            #expect(subject.verb == verb, "\(name) verb")
        }
    }

    @Test func chipSubjectsFollowTheMappingTable() {
        #expect(call("Bash", ["command": .string("echo ok")]).chipSubject == "echo ok")
        #expect(call("Read", ["file_path": .string("/a/b.swift")]).chipSubject == "/a/b.swift")
        #expect(
            call("Grep", ["pattern": .string("foo"), "path": .string("src")]).chipSubject
                == "foo in src"
        )
        #expect(call("Grep", ["pattern": .string("foo")]).chipSubject == "foo")
        #expect(call("Glob", ["pattern": .string("*.rs")]).chipSubject == "*.rs")
        #expect(call("WebFetch", ["url": .string("https://x")]).chipSubject == "https://x")
        #expect(call("WebSearch", ["query": .string("q")]).chipSubject == "q")
        #expect(call("mcp__gh__issues").chipSubject == "gh · issues")
        #expect(call("SomeCustomTool").chipSubject == "SomeCustomTool")
    }

    @Test func todoSubjectCountsDoneItems() {
        let todo = call("TodoWrite", ["todos": .array([
            .object(["content": .string("one"), "status": .string("completed")]),
            .object(["content": .string("two"), "status": .string("in_progress")]),
            .object(["content": .string("three"), "status": .string("pending")]),
        ])])
        #expect(todo.chipSubject == "1/3 done")
    }

    /// A literal newline in a subject breaks the chip's truncation, so every
    /// subject goes through the whitespace collapse — the user's breaker.
    @Test func chipSubjectAlwaysCollapsesWhitespace() {
        let multiline = call(
            "Bash", ["command": .string("set -e\nfixture_in_original=0\n\tgrep -c  \"x\"")]
        )
        #expect(multiline.chipSubject == "set -e fixture_in_original=0 grep -c \"x\"")
        #expect(!multiline.chipSubject.contains("\n"))
        #expect(call("WebSearch", ["query": .string("line one\nline two")]).chipSubject
            == "line one line two")
    }

    /// The humanizer stays: it is the accessibility label and the mobile DTO
    /// title. The CHIP verb is the one-word column.
    @Test func humanizedLabelsSurviveBesideTheOneWordVerb() {
        let bash = call("Bash", ["command": .string("echo hello")])
        #expect(bash.labels.running == "Running command")
        #expect(bash.labels.done == "Ran command")
        #expect(bash.verb == "Run")
    }

    // MARK: - Invocation block

    @Test func invocationBlockCarriesTheFullUnflattenedCall() {
        guard case .output(let lines, let truncated)? = call(
            "Bash", ["command": .string("set -e\ncargo test")]
        ).invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(truncated == 0)
        #expect(lines == ["set -e", "cargo test"])
    }

    /// Hard-wrap at exactly 80 CHARACTERS — not word boundaries. Block heights
    /// must be analytic, so the wrap is char-counted and never measured.
    @Test func longInvocationLinesHardWrapAtEightyCharacters() {
        let command = String(repeating: "x", count: 80 * 2 + 10)
        guard case .output(let lines, _)? = call("Bash", ["command": .string(command)])
            .invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.count <= 80 })
        #expect(lines[0].count == 80)
        #expect(lines[2].count == 10)
    }

    @Test func invocationCapsAtTwentyFourLinesWithACountedTail() {
        let command = (0..<30).map { "line \($0)" }.joined(separator: "\n")
        guard case .output(let lines, let truncated)? = call(
            "Bash", ["command": .string(command)]
        ).invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(lines.count == 24)
        #expect(truncated == 6)
    }

    @Test func invocationPopsTrailingBlanksAndVanishesWhenEmpty() {
        guard case .output(let lines, _)? = call(
            "Bash", ["command": .string("do it\n\n   \n")]
        ).invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(lines == ["do it"])
        #expect(call("Bash", ["command": .string("\n\n  ")]).invocationBlock == nil)
    }

    @Test func todoInvocationListsCheckboxes() {
        let todo = call("TodoWrite", ["todos": .array([
            .object(["content": .string("one"), "status": .string("completed")]),
            .object(["content": .string("two"), "status": .string("pending")]),
        ])])
        guard case .output(let lines, _)? = todo.invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(lines == ["[x] one", "[ ] two"])
    }

    @Test func mcpInvocationPrettyPrintsItsInputUnderTheHeader() {
        let mcp = call("mcp__gh__issues", ["repo": .string("zeron")])
        guard case .output(let lines, _)? = mcp.invocationBlock else {
            Issue.record("expected an output block")
            return
        }
        #expect(lines[0] == "gh · issues")
        #expect(lines.contains { $0.contains("\"repo\"") && $0.contains("\"zeron\"") })
    }

    // MARK: - Detail precedence

    @Test func detailPrefersDiffOverOutput() {
        let patched = call(
            "Edit", ["file_path": .string("a.swift")],
            result: "ok",
            toolUseResult: .object([
                "structuredPatch": .array([.object([
                    "oldStart": .number(1), "newStart": .number(1),
                    "lines": .array([.string(" ctx"), .string("-old"), .string("+new")]),
                ])]),
            ])
        )
        guard case .diff = patched.detail else {
            Issue.record("expected a diff detail, got \(String(describing: patched.detail))")
            return
        }
    }

    @Test func detailFallsBackToOutputLines() {
        guard case .output(let lines, let truncated)? = call(
            "Bash", ["command": .string("ls")], result: "a\nb\n\n  \n"
        ).detail else {
            Issue.record("expected an output detail")
            return
        }
        #expect(lines == ["a", "b"])
        #expect(truncated == 0)
    }

    /// Trailing blanks are popped FIRST, so a whitespace-only result renders
    /// nothing at all rather than an empty box.
    @Test func whitespaceOnlyOutputYieldsNoDetail() {
        #expect(call("Bash", ["command": .string("ls")], result: "\n\n   ").detail == nil)
        #expect(call("Bash", ["command": .string("ls")]).detail == nil)
    }

    /// An identical-text patch produces zero hunks; the chip must render
    /// NOTHING, not an empty diff box.
    @Test func anIdenticalTextDiffReturnsNilOutright() {
        let noop = call(
            "Edit", ["file_path": .string("a.swift")],
            toolUseResult: .object(["structuredPatch": .array([])])
        )
        #expect(noop.detail == nil)
    }

    @Test func outputDetailCapsAtTwentyFourLinesWithACountedTail() {
        let body = (0..<30).map { "line \($0)" }.joined(separator: "\n")
        guard case .output(let lines, let truncated)? = call(
            "Bash", ["command": .string("ls")], result: body
        ).detail else {
            Issue.record("expected an output detail")
            return
        }
        #expect(lines.count == 24)
        #expect(truncated == 6)
    }

    // MARK: - Analytic detail height

    @Test func chipDetailHeightIsAnalytic() {
        // 1 separator + rows × 18 + 12 body pad.
        #expect(SupermuxHarnessChipDetail.output(lines: ["a", "b"], truncatedBy: 0).height == 49)
        // The counted tail is one more 18 pt row.
        #expect(SupermuxHarnessChipDetail.output(lines: ["a", "b"], truncatedBy: 3).height == 67)
        #expect(
            SupermuxHarnessChipDetail
                .stats([.init(path: "a.swift", additions: 2, deletions: 1)])
                .height == 31
        )
        // Stats has NO counted tail row.
        let diff = SupermuxHarnessDiff.from(toolUseResult: .object([
            "structuredPatch": .array([.object([
                "oldStart": .number(1), "newStart": .number(1),
                "lines": .array([.string(" ctx"), .string("-old"), .string("+new")]),
            ])]),
        ]))!
        // 1 + (0 notices × 24 + 1 hunk × 28 + 3 lines × 21 + 8) = 100.
        #expect(SupermuxHarnessChipDetail.diff(diff).height == 100)
    }
}
