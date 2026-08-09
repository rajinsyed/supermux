import CmuxAgentChat
import Foundation
import Testing

@testable import SupermuxMobileUI

/// Focus mode hides content by design, so these pin the two things that make
/// that safe: what it is allowed to hide, and that nothing is ever dropped.
@Suite("Supermux chat focus grouping")
struct SupermuxChatFocusGroupingTests {
    // MARK: - Fixtures

    private func message(
        _ id: String,
        _ kind: ChatMessageKind,
        role: ChatRole = .agent
    ) -> ChatTranscriptRow {
        .message(
            ChatMessageRowSnapshot(
                message: ChatMessage(
                    id: id,
                    seq: 0,
                    role: role,
                    timestamp: Date(timeIntervalSince1970: 0),
                    kind: kind
                ),
                groupPosition: .solo,
                showsTimestamp: false
            )
        )
    }

    private func tool(_ id: String) -> ChatTranscriptRow {
        message(id, .toolUse(ChatToolUse(toolName: "Read", summary: "Read a.swift")))
    }

    private func prose(_ id: String, role: ChatRole = .agent) -> ChatTranscriptRow {
        message(id, .prose(ChatProse(text: "hello")), role: role)
    }

    // MARK: - What gets folded

    @Test("A run of work rows folds into one group")
    func runFolds() {
        let items = SupermuxChatFocusGrouping().items(
            for: [prose("p1"), tool("t1"), tool("t2"), tool("t3"), prose("p2")]
        )
        #expect(items.count == 3)
        guard case .workGroup(let group) = items[1] else {
            Issue.record("expected the middle item to be a group")
            return
        }
        #expect(group.count == 3)
    }

    @Test("Non-adjacent runs stay separate groups")
    func separateRunsStaySeparate() {
        let items = SupermuxChatFocusGrouping().items(
            for: [tool("t1"), tool("t2"), prose("p1"), tool("t3"), tool("t4")]
        )
        #expect(items.count == 3)
        if case .workGroup = items[0] {} else { Issue.record("first should be a group") }
        if case .row = items[1] {} else { Issue.record("middle should be a row") }
        if case .workGroup = items[2] {} else { Issue.record("last should be a group") }
    }

    @Test("A lone work row is left alone — folding one call saves nothing")
    func singleWorkRowIsNotFolded() {
        let items = SupermuxChatFocusGrouping().items(for: [prose("p1"), tool("t1"), prose("p2")])
        #expect(items.count == 3)
        if case .row = items[1] {} else { Issue.record("a single tool row should not fold") }
    }

    @Test("Every work kind folds: tools, thinking, shell output, diffs")
    func allWorkKindsFold() {
        let rows = [
            message("t", .toolUse(ChatToolUse(toolName: "Read", summary: "Read a"))),
            message("k", .thought(ChatThought(text: "thinking"))),
            message("s", .terminal(ChatTerminalCapture(command: "ls"))),
            message("d", .fileEdit(ChatFileEdit(filePath: "a.swift", operation: .edit))),
        ]
        for row in rows {
            #expect(SupermuxChatFocusGrouping.isWorkRow(row), "\(row.id) should be work")
        }
        let items = SupermuxChatFocusGrouping().items(for: rows)
        #expect(items.count == 1)
    }

    // MARK: - What must never be folded

    @Test("Blocking and conversational rows are never folded")
    func nonWorkRowsAreNeverFolded() {
        // Permissions and questions BLOCK the agent — hiding them would strand
        // the session behind a disclosure the user has no reason to open.
        let rows: [ChatTranscriptRow] = [
            prose("p", role: .agent),
            prose("u", role: .user),
            message("q", .question(ChatQuestion(prompt: "which?", options: []))),
            message("perm", .permissionRequest(ChatPermissionRequest(title: "Allow?", subject: "rm"))),
            message("st", .status(ChatStatusTransition(event: .sessionStarted))),
            message("att", .attachment(ChatAttachment(media: .image))),
            .dateHeader(day: Date(timeIntervalSince1970: 0)),
            .unreadSeparator,
        ]
        for row in rows {
            #expect(!SupermuxChatFocusGrouping.isWorkRow(row), "\(row.id) must stay visible")
        }
        let items = SupermuxChatFocusGrouping().items(for: rows)
        #expect(items.count == rows.count)
    }

    @Test("A pending outbound prompt is never folded")
    func pendingOutboundIsNeverFolded() {
        let pending = ChatTranscriptRow.pendingOutbound(
            ChatPendingOutbound(
                id: "x",
                text: "do the thing",
                createdAt: Date(timeIntervalSince1970: 0),
                delivery: .sending
            )
        )
        #expect(!SupermuxChatFocusGrouping.isWorkRow(pending))
    }

    // MARK: - Safety invariants

    @Test("Disabling focus mode passes every row through untouched")
    func disabledIsIdentity() {
        let rows = [prose("p1"), tool("t1"), tool("t2"), prose("p2")]
        let items = SupermuxChatFocusGrouping().items(for: rows, isEnabled: false)
        #expect(items.count == rows.count)
        #expect(items.map(\.id) == rows.map(\.id))
    }

    @Test("No row is ever dropped, whatever the shape")
    func groupingLosesNothing() {
        let rows = [
            prose("p1"), tool("t1"), tool("t2"), prose("p2"),
            tool("t3"), message("k", .thought(ChatThought(text: "x"))), prose("p3"), tool("t4"),
        ]
        var seen: [String] = []
        for item in SupermuxChatFocusGrouping().items(for: rows) {
            switch item {
            case .row(let row): seen.append(row.id)
            case .workGroup(let group): seen.append(contentsOf: group.rows.map(\.id))
            }
        }
        #expect(seen == rows.map(\.id), "grouping must preserve every row, in order")
    }

    @Test("A group keeps its identity as the run grows, so it stays expanded")
    func groupIdentityIsStableAsRunGrows() {
        func groupID(_ rows: [ChatTranscriptRow]) -> String? {
            for case .workGroup(let group) in SupermuxChatFocusGrouping().items(for: rows) {
                return group.id
            }
            return nil
        }
        // Streaming one more tool call into a live run must not re-key the
        // group, or the user's expanded disclosure would snap shut mid-turn.
        let before = groupID([prose("p"), tool("t1"), tool("t2")])
        let after = groupID([prose("p"), tool("t1"), tool("t2"), tool("t3")])
        #expect(before != nil)
        #expect(before == after)
    }

    @Test("An empty transcript groups to nothing")
    func emptyTranscript() {
        #expect(SupermuxChatFocusGrouping().items(for: []).isEmpty)
    }
}
