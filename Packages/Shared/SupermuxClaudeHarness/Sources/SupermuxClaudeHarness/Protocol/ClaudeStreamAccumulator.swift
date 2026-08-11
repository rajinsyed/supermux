import Foundation

/// Reassembles partial-message stream events into in-flight messages and
/// reconciles them with the authoritative complete `assistant` lines.
///
/// Contract (from the protocol design):
/// - partial blocks are keyed by `(session_id, parent_tool_use_id, message.id,
///   block index)`; a missing `message_start` gets a synthetic message key;
/// - `input_json_delta` fragments are appended verbatim and decoded only at
///   `content_block_stop`; when final decoding fails the raw accumulated text
///   is preserved on the block and a diagnostic is emitted;
/// - the complete authoritative `assistant` line replaces the streamed draft
///   (never appends duplicate prose); multiple assistant lines sharing one API
///   message ID reconcile into one message, each carrying its just-completed
///   block;
/// - a streamed-vs-authoritative tool-input mismatch is diagnosed and the
///   authoritative input wins;
/// - an empty `thinking_delta` is legal and never terminates the block.
public struct ClaudeStreamAccumulator: Sendable {
    /// Identity of one accumulated message.
    public struct MessageKey: Sendable, Hashable {
        public let sessionID: String?
        public let parentToolUseID: String?
        /// The API message ID, or a `synthetic-N` key when `message_start`
        /// never arrived.
        public let messageID: String

        public init(sessionID: String?, parentToolUseID: String?, messageID: String) {
            self.sessionID = sessionID
            self.parentToolUseID = parentToolUseID
            self.messageID = messageID
        }
    }

    /// One accumulated content block.
    public struct Block: Sendable, Equatable {
        public let index: Int
        /// Best-known content: streamed draft until the authoritative
        /// assistant line replaces it.
        public var content: ClaudeContentBlock
        /// Accumulated verbatim `partial_json` for a streaming tool_use block.
        public var partialJSON: String?
        /// The raw accumulated text kept when final input decoding failed.
        public var undecodablePartialJSON: String?
        /// `content_block_stop` observed.
        public var isComplete: Bool
        /// The complete assistant line replaced this block.
        public var isAuthoritative: Bool
    }

    /// One in-flight or completed accumulated message.
    public struct Message: Sendable, Equatable {
        public let key: MessageKey
        public var role: String?
        public var model: String?
        /// Blocks ordered by stream index.
        public var blocks: [Block]
        public var stopReason: String?
        public var usage: ClaudeUsage?
        /// `message_stop` observed or the authoritative line carried a stop
        /// reason.
        public var isComplete: Bool
    }

    /// One observable accumulation outcome.
    public enum Event: Sendable, Equatable {
        /// The identified message changed (new block, delta, or reconciliation).
        case messageChanged(Message)
        /// A non-fatal accumulation observation.
        case diagnostic(ClaudeHarnessDiagnostic)
    }

    /// The active-stream key: only one message streams at a time per
    /// `(session, parent tool use)` pair.
    private struct StreamKey: Hashable {
        let sessionID: String?
        let parentToolUseID: String?
    }

    private var drafts: [MessageKey: Message] = [:]
    private var order: [MessageKey] = []
    private var activeMessage: [StreamKey: MessageKey] = [:]
    /// Count of authoritative blocks applied per message, used to place
    /// non-tool blocks from per-block assistant snapshots.
    private var reconciledCounts: [MessageKey: Int] = [:]
    private var syntheticCounter: UInt64 = 0

    public init() {}

    /// All accumulated messages in arrival order.
    public var messages: [Message] {
        order.compactMap { drafts[$0] }
    }

    /// Consumes one typed line; lines other than `stream_event`/`assistant`
    /// are ignored.
    public mutating func consume(_ line: ClaudeStreamLine) -> [Event] {
        switch line {
        case .streamEvent(let envelope):
            return consume(envelope)
        case .assistant(let envelope):
            return reconcile(envelope)
        default:
            return []
        }
    }

    // MARK: - Streaming

