public import CmuxAgentChat
public import SwiftUI

/// A day divider ("Today", "9 June").
public struct SupermuxChatDateHeader: View {
    private let day: Date

    /// Creates a date header.
    public init(day: Date) {
        self.day = day
    }

    public var body: some View {
        Text(title)
            .font(.supermuxChatCaption(.medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    private var title: String {
        if Calendar.current.isDateInToday(day) {
            return String(
                localized: "supermux.chat.date.today",
                defaultValue: "Today",
                bundle: .module
            )
        }
        if Calendar.current.isDateInYesterday(day) {
            return String(
                localized: "supermux.chat.date.yesterday",
                defaultValue: "Yesterday",
                bundle: .module
            )
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// The "unread from here" marker.
public struct SupermuxChatUnreadSeparator: View {
    @Environment(\.supermuxChatTheme) private var theme

    /// Creates an unread separator.
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            line
            Text(
                String(
                    localized: "supermux.chat.unread",
                    defaultValue: "New",
                    bundle: .module
                )
            )
            .font(.supermuxChatCaption(.semibold))
            .foregroundStyle(theme.running)
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(theme.running.opacity(0.4))
            .frame(height: 0.5)
    }
}

/// A session lifecycle transition, centered and quiet.
public struct SupermuxChatStatusRow: View {
    private let transition: ChatStatusTransition

    /// Creates a status row.
    public init(transition: ChatStatusTransition) {
        self.transition = transition
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 10))
            Text(title)
                .font(.supermuxChatCaption())
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch transition.event {
        case .sessionStarted: return "play.circle"
        case .sessionEnded: return "stop.circle"
        case .interrupted: return "exclamationmark.circle"
        case .contextCompacted: return "arrow.down.right.and.arrow.up.left"
        }
    }

    private var title: String {
        if let detail = transition.detail, !detail.isEmpty { return detail }
        switch transition.event {
        case .sessionStarted:
            return String(
                localized: "supermux.chat.status.started",
                defaultValue: "Session started",
                bundle: .module
            )
        case .sessionEnded:
            return String(
                localized: "supermux.chat.status.ended",
                defaultValue: "Session ended",
                bundle: .module
            )
        case .interrupted:
            return String(
                localized: "supermux.chat.status.interrupted",
                defaultValue: "Interrupted",
                bundle: .module
            )
        case .contextCompacted:
            return String(
                localized: "supermux.chat.status.compacted",
                defaultValue: "Context compacted",
                bundle: .module
            )
        }
    }
}

/// A file or image the user attached to a prompt.
public struct SupermuxChatAttachmentRow: View {
    private let attachment: ChatAttachment
    private let onOpenArtifact: (String) -> Void

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates an attachment row.
    ///
    /// - Parameters:
    ///   - attachment: The attachment payload.
    ///   - onOpenArtifact: Opens the artifact viewer for a host path.
    public init(
        attachment: ChatAttachment,
        onOpenArtifact: @escaping (String) -> Void
    ) {
        self.attachment = attachment
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: theme.outgoingLeadingGutter)
            Button(action: open) {
                HStack(spacing: 7) {
                    Image(systemName: attachment.media == .image ? "photo" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(.supermuxChatFootnote())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(theme.elevatedFill, in: .capsule)
                .overlay { Capsule().strokeBorder(theme.hairline, lineWidth: 0.5) }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(attachment.hostPath == nil)
        }
        .accessibilityElement(children: .combine)
    }

    private func open() {
        guard let path = attachment.hostPath else { return }
        onOpenArtifact(path)
    }

    private var displayName: String {
        if let name = attachment.displayName, !name.isEmpty { return name }
        if let path = attachment.hostPath,
           let last = path.split(separator: "/").last {
            return String(last)
        }
        return String(
            localized: "supermux.chat.attachment",
            defaultValue: "Attachment",
            bundle: .module
        )
    }
}
