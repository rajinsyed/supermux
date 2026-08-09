public import CMUXMobileCore
public import CmuxAgentChat
public import SwiftUI

/// A multiple-choice question the agent asked.
///
/// Options are full-width rows rather than a horizontal row of chips: a
/// question's options are often sentences, and on a phone the only layout
/// that reads them all without truncating is one per line.
public struct SupermuxChatQuestionCard: View {
    private let question: ChatQuestion
    private let onAnswer: (Int) -> Void

    @Environment(\.supermuxChatTheme) private var theme

    /// Disarms the options after the first tap; answering is key injection
    /// over a Mac round-trip, so a second tap would pick a different option.
    @State private var tappedIndex: Int?

    /// Creates a question card.
    ///
    /// - Parameters:
    ///   - question: The question payload.
    ///   - onAnswer: Sends the chosen option index.
    public init(question: ChatQuestion, onAnswer: @escaping (Int) -> Void) {
        self.question = question
        self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt)
                .font(.supermuxChatBody())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(option, index: index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(_ option: ChatQuestion.Option, index: Int) -> some View {
        let isSelected = question.selectedOptionLabel == option.label
        let isAnswered = question.selectedOptionLabel != nil

        return Button { choose(index) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected
                        ? AnyShapeStyle(theme.accent)
                        : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.supermuxChatSubheadline(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.supermuxChatCaption())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if tappedIndex == index, !isAnswered {
                    ProgressView().controlSize(.small)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.elevatedFill.opacity(isSelected ? 1 : 0.55),
                in: .rect(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent.opacity(0.5) : theme.hairline,
                        lineWidth: isSelected ? 1 : 0.5
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || tappedIndex != nil)
        .accessibilityIdentifier("SupermuxChatQuestionOption-\(index)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func choose(_ index: Int) {
        guard tappedIndex == nil, question.selectedOptionLabel == nil else { return }
        tappedIndex = index
        #if os(iOS)
        MobileHapticFeedback().impact(style: .light)
        #endif
        onAnswer(index)
    }
}
