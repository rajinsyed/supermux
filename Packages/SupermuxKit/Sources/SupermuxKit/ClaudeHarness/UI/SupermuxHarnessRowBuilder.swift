import Foundation
public import SupermuxClaudeHarness

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
public struct SupermuxHarnessRowBuilder: Sendable {
    public private(set) var rows: [SupermuxHarnessRow] = []

    private var accumulator = ClaudeStreamAccumulator()
    private var indexByID: [String: Int] = [:]
    /// Prompt uuids already rendered, so a replayed `user` line cannot
    /// duplicate a prompt after a resume backfill.
    private var seenPromptUUIDs: Set<String> = []
    private var noticeCounter = 0
    private var resultCounter = 0

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
            upsert(
                SupermuxHarnessRow(
                    id: "result-\(resultCounter)-\(result.uuid ?? "")",
                    kind: .result(SupermuxHarnessResultSummary(result: result))
                )
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
        upsert(SupermuxHarnessRow(id: "notice-\(noticeCounter)", kind: .notice(notice)))
    }

    /// Drops every row (used when a session is restarted in place).
    public mutating func reset() {
        self = SupermuxHarnessRowBuilder()
    }

    // MARK: - Assistant messages

    private mutating func apply(_ message: ClaudeStreamAccumulator.Message) {
        for block in message.blocks {
            let rowID = "\(message.key.messageID)-\(block.index)"
            switch block.content {
            case .text(let text, _):
                // Whitespace-only is not content. The CLI regularly emits
                // "\n\n" text blocks as separators between tool calls; an
                // `isEmpty` check lets those through, and each one becomes a
                // real row occupying a real line box plus `rowSpacing` — blank
                // bands in the transcript with nothing drawn in them.
                guard !text.isBlankForTranscript else { continue }
                upsert(
                    SupermuxHarnessRow(
                        id: rowID,
                        kind: .assistantProse(text: text, isStreaming: !block.isComplete)
                    )
                )
            case .thinking(let thinking, _):
                guard !thinking.isBlankForTranscript else { continue }
                upsert(
                    SupermuxHarnessRow(
                        id: rowID,
                        kind: .thinking(text: thinking, isStreaming: !block.isComplete)
                    )
                )
            case .toolUse(let id, let name, let input, _):
                guard !id.isEmpty else { continue }
                // A tool row is keyed by tool_use_id, not by block position:
                // its result arrives on a later `user` line that only knows
                // that id.
                if let existing = existingToolCall(id: id) {
                    var updated = existing
                    updated.input = input
                    upsert(SupermuxHarnessRow(id: toolRowID(id), kind: .toolCall(updated)))
                } else {
                    upsert(
                        SupermuxHarnessRow(
                            id: toolRowID(id),
                            kind: .toolCall(
                                SupermuxHarnessToolCall(
                                    id: id, name: name, input: input, status: .running
                                )
                            )
                        )
                    )
                }
            case .toolResult, .image, .document, .unknown:
                continue
            }
        }
    }

    // MARK: - User lines

    private mutating func applyUser(_ envelope: ClaudeMessageEnvelope) {
        var resolvedToolResult = false
        for block in envelope.message.content {
            guard case .toolResult(let toolUseID, let content, let isError) = block,
                  let toolUseID else { continue }
            resolvedToolResult = true
            guard var call = existingToolCall(id: toolUseID) else { continue }
            call.status = (isError ?? false) ? .failed : .succeeded
            call.resultText = content.plainText
            call.toolUseResult = envelope.toolUseResult
            upsert(SupermuxHarnessRow(id: toolRowID(toolUseID), kind: .toolCall(call)))
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
        upsert(
            SupermuxHarnessRow(id: "prompt-\(identity)", kind: .userPrompt(text: trimmed))
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

    private func toolRowID(_ toolUseID: String) -> String { "tool-\(toolUseID)" }

    private func existingToolCall(id toolUseID: String) -> SupermuxHarnessToolCall? {
        guard let index = indexByID[toolRowID(toolUseID)],
              case .toolCall(let call) = rows[index].kind else { return nil }
        return call
    }

    private mutating func upsert(_ row: SupermuxHarnessRow) {
        if let index = indexByID[row.id] {
            guard rows[index] != row else { return }
            rows[index] = row
            return
        }
        indexByID[row.id] = rows.count
        rows.append(row)
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