    private mutating func consume(_ envelope: ClaudeStreamEventEnvelope) -> [Event] {
        let streamKey = StreamKey(
            sessionID: envelope.sessionID,
            parentToolUseID: envelope.parentToolUseID
        )
        switch envelope.event {
        case .messageStart(let message):
            let key = MessageKey(
                sessionID: envelope.sessionID,
                parentToolUseID: envelope.parentToolUseID,
                messageID: message.id ?? nextSyntheticID()
            )
            activeMessage[streamKey] = key
            var draft = drafts[key] ?? Message(
                key: key, role: nil, model: nil, blocks: [],
                stopReason: nil, usage: nil, isComplete: false
            )
            draft.role = message.role ?? draft.role
            draft.model = message.model ?? draft.model
            store(draft)
            return [.messageChanged(draft)]

        case .contentBlockStart(let index, let block):
            var draft = activeDraft(for: streamKey)
            var accumulated = Block(
                index: index,
                content: block,
                partialJSON: nil,
                undecodablePartialJSON: nil,
                isComplete: false,
                isAuthoritative: false
            )
            if case .toolUse = block {
                accumulated.partialJSON = ""
            }
            draft.blocks.removeAll { $0.index == index && !$0.isAuthoritative }
            draft.blocks.append(accumulated)
            draft.blocks.sort { $0.index < $1.index }
            store(draft)
            return [.messageChanged(draft)]

        case .contentBlockDelta(let index, let delta):
            var draft = activeDraft(for: streamKey)
            guard let position = draft.blocks.firstIndex(where: { $0.index == index }) else {
                return []
            }
            apply(delta, to: &draft.blocks[position])
            store(draft)
            return [.messageChanged(draft)]

        case .contentBlockStop(let index):
            var draft = activeDraft(for: streamKey)
            guard let position = draft.blocks.firstIndex(where: { $0.index == index }) else {
                return []
            }
            var events: [Event] = []
            draft.blocks[position].isComplete = true
            events.append(contentsOf: decodeToolInputAtStop(
                block: &draft.blocks[position],
                messageID: draft.key.messageID
            ))
            store(draft)
            events.append(.messageChanged(draft))
            return events

        case .messageDelta(let delta, let usage, _):
            var draft = activeDraft(for: streamKey)
            draft.stopReason = delta.stopReason ?? draft.stopReason
            draft.usage = usage ?? draft.usage
            store(draft)
            return [.messageChanged(draft)]

        case .messageStop:
            guard let key = activeMessage[streamKey], var draft = drafts[key] else {
                return []
            }
            draft.isComplete = true
            store(draft)
            activeMessage[streamKey] = nil
            return [.messageChanged(draft)]

        case .unknown:
            return []
        }
    }

    private mutating func apply(_ delta: ClaudeStreamDelta, to block: inout Block) {
        switch delta {
        case .text(let text):
            if case .text(let existing, let citations) = block.content {
                block.content = .text(text: existing + text, citations: citations)
            }
        case .thinking(let text, _):
            // Empty thinking text carries progress only; appending "" is a
            // no-op that must not hide or terminate the block.
            if case .thinking(let existing, let signature) = block.content {
                block.content = .thinking(thinking: existing + text, signature: signature)
            }
        case .signature(let signature):
            if case .thinking(let existing, _) = block.content {
                block.content = .thinking(thinking: existing, signature: signature)
            }
        case .inputJSON(let fragment):
            block.partialJSON = (block.partialJSON ?? "") + fragment
        case .unknown:
            break
        }
    }

    /// Decodes accumulated `partial_json` exactly once, at block stop.
    /// A block the authoritative assistant line already replaced is left
    /// alone (on the wire, `content_block_stop` follows the assistant line).
    private func decodeToolInputAtStop(block: inout Block, messageID: String) -> [Event] {
        guard !block.isAuthoritative,
              case .toolUse(let id, let name, let input, let caller) = block.content,
              let partial = block.partialJSON, !partial.isEmpty else {
            return []
        }
        if let decoded = try? JSONDecoder().decode(
            ClaudeJSONValue.self, from: Data(partial.utf8)
        ) {
            block.content = .toolUse(id: id, name: name, input: decoded, caller: caller)
            return []
        }
        // Malformed partial input: keep the raw text and the original
        // (typically empty) input; the authoritative line reconciles later.
        block.undecodablePartialJSON = partial
        _ = input
        return [.diagnostic(.toolInputUndecodable(toolUseID: id, messageID: messageID))]
    }

    // MARK: - Reconciliation

