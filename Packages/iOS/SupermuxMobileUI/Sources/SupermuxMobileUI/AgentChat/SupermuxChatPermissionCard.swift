public import CMUXMobileCore
public import CmuxAgentChat
public import SwiftUI

/// A permission request awaiting the user's decision.
///
/// The one row on the surface that is allowed to shout: it carries an accent
/// border because it is the only thing that *blocks* the agent, and a user
/// scrolling a long transcript has to be able to find it instantly. Once
/// resolved it collapses to a quiet receipt line.
public struct SupermuxChatPermissionCard: View {
    private let request: ChatPermissionRequest
    private let timestamp: Date
    private let onAnswer: (Int) -> Void

    @Environment(\.supermuxChatTheme) private var theme

    /// Set on the first tap so the buttons disarm immediately: answering is
    /// key injection over a Mac round-trip, and a second tap before the
    /// receipt echoes back would select a different option.
    @State private var tappedIndex: Int?

    /// Creates a permission card.
    ///
    /// - Parameters:
    ///   - request: The permission payload, pending or resolved.
    ///   - timestamp: When the request was raised.
    ///   - onAnswer: Sends the chosen option index.
    public init(
        request: ChatPermissionRequest,
        timestamp: Date,
        onAnswer: @escaping (Int) -> Void
    ) {
        self.request = request
        self.timestamp = timestamp
        self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isPending ? theme.running : .secondary)
                Text(request.title)
                    .font(.supermuxChatSubheadline(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(request.subject)
                .font(.supermuxChatMono(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.elevatedFill, in: .rect(cornerRadius: 8, style: .continuous))

            if let resolution = request.resolution {
                receipt(resolution)
            } else {
                decisionButtons
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.cardCornerRadius, style: .continuous)
                .fill(theme.elevatedFill.opacity(isPending ? 0.6 : 0.35))
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    isPending ? theme.running : theme.hairline,
                    lineWidth: isPending ? 1.5 : 0.5
                )
        }
    }

    private var isPending: Bool { request.resolution == nil }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            Button { decide(1) } label: {
                Text(Self.denyTitle)
                    .font(.supermuxChatSubheadline(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(theme.hairline, lineWidth: 1)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SupermuxChatPermissionDeny")

            Button { decide(0) } label: {
                HStack(spacing: 6) {
                    if tappedIndex == 0 {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.outgoingText)
                    }
                    Text(Self.approveTitle)
                }
                .font(.supermuxChatSubheadline(.semibold))
                .foregroundStyle(theme.outgoingText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(theme.accent, in: .rect(cornerRadius: 11, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SupermuxChatPermissionApprove")
        }
        .disabled(tappedIndex != nil)
        .opacity(tappedIndex == nil ? 1 : 0.6)
    }

    private func decide(_ index: Int) {
        guard tappedIndex == nil else { return }
        tappedIndex = index
        #if os(iOS)
        MobileHapticFeedback().impact(style: .medium)
        #endif
        onAnswer(index)
    }

    private func receipt(_ resolution: ChatPermissionRequest.Resolution) -> some View {
        HStack(spacing: 5) {
            Image(systemName: receiptSymbol(resolution))
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: "\(receiptLabel(resolution)) · \(timestamp.formatted(.dateTime.hour().minute()))")
                .font(.supermuxChatCaption())
        }
        .foregroundStyle(.secondary)
    }

    private func receiptSymbol(_ resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved: return "checkmark"
        case .denied: return "xmark"
        case .expired: return "clock"
        }
    }

    private func receiptLabel(_ resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved:
            return String(
                localized: "supermux.chat.permission.approved",
                defaultValue: "Approved",
                bundle: .module
            )
        case .denied:
            return String(
                localized: "supermux.chat.permission.denied",
                defaultValue: "Denied",
                bundle: .module
            )
        case .expired:
            return String(
                localized: "supermux.chat.permission.expired",
                defaultValue: "Expired",
                bundle: .module
            )
        }
    }

    static let approveTitle = String(
        localized: "supermux.chat.permission.approve",
        defaultValue: "Approve",
        bundle: .module
    )

    static let denyTitle = String(
        localized: "supermux.chat.permission.deny",
        defaultValue: "Deny",
        bundle: .module
    )
}
