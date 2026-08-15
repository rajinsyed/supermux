import Foundation

/// Projects typed protocol lines onto the ordered transcript rows the view
/// renders.
///
/// Pure and synchronous so the whole projection is unit-testable from fixtures
/// without a process, a view, or a clock. It keeps its own
/// ``ClaudeStreamAccumulator`` rather than re-reading the session actor's, so a
/// delta costs no actor hop: the session already broadcast the line.
///
/// Row identity rule: a row is *updated in place* whenever a later line refines
/// it (streaming text growing, a tool call receiving its result). Only genuinely
/// new content appends. That keeps `LazyVStack` identities stable, so SwiftUI
/// animates the change instead of tearing down and re-inserting rows mid-stream.
///
/// Grouping rule: consecutive tool calls collapse into ONE
/// ``SupermuxHarnessToolGroup`` row. Any non-tool row closes the open group, so
/// a turn reads call → answer → call rather than as a wall of flat tool lines.
public struct SupermuxHarnessRowBuilder: Sendable {
    public private(set) var rows: [SupermuxHarnessRow] = []

    private var accumulator = ClaudeStreamAccumulator()
    private var indexByID: [String: Int] = [:]
    /// Prompt uuids already rendered, so a replayed `user` line cannot
    /// duplicate a prompt after a resume backfill.
    private var seenPromptUUIDs: Set<String> = []
    private var noticeCounter = 0
    private var resultCounter = 0

    /// Per-entry projection cursor: which group row is currently open, how many
    /// groups the entry has opened, and whether it has emitted a row yet.
    private struct EntryCursor {
        var openGroupRowID: String?
        var groupIndex = 0
        var hasEmittedRow = false
        var lastRowID: String?
        var isStreaming = true
        var createdAt = Date()
    }

    private var cursors: [String: EntryCursor] = [:]
    /// `tool_use_id` → the group row that owns the call, so a result arriving
    /// on a later `user` line finds it without scanning every row.
    private var groupRowIDByToolUseID: [String: String] = [:]
    /// Row indices per entry. Rows only ever append, so an index stays valid,
    /// and the per-entry sweeps below stay O(entry) rather than O(transcript).
    private var rowIndicesByEntryID: [String: [Int]] = [:]

    public init() {}

    /// Consumes one transcript line, updating `rows` in place.
    public mutating func consume(_ line: ClaudeStreamLine) {
        for event in accumulator.consume(line) {
            if case .messageChanged(let message) = event {
                apply(message)
            }
        }
        switch line {
        case .user(let envelope):
            applyUser(envelope)
        case .result(let result):
            resultCounter += 1
            let entryID = "result-\(resultCounter)-\(result.uuid ?? "")"
            appendStandalone(
                id: entryID,
                entryID: entryID,
                kind: .result(SupermuxHarnessResultSummary(result: result))
            )
        case .system(let event):
            applySystem(event)
        case .assistant, .streamEvent, .controlRequest, .controlResponse, .unknown:
            break
        }
    }

    /// Appends a notice row (diagnostics, process end, launcher errors).
    ///
    /// A notice with a blank title is dropped: it would render as an icon and a
    /// zero-width string, i.e. an empty band in the transcript.
    public mutating func append(notice: SupermuxHarnessNotice) {
        guard !notice.title.isBlankForTranscript else { return }
        noticeCounter += 1
        let id = "notice-\(noticeCounter)"
        appendStandalone(id: id, entryID: id, kind: .notice(notice))
    }

    /// Drops every row (used when a session is restarted in place).
    public mutating func reset() {
        self = SupermuxHarnessRowBuilder()
    }

    // MARK: - Assistant messages

    private mutating func apply(_ message: ClaudeStreamAccumulator.Message) {
        let entryID = message.key.messageID
        var cursor = cursors[entryID] ?? EntryCursor()
        cursor.isStreaming = !message.isComplete
        cursors[entryID] = cursor

        for block in message.blocks {
            let rowID = "\(entryID)-\(block.index)"
            switch block.content {
            case .text(let text, _):
                // Whitespace-only is not content. The CLI regularly emits
                // "\n\n" text blocks as separators between tool calls; an
                // `isEmpty` check lets those through, and each one becomes a
                // real row occupying a real line box plus `rowSpacing` — blank
                // bands in the transcript with nothing drawn in them. They also
                // must not close an open tool group, or every consecutive pair
                // of Claude tool calls would land in its own group.
                guard !text.isBlankForTranscript else { continue }
                upsertBlock(
                    id: rowID,
                    entryID: entryID,
                    kind: .assistantProse(text: text, isStreaming: !block.isComplete)
                )
            case .thinking(let thinking, _):
                guard !thinking.isBlankForTranscript else { continue }
                upsertBlock(
                    id: rowID,
                    entryID: entryID,
                    kind: .thinking(text: thinking, isStreaming: !block.isComplete)
                )
            case .toolUse(let id, let name, let input, _):
                guard !id.isEmpty else { continue }
                appendToolCall(id: id, name: name, input: input, entryID: entryID)
            case .toolResult, .image, .document, .unknown:
                continue
            }
        }

        // `autoOpen` and the settled timestamp both hang off the streaming bit
        // rather than off any block, so they are re-derived every time — a
        // `message_stop` that changes nothing else still has to close the
        // trailing group and stamp the entry.
        refreshAutoOpen(entryID: entryID)
        restampEntry(entryID)
    }