    /// Applies one authoritative complete `assistant` line. Each such line
    /// carries the just-completed block(s) for its message ID; the streamed
    /// draft content is replaced, never duplicated.
    private mutating func reconcile(_ envelope: ClaudeMessageEnvelope) -> [Event] {
        let key = MessageKey(
            sessionID: envelope.sessionID,
            parentToolUseID: envelope.parentToolUseID,
            messageID: envelope.message.id ?? nextSyntheticID()
        )
        var draft = drafts[key] ?? adoptSyntheticDraft(for: envelope, key: key) ?? Message(
            key: key, role: nil, model: nil, blocks: [],
            stopReason: nil, usage: nil, isComplete: false
        )
        draft.role = envelope.message.role ?? draft.role
        draft.model = envelope.message.model ?? draft.model
        draft.stopReason = envelope.message.stopReason ?? draft.stopReason
        draft.usage = envelope.message.usage ?? draft.usage

        var events: [Event] = []
        var reconciled = reconciledCounts[key] ?? 0
        for authoritative in envelope.message.content {
            if case .toolUse(let id, _, let input, _) = authoritative {
                // Match streamed tool blocks by tool-use ID.
                if let position = draft.blocks.firstIndex(where: { block in
                    if case .toolUse(let draftID, _, _, _) = block.content {
                        return draftID == id
                    }
                    return false
                }) {
                    if let mismatch = toolInputMismatch(
                        streamed: draft.blocks[position], authoritativeInput: input, toolUseID: id
                    ) {
                        events.append(mismatch)
                    }
                    draft.blocks[position].content = authoritative
                    draft.blocks[position].isComplete = true
                    draft.blocks[position].isAuthoritative = true
                    draft.blocks[position].undecodablePartialJSON = nil
                    reconciled += 1
                    continue
                }
            }
            // Non-tool blocks (or unmatched tools): authoritative snapshots
            // arrive in block order, so the n-th reconciled block replaces the
            // draft block at position n.
            if reconciled < draft.blocks.count {
                draft.blocks[reconciled].content = authoritative
                draft.blocks[reconciled].isComplete = true
                draft.blocks[reconciled].isAuthoritative = true
            } else {
                draft.blocks.append(Block(
                    index: draft.blocks.count,
                    content: authoritative,
                    partialJSON: nil,
                    undecodablePartialJSON: nil,
                    isComplete: true,
                    isAuthoritative: true
                ))
            }
            reconciled += 1
        }
        reconciledCounts[key] = reconciled
        if draft.stopReason != nil {
            draft.isComplete = true
        }
        store(draft)
        events.append(.messageChanged(draft))
        return events
    }

    /// Compares the reassembled streamed input against the authoritative one.
    /// On the wire the assistant line precedes `content_block_stop`, so the
    /// comparison decodes the accumulated `partial_json` directly.
    private func toolInputMismatch(
        streamed: Block, authoritativeInput: ClaudeJSONValue, toolUseID: String
    ) -> Event? {
        guard let partial = streamed.partialJSON, !partial.isEmpty,
              let reassembled = try? JSONDecoder().decode(
                  ClaudeJSONValue.self, from: Data(partial.utf8)
              ),
              reassembled != authoritativeInput else { return nil }
        return .diagnostic(.toolInputMismatch(toolUseID: toolUseID))
    }

    /// When assistant lines arrive for a message whose `message_start` was
    /// missed, the active synthetic draft (same stream, synthetic ID) is
    /// re-keyed to the authoritative message ID.
    private mutating func adoptSyntheticDraft(
        for envelope: ClaudeMessageEnvelope, key: MessageKey
    ) -> Message? {
        let streamKey = StreamKey(
            sessionID: envelope.sessionID,
            parentToolUseID: envelope.parentToolUseID
        )
        guard let activeKey = activeMessage[streamKey],
              activeKey.messageID.hasPrefix("synthetic-"),
              let synthetic = drafts[activeKey] else { return nil }
        drafts.removeValue(forKey: activeKey)
        if let position = order.firstIndex(of: activeKey) {
            order[position] = key
        }
        reconciledCounts[key] = reconciledCounts.removeValue(forKey: activeKey) ?? 0
        activeMessage[streamKey] = key
        let adopted = Message(
            key: key,
            role: synthetic.role,
            model: synthetic.model,
            blocks: synthetic.blocks,
            stopReason: synthetic.stopReason,
            usage: synthetic.usage,
            isComplete: synthetic.isComplete
        )
        // Register under the new key so `store` sees it as existing and does
        // not append the key to `order` a second time.
        drafts[key] = adopted
        return adopted
    }

    // MARK: - Storage

    private mutating func store(_ message: Message) {
        if drafts[message.key] == nil {
            order.append(message.key)
        }
        drafts[message.key] = message
    }

    private mutating func activeDraft(for streamKey: StreamKey) -> Message {
        if let key = activeMessage[streamKey], let draft = drafts[key] {
            return draft
        }
        // Deltas without message_start get a synthetic message key.
        let key = MessageKey(
            sessionID: streamKey.sessionID,
            parentToolUseID: streamKey.parentToolUseID,
            messageID: nextSyntheticID()
        )
        activeMessage[streamKey] = key
        let draft = Message(
            key: key, role: nil, model: nil, blocks: [],
            stopReason: nil, usage: nil, isComplete: false
        )
        store(draft)
        return draft
    }

    private mutating func nextSyntheticID() -> String {
        syntheticCounter += 1
        return "synthetic-\(syntheticCounter)"
    }
}
