#if os(iOS)
public import CMUXMobileCore
public import CmuxAgentChat
public import CmuxAgentChatUI
public import PhotosUI
public import SwiftUI
import UIKit

/// The chat composer: a floating glass capsule at rest that morphs into a
/// full-width card on focus.
///
/// The morph is the point. At rest the composer is a narrow capsule inset from
/// the screen edges, so the transcript reads as the page and the composer as a
/// control floating over it. On focus it expands to full width and grows a
/// control row. The text field stays mounted across both states, so the
/// keyboard rises in the same motion as the morph instead of after a view swap.
public struct SupermuxChatComposer: View {
    private let agentState: ChatAgentState
    private let agentKind: ChatAgentKind
    private let isConnected: Bool
    private let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    private let accessoryShortcuts: [ChatAccessoryShortcut]
    private let onSend: (String, [ChatOutboundAttachment]) -> Void
    private let onInterrupt: (Bool) -> Void
    private let onOpenTerminal: () -> Void

    @Binding private var draft: String

    @Environment(\.supermuxChatTheme) private var theme
    @FocusState private var isFocused: Bool

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var isStagingAttachments = false
    @State private var lastStopTap: Date?

    /// The resting capsule's inline control side; the extra 2pt over 32 keeps
    /// it comfortable to hit without making the capsule look chunky.
    private let inlineControlSide: CGFloat = 34

    /// Extra horizontal inset applied only while collapsed, so the resting
    /// capsule reads as a floating control rather than an input bar.
    private static let collapsedInset: CGFloat = 24

    private static let maxAttachmentDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.85
    private static let hardStopWindow: TimeInterval = 2

    /// Creates a composer.
    ///
    /// - Parameters:
    ///   - agentState: Live agent presence; drives Stop.
    ///   - agentKind: Names the agent in the placeholder.
    ///   - isConnected: Whether sending is currently possible.
    ///   - draft: Host-owned draft, so it survives leaving and returning.
    ///   - accessoryShortcuts: Host-provided shortcut items.
    ///   - onSend: Sends text plus staged attachments.
    ///   - onInterrupt: Interrupts the turn; `true` means hard.
    ///   - onOpenTerminal: Opens the session's raw terminal.
    public init(
        agentState: ChatAgentState,
        agentKind: ChatAgentKind,
        isConnected: Bool,
        draft: Binding<String>,
        accessoryLeadingShortcuts: [ChatAccessoryShortcut] = [],
        accessoryShortcuts: [ChatAccessoryShortcut] = [],
        onSend: @escaping (String, [ChatOutboundAttachment]) -> Void,
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.agentState = agentState
        self.agentKind = agentKind
        self.isConnected = isConnected
        _draft = draft
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        SupermuxChatGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                if !isCollapsed, !attachments.isEmpty {
                    attachmentStrip
                }
                inputRow
                if !isCollapsed {
                    bottomBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .supermuxChatGlass(in: surfaceShape)
            .clipShape(surfaceShape)
            .padding(.horizontal, isCollapsed ? Self.collapsedInset : 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // The keyboard-tracking controller measures this view with a compressed
        // vertical fitting size and feeds the result to the composer height
        // constraint, the transcript's bottom inset, and the scroll-button
        // overlay. It must therefore be vertically intrinsic — a flexible
        // height here would mis-measure all three.
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.26), value: isCollapsed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SupermuxChatComposer")
    }

    /// Collapse whenever the composer is idle and empty. A running turn stays
    /// collapsed too and surfaces Stop inline, rather than expanding a card the
    /// user did not ask for.
    private var isCollapsed: Bool {
        !isFocused && draft.isEmpty && attachments.isEmpty
    }

    private var surfaceShape: RoundedRectangle {
        // Collapsed: half the row height, so the surface is a true capsule.
        RoundedRectangle(cornerRadius: isCollapsed ? (inlineControlSide + 12) / 2 : 26)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if isCollapsed {
                attachButton
            }

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(.supermuxChatBody())
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("SupermuxChatComposerField")

            if isCollapsed, isWorking {
                stopButton
            }
            if !isCollapsed || !draft.isEmpty {
                sendOrStopButton
            }
        }
        .padding(.leading, isCollapsed ? 6 : 14)
        .padding(.trailing, isCollapsed ? 6 : 8)
        .padding(.top, isCollapsed ? 6 : 12)
        .padding(.bottom, isCollapsed ? 6 : 4)
    }

