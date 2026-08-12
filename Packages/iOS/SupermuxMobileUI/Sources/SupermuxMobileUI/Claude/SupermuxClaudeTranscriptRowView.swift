public import SupermuxMobileCore
public import SwiftUI

/// One transcript row: a user bubble, assistant markdown, a thinking
/// disclosure, a tool card, or a status line.
///
/// Takes only VALUES — the projected row plus two closures. Nothing here
/// holds a store reference, which is what makes it safe below the transcript
/// list's lazy boundary (the SwiftUI list-boundary rule in CLAUDE.md).
public struct SupermuxClaudeTranscriptRowView: View {
    private let row: SupermuxClaudeTranscriptRow
    private let loadFullPayload: @MainActor (String) async -> String?

    /// Creates a transcript row.
    /// - Parameters:
    ///   - row: The projected row.
    ///   - loadFullPayload: Fetches a message's untruncated tool body through
    ///     `claude.tool_payload`; returns `nil` on failure.
    public init(
        row: SupermuxClaudeTranscriptRow,
        loadFullPayload: @escaping @MainActor (String) async -> String? = { _ in nil }
    ) {
        self.row = row
        self.loadFullPayload = loadFullPayload
    }

    public var body: some View {
        switch row.content {
        case .userPrompt(let text):
            userBubble(text)
        case .assistantProse(let text):
            SupermuxClaudeMarkdownText(messageID: row.id, markdown: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text):
            SupermuxClaudeThinkingDisclosure(messageID: row.id, text: text)
        case .tool(let tool):
            SupermuxClaudeToolCard(
                messageID: row.id,
                tool: tool,
                loadFullPayload: loadFullPayload
            )
        case .status(let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The sent-prompt bubble: right-aligned with a leading gutter, so it
    /// reads as "from the user" without needing an avatar.
    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: SupermuxClaudeStyle.bubbleLeadingGutter)
            Text(text)
                .font(SupermuxClaudeStyle.body())
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    .quaternary,
                    in: RoundedRectangle(
                        cornerRadius: SupermuxClaudeStyle.bubbleCornerRadius,
                        style: .continuous
                    )
                )
        }
    }
}

/// Extended thinking, collapsed by default.
///
/// Collapsed because thinking is usually far longer than the answer it
/// precedes, and an expanded-by-default transcript would bury every reply.
public struct SupermuxClaudeThinkingDisclosure: View {
    private let messageID: String
    private let text: String

    @State private var isExpanded = false