    /// Appends a tool call to the entry's open group, or opens a new one.
    ///
    /// The call is keyed by `tool_use_id`, not by block position: its result
    /// arrives on a later `user` line that knows only that id.
    private mutating func appendToolCall(
        id: String,
        name: String,
        input: ClaudeJSONValue,
        entryID: String
    ) {
        var cursor = cursors[entryID] ?? EntryCursor()

        // An already-projected call is refined in place, wherever it sits.
        if let rowID = groupRowIDByToolUseID[id],
           let rowIndex = indexByID[rowID],
           case .toolGroup(var group) = rows[rowIndex].kind,
           let callIndex = group.tools.firstIndex(where: { $0.id == id }) {
            group.tools[callIndex].input = input
            replaceKind(at: rowIndex, with: .toolGroup(group))
            return
        }

        if let openID = cursor.openGroupRowID,
           let rowIndex = indexByID[openID],
           case .toolGroup(var group) = rows[rowIndex].kind {
            group.tools.append(
                SupermuxHarnessToolCall(id: id, name: name, input: input, status: .running)
            )
            replaceKind(at: rowIndex, with: .toolGroup(group))
            groupRowIDByToolUseID[id] = openID
            return
        }

        let rowID = "\(entryID)#g\(cursor.groupIndex)"
        cursor.groupIndex += 1
        cursor.openGroupRowID = rowID
        cursors[entryID] = cursor
        let group = SupermuxHarnessToolGroup(
            id: rowID,
            tools: [SupermuxHarnessToolCall(id: id, name: name, input: input, status: .running)],
            autoOpen: false
        )
        groupRowIDByToolUseID[id] = rowID
        appendRow(id: rowID, entryID: entryID, kind: .toolGroup(group))
    }

    // MARK: - User lines

    private mutating func applyUser(_ envelope: ClaudeMessageEnvelope) {
        var resolvedToolResult = false
        for block in envelope.message.content {
            guard case .toolResult(let toolUseID, let content, let isError) = block,
                  let toolUseID else { continue }
            resolvedToolResult = true
            guard let rowID = groupRowIDByToolUseID[toolUseID],
                  let rowIndex = indexByID[rowID],
                  case .toolGroup(var group) = rows[rowIndex].kind,
                  let callIndex = group.tools.firstIndex(where: { $0.id == toolUseID })
            else { continue }
            group.tools[callIndex].status = (isError ?? false) ? .failed : .succeeded
            group.tools[callIndex].resultText = content.plainText
            group.tools[callIndex].toolUseResult = envelope.toolUseResult
            replaceKind(at: rowIndex, with: .toolGroup(group))
        }
        guard !resolvedToolResult else { return }
        // A plain replayed user line is the prompt acknowledgment.
        let text = envelope.message.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let identity = envelope.uuid ?? "prompt-\(rows.count)"
        guard seenPromptUUIDs.insert(identity).inserted else { return }
        appendRow(
            id: "prompt-\(identity)",
            entryID: identity,
            kind: .userPrompt(text: trimmed),
            // A user row always carries its time: the prompt happened, even if
            // the answer has not.
            timestamp: Self.parseTimestamp(envelope.timestamp) ?? Date()
        )
    }

    // MARK: - System lines

    private mutating func applySystem(_ event: ClaudeSystemEvent) {
        switch event {
        case .notification(let notification):
            guard let text = notification.text, !text.isBlankForTranscript else { return }
            append(notice: SupermuxHarnessNotice(severity: .info, title: text))
        case .permissionDenied(let payload):
            append(
                notice: SupermuxHarnessNotice(
                    severity: .warning,
                    title: String(
                        localized: "supermux.harness.notice.permissionDenied",
                        defaultValue: "Claude reported a denied tool permission."
                    ),
                    detail: payload["message"]?.stringValue
                )
            )
        case .initialize, .status, .hookStarted, .hookResponse, .hookProgress,
             .thinkingTokens, .compactBoundary, .unknown:
            break
        }
    }

