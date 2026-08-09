public import CmuxAgentChat
public import CmuxAgentChatUI
public import SwiftUI

/// Renders one ``ChatTranscriptRow`` in the supermux design language.
///
/// This is the fork's replacement for upstream's row dispatcher. It consumes
/// exactly the same immutable snapshot and the same `ChatRowActions` bundle,
/// so it inherits upstream's detail sheets, artifact routing, and history
/// paging without reimplementing any of them.
///
/// `Equatable` so the transcript's `.equatable()` short-circuit still skips
/// body evaluation for rows whose snapshot did not change while content
/// streams in around them.
public struct SupermuxChatRowView: View, Equatable {
    private let row: ChatTranscriptRow
    private let actions: ChatRowActions

    @Environment(\.supermuxChatTheme) private var theme
    @Environment(\.chatContentCache) private var contentCache

    /// Creates the dispatcher.
    ///
    /// - Parameters:
    ///   - row: The row snapshot to render.
    ///   - actions: Row action bundle.
    public init(row: ChatTranscriptRow, actions: ChatRowActions) {
        self.row = row
        self.actions = actions
    }

    /// Compares only render-relevant value state; the action closures are
    /// intentionally excluded, matching upstream's contract.
    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    public var body: some View {
        content
            .padding(.top, theme.rowSpacing)
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .dateHeader(let day):
            SupermuxChatDateHeader(day: day)
        case .unreadSeparator:
            SupermuxChatUnreadSeparator()
        case .message(let snapshot):
            messageView(snapshot)
        case .pendingOutbound(let pending):
            SupermuxChatUserBubble(
                text: pending.text,
                timestamp: pending.createdAt,
                showsTimestamp: false
            )
            .opacity(0.55)
        case .terminalCommand(let block):
            SupermuxChatTerminalCard(
                capture: ChatTerminalCapture(
                    command: block.command,
                    output: block.output,
                    exitCode: block.exitCode,
                    isRunning: block.isRunning
                ),
                rowID: "term-\(block.id)",
                outputLines: terminalLines(id: "term-\(block.id)", output: block.output),
                onShowDetail: { actions.showTerminalCommandDetail(block) }
            )
        }
    }

    @ViewBuilder
    private func messageView(_ snapshot: ChatMessageRowSnapshot) -> some View {
        let message = snapshot.message
        let rowID = ChatTranscriptRow.message(snapshot).id

        switch message.kind {
        case .prose(let prose):
            if message.role == .user {
                SupermuxChatUserBubble(
                    text: prose.text,
                    timestamp: message.timestamp,
                    showsTimestamp: snapshot.showsTimestamp,
                    onCopied: actions.notifyCopied
                )
            } else {
                SupermuxChatProseView(
                    prose: prose,
                    messageID: message.id,
                    onShowCodeDetail: actions.showCodeBlockDetail,
                    onCopied: actions.notifyCopied
                )
            }

        case .thought:
            SupermuxChatActivityRow(
                symbolName: "brain",
                phrase: SupermuxChatActivityPhrase(verb: Self.thoughtTitle, target: ""),
                accessibilityID: "SupermuxChatThought-\(rowID)",
                onTap: { actions.showMessageDetail(message) }
            )

        case .toolUse(let toolUse):
            SupermuxChatActivityRow(
                symbolName: SupermuxChatActivityPhrase.symbolName(forToolName: toolUse.toolName),
                phrase: SupermuxChatActivityPhrase.phrase(
                    toolName: toolUse.toolName,
                    summary: toolUse.summary,
                    isRunning: toolUse.status == .running
                ),
                isFailed: toolUse.status == .failed,
                accessibilityID: "SupermuxChatToolUse-\(rowID)",
                onTap: { actions.showMessageDetail(message) }
            )

        case .terminal(let capture):
            SupermuxChatTerminalCard(
                capture: capture,
                rowID: rowID,
                outputLines: terminalLines(id: rowID, output: capture.output),
                onShowDetail: { actions.showMessageDetail(message) }
            )

        case .fileEdit(let edit):
            SupermuxChatFileEditCard(
                edit: edit,
                rowID: rowID,
                diffLines: diffLines(id: rowID, diff: edit.unifiedDiff),
                onShowDetail: { actions.showMessageDetail(message) }
            )

        case .permissionRequest(let request):
            SupermuxChatPermissionCard(
                request: request,
                timestamp: message.timestamp,
                onAnswer: actions.answerOption
            )

        case .question(let question):
            SupermuxChatQuestionCard(
                question: question,
                onAnswer: actions.answerOption
            )

        case .status(let transition):
            SupermuxChatStatusRow(transition: transition)

        case .attachment(let attachment):
            SupermuxChatAttachmentRow(
                attachment: attachment,
                onOpenArtifact: actions.openArtifact
            )

        case .unsupported(let payload):
            SupermuxChatActivityRow(
                symbolName: "questionmark.square.dashed",
                phrase: SupermuxChatActivityPhrase(
                    verb: Self.unsupportedTitle,
                    target: payload.rawType
                ),
                showsDisclosure: false,
                accessibilityID: "SupermuxChatUnsupported-\(rowID)"
            )
        }
    }

    /// Reuses upstream's per-row sanitized-output cache so re-rendering a
    /// streaming transcript does not re-scan ANSI escapes every frame.
    private func terminalLines(id: String, output: String?) -> [String] {
        guard let output, !output.isEmpty else { return [] }
        if let contentCache {
            return contentCache.sanitizedLines(messageID: id, output: output)
        }
        return ChatANSISanitizer()
            .sanitized(output)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func diffLines(id: String, diff: String?) -> [String] {
        guard let diff, !diff.isEmpty else { return [] }
        if let contentCache {
            return contentCache.diffLines(messageID: id, diff: diff)
        }
        return diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static let thoughtTitle = String(
        localized: "supermux.chat.thought",
        defaultValue: "Thought",
        bundle: .module
    )

    static let unsupportedTitle = String(
        localized: "supermux.chat.unsupported",
        defaultValue: "Unsupported",
        bundle: .module
    )
}