    /// Creates a thinking disclosure.
    /// - Parameters:
    ///   - messageID: Stable identity for the markdown cache.
    ///   - text: The thinking content.
    public init(messageID: String, text: String) {
        self.messageID = messageID
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "supermux.claude.thinking",
                        defaultValue: "Thinking",
                        bundle: .module
                    ))
                    .font(.footnote.weight(.medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SupermuxClaudeMarkdownText(messageID: messageID, markdown: text)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool invocation: a humanized headline, a bounded summary, and — for a
/// completed tool — an affordance that fetches the untruncated body.
///
/// `TodoWrite` renders as a progress card instead (``SupermuxClaudeTodoCard``).
public struct SupermuxClaudeToolCard: View {
    private let messageID: String
    private let tool: SupermuxClaudeToolDTO
    private let loadFullPayload: @MainActor (String) async -> String?

    @State private var fullPayload: String?
    @State private var isLoadingPayload = false

    /// Creates a tool card.
    /// - Parameters:
    ///   - messageID: The owning message's identifier.
    ///   - tool: The bounded tool summary.
    ///   - loadFullPayload: Fetches the untruncated body.
    public init(
        messageID: String,
        tool: SupermuxClaudeToolDTO,
        loadFullPayload: @escaping @MainActor (String) async -> String? = { _ in nil }
    ) {
        self.messageID = messageID
        self.tool = tool
        self.loadFullPayload = loadFullPayload
    }

    public var body: some View {
        if SupermuxClaudeTodoPresentation.isTodoList(tool) {
            SupermuxClaudeTodoCard(tool: tool)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let summary = tool.inputSummary, !summary.isEmpty {
                Text(summary)
                    .font(SupermuxClaudeStyle.mono(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(fullPayload == nil ? 3 : nil)
                    .textSelection(.enabled)
            }
            if let output = fullPayload ?? tool.outputSummary, !output.isEmpty {
                Text(output)
                    .font(SupermuxClaudeStyle.mono(size: 12))
                    .foregroundStyle(
                        SupermuxClaudeTranscriptPresentation.isFailed(tool) ? .red : .secondary
                    )
                    .lineLimit(fullPayload == nil ? 6 : nil)
                    .textSelection(.enabled)
            }
            if fullPayload == nil, SupermuxClaudeTranscriptPresentation.offersFullPayload(tool) {
                Button {
                    Task { await loadPayload() }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingPayload {
                            ProgressView().controlSize(.small)
                        }
                        Text(String(
                            localized: "supermux.claude.tool.showFull",
                            defaultValue: "Show full output",
                            bundle: .module
                        ))
                        .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(isLoadingPayload)
            }
        }
        .padding(SupermuxClaudeStyle.tightSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(
            cornerRadius: SupermuxClaudeStyle.cardCornerRadius,
            style: .continuous
        ))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: SupermuxClaudeTranscriptPresentation.isFailed(tool)
                ? "exclamationmark.triangle"
                : "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(
                    SupermuxClaudeTranscriptPresentation.isFailed(tool) ? .red : .secondary
                )
                .accessibilityHidden(true)
            if tool.isComplete {
                Text(SupermuxClaudeTranscriptPresentation.toolTitle(tool))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                // A running tool shimmers its own label rather than spinning a
                // separate indicator: the sentence IS what is in progress.
                SupermuxChatShimmerText(
                    text: SupermuxClaudeTranscriptPresentation.toolTitle(tool)
                )
                .equatable()
            }
            Spacer(minLength: 0)
        }
    }

    private func loadPayload() async {
        isLoadingPayload = true
        defer { isLoadingPayload = false }
        fullPayload = await loadFullPayload(messageID)
    }
}

/// The `TodoWrite` card: a progress ring over the parsed to-do rows.
public struct SupermuxClaudeTodoCard: View {
    private let tool: SupermuxClaudeToolDTO

    /// Creates a to-do card.
    /// - Parameter tool: The `TodoWrite` tool summary.
    public init(tool: SupermuxClaudeToolDTO) {
        self.tool = tool
    }

    public var body: some View {
        let todos = SupermuxClaudeTodoPresentation.todos(in: tool)
        // An unparseable payload falls back to the ordinary tool card rather
        // than rendering an empty ring — the content still shows.
        if todos.isEmpty {
            SupermuxClaudeToolCard(messageID: tool.toolUseID, tool: tool)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SupermuxClaudeProgressRing(
                        progress: SupermuxClaudeTodoPresentation.progress(todos)
                    )
                    Text(SupermuxClaudeTodoPresentation.counter(todos))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                ForEach(todos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: todo.status))
                            .font(.caption)
                            .foregroundStyle(todo.status == .completed ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(todo.title)
                            .font(SupermuxClaudeStyle.body())
                            .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                            .strikethrough(todo.status == .completed)
                    }
                }
            }
            .padding(SupermuxClaudeStyle.tightSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(
                cornerRadius: SupermuxClaudeStyle.cardCornerRadius,
                style: .continuous
            ))
        }
    }

    private func symbol(for status: SupermuxClaudeTodo.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted"
        case .pending: "circle"
        }
    }
}

/// A small completion ring.
public struct SupermuxClaudeProgressRing: View, Equatable {
    private let progress: Double

    /// Creates a progress ring.
    /// - Parameter progress: Completion fraction, 0...1.
    public init(progress: Double) {
        self.progress = progress
    }

    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.progress == rhs.progress
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