    // MARK: - Row storage

    /// Appends (or refines) a non-tool block row, closing any open group first.
    private mutating func upsertBlock(
        id: String,
        entryID: String,
        kind: SupermuxHarnessRow.Kind
    ) {
        if let index = indexByID[id] {
            replaceKind(at: index, with: kind)
            return
        }
        cursors[entryID]?.openGroupRowID = nil
        appendRow(id: id, entryID: entryID, kind: kind)
    }

    /// A row that is its own entry (notices, results) — it also closes every
    /// open group, since something that is not part of a turn came between.
    ///
    /// These never stream, so the entry is settled on arrival and the row
    /// carries its timestamp immediately.
    private mutating func appendStandalone(
        id: String,
        entryID: String,
        kind: SupermuxHarnessRow.Kind
    ) {
        for key in cursors.keys {
            cursors[key]?.openGroupRowID = nil
        }
        var cursor = cursors[entryID] ?? EntryCursor()
        cursor.isStreaming = false
        cursors[entryID] = cursor
        appendRow(id: id, entryID: entryID, kind: kind)
    }

    private mutating func appendRow(
        id: String,
        entryID: String,
        kind: SupermuxHarnessRow.Kind,
        timestamp: Date? = nil
    ) {
        guard indexByID[id] == nil else { return }
        var cursor = cursors[entryID] ?? EntryCursor()
        let isFirst = !cursor.hasEmittedRow
        cursor.hasEmittedRow = true
        cursor.lastRowID = id
        cursors[entryID] = cursor

        var row = SupermuxHarnessRow(
            id: id,
            kind: kind,
            turnStart: isFirst,
            entryID: entryID,
            timestamp: timestamp
        )
        row.version = Self.fingerprint(of: row)
        indexByID[id] = rows.count
        rowIndicesByEntryID[entryID, default: []].append(rows.count)
        rows.append(row)
        // The entry's LAST row moved, so the previous holder gives its stamp up.
        restampEntry(entryID)
    }

    private mutating func replaceKind(at index: Int, with kind: SupermuxHarnessRow.Kind) {
        guard rows[index].kind != kind else { return }
        rows[index].kind = kind
        rows[index].version = Self.fingerprint(of: rows[index])
    }

    /// Re-evaluates which row of an entry carries the timestamp.
    ///
    /// The entry's LAST row carries it, and only once streaming has ended —
    /// "the turn isn't at a time yet" while it is still being written. Every
    /// earlier row gives its stamp up when a newer row appends.
    ///
    /// Setting it must bump the version too: a tool-group row's own fingerprint
    /// would not otherwise change when streaming flips off.
    ///
    /// User rows are exempt — they were stamped at append and never stream.
    private mutating func restampEntry(_ entryID: String) {
        guard let cursor = cursors[entryID], let lastRowID = cursor.lastRowID else { return }
        let stamp = cursor.isStreaming ? nil : cursor.createdAt
        for index in rowIndicesByEntryID[entryID] ?? [] {
            if case .userPrompt = rows[index].kind { continue }
            setTimestamp(rows[index].id == lastRowID ? stamp : nil, at: index)
        }
    }

    private mutating func setTimestamp(_ timestamp: Date?, at index: Int) {
        guard rows[index].timestamp != timestamp else { return }
        rows[index].timestamp = timestamp
        rows[index].version = Self.fingerprint(of: rows[index])
    }

    /// A trailing group auto-expands while its message streams; every other
    /// group stays closed.
    private mutating func refreshAutoOpen(entryID: String) {
        guard let cursor = cursors[entryID] else { return }
        let lastGroupRowID = cursor.isStreaming ? cursor.openGroupRowID : nil
        for index in rowIndicesByEntryID[entryID] ?? [] {
            guard case .toolGroup(var group) = rows[index].kind else { continue }
            let wanted = group.id == lastGroupRowID
            guard group.autoOpen != wanted else { continue }
            group.autoOpen = wanted
            replaceKind(at: index, with: .toolGroup(group))
        }
    }

    /// The CLI stamps `user` lines ISO-8601, usually with fractional seconds.
    private static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let fractional = try? Date(
            text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return fractional
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}

extension String {
    /// True when this string would render as an empty transcript row.
    ///
    /// Deliberately stricter than `isEmpty`: a block of only newlines or spaces
    /// still occupies a full line box plus the surrounding `rowSpacing`, so it
    /// reads as an unexplained gap in the transcript rather than as nothing.
    var isBlankForTranscript: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
