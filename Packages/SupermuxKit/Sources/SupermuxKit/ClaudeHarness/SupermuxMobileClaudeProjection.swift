public import Foundation
import SupermuxClaudeHarness
public import SupermuxMobileCore

/// Projects retained Claude protocol lines into mobile messages and payloads.
public struct SupermuxMobileClaudeProjection: Sendable {
    /// Maximum UTF-8 bytes embedded for tool input or output in an event.
    public static let eventToolOutputLimit = 4 * 1024

    /// Ordered compact messages, with streaming blocks replaced wholesale by id.
    public let messages: [SupermuxClaudeChatMessageDTO]
    /// Full tool payload bytes keyed by the enclosing mobile message identifier.
    public let toolPayloads: [String: Data]

    /// Creates a deterministic projection from retained transcript lines.
    /// - Parameter lines: Typed protocol lines in ascending sequence order.
    public init(lines: [ClaudeTranscriptLine]) {
        var accumulator = ClaudeStreamAccumulator()
        var messagesByID: [String: SupermuxClaudeChatMessageDTO] = [:]
        var order: [String] = []
        var payloads: [String: Data] = [:]

        func upsert(_ message: SupermuxClaudeChatMessageDTO) {
            if messagesByID[message.id] == nil { order.append(message.id) }
            messagesByID[message.id] = message
        }

        for transcript in lines {
            for event in accumulator.consume(transcript.line) {
                guard case .messageChanged(let message) = event else { continue }
                for block in message.blocks {
                    let id = "\(message.key.messageID)-\(block.index)"
                    switch block.content {
                    case .text(let text, _):
                        guard !text.isEmpty else { continue }
                        upsert(.init(id: id, seq: transcript.seq, role: .assistant,
                                     timestamp: 0, kind: .prose, text: text))
                    case .thinking(let text, _):
                        guard !text.isEmpty else { continue }
                        upsert(.init(id: id, seq: transcript.seq, role: .assistant,
                                     timestamp: 0, kind: .thought, text: text))
                    case .toolUse(let toolID, let name, let input, _):
                        guard !toolID.isEmpty else { continue }
                        let messageID = "tool-\(toolID)"
                        let inputData = (try? JSONEncoder().encode(input)) ?? Data()
                        payloads[messageID] = inputData
                        let summary = Self.bounded(String(data: inputData, encoding: .utf8))
                        let existing = messagesByID[messageID]
                        upsert(.init(
                            id: messageID, seq: existing?.seq ?? transcript.seq,
                            role: .assistant, timestamp: 0, kind: .tool,
                            tool: .init(
                                toolUseID: toolID, name: name, title: name,
                                inputSummary: summary,
                                outputSummary: existing?.tool?.outputSummary,
                                isError: existing?.tool?.isError,
                                isComplete: existing?.tool?.isComplete ?? false
                            )
                        ))
                    case .toolResult, .image, .document, .unknown:
                        break
                    }
                }
            }

            switch transcript.line {
            case .user(let envelope):
                var handledTool = false
                for block in envelope.message.content {
                    guard case .toolResult(let toolID, let content, let isError) = block,
                          let toolID else { continue }
                    handledTool = true
                    let messageID = "tool-\(toolID)"
                    let output = content.plainText
                    payloads[messageID] = Data(output.utf8)
                    let existing = messagesByID[messageID]
                    upsert(.init(
                        id: messageID, seq: existing?.seq ?? transcript.seq,
                        role: .assistant, timestamp: Self.timestamp(envelope.timestamp), kind: .tool,
                        tool: .init(
                            toolUseID: toolID,
                            name: existing?.tool?.name ?? "tool",
                            title: existing?.tool?.title ?? "Tool",
                            inputSummary: existing?.tool?.inputSummary,
                            outputSummary: Self.bounded(output),
                            isError: isError,
                            isComplete: true
                        )
                    ))
                }
                guard !handledTool else { break }
                let text = envelope.message.content.compactMap { block -> String? in
                    if case .text(let text, _) = block { return text }
                    return nil
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { break }
                let id = "prompt-\(envelope.uuid ?? String(transcript.seq))"
                upsert(.init(id: id, seq: transcript.seq, role: .user,
                             timestamp: Self.timestamp(envelope.timestamp), kind: .prose, text: text))
            case .system(let event):
                if case .notification(let notification) = event,
                   let text = notification.text, !text.isEmpty {
                    upsert(.init(id: "status-\(transcript.seq)", seq: transcript.seq,
                                 role: .system, timestamp: 0, kind: .status, text: text))
                }
            case .result(let result):
                let text = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
                if let text, !text.isEmpty {
                    upsert(.init(id: "result-\(transcript.seq)", seq: transcript.seq,
                                 role: .system, timestamp: 0, kind: .status, text: text))
                }
            case .assistant, .streamEvent, .controlRequest, .controlResponse, .unknown:
                break
            }
        }
        self.messages = order.compactMap { messagesByID[$0] }.sorted { $0.seq < $1.seq }
        self.toolPayloads = payloads
    }

    private static func bounded(_ text: String?) -> String? {
        guard let text else { return nil }
        let data = Data(text.utf8)
        guard data.count > eventToolOutputLimit else { return text }
        var prefix = Data(data.prefix(eventToolOutputLimit))
        while !prefix.isEmpty {
            if let bounded = String(data: prefix, encoding: .utf8) { return bounded }
            prefix.removeLast()
        }
        return ""
    }

    private static func timestamp(_ value: String?) -> Double {
        guard let value else { return 0 }
        return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? 0
    }
}