    private var placeholder: String {
        String(
            localized: "supermux.chat.composer.placeholder",
            defaultValue: "Message \(agentKind.displayName)",
            bundle: .module
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            attachButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(accessoryLeadingShortcuts) { shortcut in
                        shortcutButton(shortcut)
                    }
                    ForEach(accessoryShortcuts) { shortcut in
                        shortcutButton(shortcut)
                    }
                }
            }
            if isWorking {
                stopButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    /// Host shortcuts arrive with deliberately empty actions for the two
    /// behaviors only the composer can perform — dismissing the keyboard and
    /// pasting into the field. Upstream's composer rebinds them through
    /// `semanticAction`; the fork composer must do the same or those two
    /// buttons silently do nothing.
    private func resolved(_ shortcut: ChatAccessoryShortcut) -> ChatAccessoryShortcut {
        switch shortcut.semanticAction {
        case .dismissKeyboard:
            return shortcut.replacingAction { isFocused = false }
        case .paste:
            return shortcut.replacingAction(performPaste)
        case nil:
            return shortcut
        }
    }

    private func performPaste() {
        let pasteboard = UIPasteboard.general
        if attachments.count < 4,
           let image = pasteboard.image,
           let encoded = image.jpegData(compressionQuality: Self.jpegQuality) {
            attachments.append(
                ChatComposerAttachment(
                    id: "pasted-\(attachments.count)-\(Int(Date().timeIntervalSince1970))",
                    data: encoded,
                    format: .jpeg,
                    thumbnail: Image(uiImage: image)
                )
            )
            isFocused = true
            return
        }
        guard let text = pasteboard.string else { return }
        draft += text
        isFocused = true
    }

    private func shortcutButton(_ rawShortcut: ChatAccessoryShortcut) -> some View {
        let shortcut = resolved(rawShortcut)
        return Button(action: shortcut.perform) {
            Group {
                if let systemImage = shortcut.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15))
                } else {
                    Text(shortcut.title)
                        .font(.supermuxChatFootnote(.medium))
                }
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shortcut.accessibilityLabel ?? shortcut.title)
    }

    // MARK: - Controls

    private var attachButton: some View {
        PhotosPicker(selection: $pickedItems, maxSelectionCount: 4, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: inlineControlSide, height: inlineControlSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatComposerAttach")
        .accessibilityLabel(
            String(
                localized: "supermux.chat.composer.attach",
                defaultValue: "Add attachment",
                bundle: .module
            )
        )
        .onChange(of: pickedItems) {
            let items = pickedItems
            Task { await loadPickedItems(items) }
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if hasContent {
            Button(action: performSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isConnected ? theme.outgoingText : .secondary)
                    .frame(width: inlineControlSide, height: inlineControlSide)
                    .background(
                        Circle().fill(isConnected
                            ? AnyShapeStyle(theme.accent)
                            : AnyShapeStyle(.quaternary))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isConnected || isStagingAttachments)
            .accessibilityIdentifier("SupermuxChatComposerSend")
            .accessibilityLabel(Self.sendLabel)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if isWorking, !isCollapsed {
            stopButton
        }
    }

    private var stopButton: some View {
        Button(action: performStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: inlineControlSide, height: inlineControlSide)
                .background(Circle().fill(theme.failure))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SupermuxChatComposerStop")
        .accessibilityLabel(
            String(
                localized: "supermux.chat.composer.stop",
                defaultValue: "Stop",
                bundle: .module
            )
        )
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    attachment.thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            removeButton(id: attachment.id, index: index)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            String(
                                localized: "supermux.chat.composer.attachment",
                                defaultValue: "Attachment \(index + 1)",
                                bundle: .module
                            )
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
    }

    private func removeButton(id: String, index: Int) -> some View {
        Button {
            removeAttachment(id: id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, .black.opacity(0.6))
                .padding(3)
                .frame(width: 36, height: 36, alignment: .topTrailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "supermux.chat.composer.removeAttachment",
                defaultValue: "Remove attachment \(index + 1)",
                bundle: .module
            )
        )
    }

    // MARK: - State

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasContent: Bool {
        !trimmedDraft.isEmpty || !attachments.isEmpty
    }

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    // MARK: - Actions

    private func performSend() {
        guard hasContent, !isStagingAttachments else { return }
        MobileHapticFeedback().impact(style: .light)
        onSend(trimmedDraft, attachments.map(\.outbound))
        draft = ""
        attachments = []
        pickedItems = []
    }

    /// A second Stop within the window escalates to a hard interrupt, matching
    /// the terminal's double-tap-to-kill affordance.
    private func performStop() {
        MobileHapticFeedback().impact(style: .rigid)
        let now = Date()
        if let last = lastStopTap, now.timeIntervalSince(last) < Self.hardStopWindow {
            onInterrupt(true)
        } else {
            onInterrupt(false)
        }
        lastStopTap = now
    }

    private func removeAttachment(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments.remove(at: index)
        if let picked = pickedItems.firstIndex(where: { $0.itemIdentifier == id }) {
            pickedItems.remove(at: picked)
        }
    }

    private func loadPickedItems(_ items: [PhotosPickerItem]) async {
        isStagingAttachments = true
        defer { isStagingAttachments = false }
        var staged: [ChatComposerAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let attachment = Self.stagedAttachment(
                      from: data,
                      id: item.itemIdentifier ?? "picked-\(index)"
                  )
            else { continue }
            staged.append(attachment)
        }
        attachments = staged
    }

    /// Downscales and re-encodes a picked image before staging it.
    ///
    /// Phone photos are routinely 12MP; sending one untouched would push tens
    /// of megabytes over the pairing transport for an image the agent reads at
    /// screen resolution. Bounds the long edge and re-encodes as JPEG.
    private static func stagedAttachment(
        from data: Data,
        id: String
    ) -> ChatComposerAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxAttachmentDimension
            ? maxAttachmentDimension / longEdge
            : 1
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let resized = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            : image
        guard let encoded = resized.jpegData(compressionQuality: jpegQuality) else {
            return nil
        }
        return ChatComposerAttachment(
            id: id,
            data: encoded,
            format: .jpeg,
            thumbnail: Image(uiImage: resized)
        )
    }

    static let sendLabel = String(
        localized: "supermux.chat.composer.send",
        defaultValue: "Send",
        bundle: .module
    )
}
#endif
