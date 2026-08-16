//
//  SupermuxZeronAttachmentStrip.swift
//  SupermuxZeronUI
//
//  The staged-attachment strip inside the pill. Spec 04 §9, from
//  `composer.rs:3565-3646` + `attachments.rs`.
//
//  ── Three details that are easy to lose ──
//
//  1. **The image gets its OWN 7 pt radius.** The 8 pt frame's rounding only
//     clips rectangularly, so an inherited clip leaves square image corners
//     inside a rounded frame (7 = 8 − border).
//  2. **The remove button overhangs the thumb by 6 pt on both axes** and must be
//     its own draw layer: inside the frosted pill everything shares one draw
//     order and images render last, so without it the thumbnail paints OVER the
//     button. `.zIndex(1)` is the SwiftUI equivalent of `frost::layered`.
//  3. **Its click must not also open the preview.** The button hangs outside the
//     thumb's own hitbox, so the tap has to stop propagation — a plain `Button`
//     inside the `ZStack` does that, which is why this is not a tap gesture.
//
//  ── There is no loading state ──
//
//  A staged attachment holds already-read bytes; staging is synchronous and
//  either succeeds or is rejected up-front. The rejection strings are here
//  because they are the composer's user-facing copy, but nothing renders a
//  spinner over a thumb. `state` still carries `.loading`/`.failed` so a mount
//  that stages ASYNCHRONOUSLY (the phone reading a `PhotosPicker` item) has a
//  faithful place to put the pulse rather than inventing one.
//

public import SwiftUI

internal import Foundation

// MARK: - Model

/// One staged attachment.
public struct SupermuxZeronAttachment: Sendable, Equatable, Hashable, Identifiable {
    /// How the thumbnail renders right now.
    public enum State: Sendable, Equatable, Hashable {
        /// Bytes in hand — the only state zeron itself has.
        case ready
        /// Being read. Renders the 2400 ms `ZERON_PULSE` breathe over an
        /// `ink(0.04)` plate, the same recipe as the slash skeleton.
        case loading
        /// Rejected. Renders the plate with a danger-tinted triangle.
        case failed(String)
    }

    public let id: String
    /// The file name, shown in the lightbox.
    public let name: String
    public var state: State

    public init(id: String, name: String, state: State = .ready) {
        self.id = id
        self.name = name
        self.state = state
    }

    /// The formats `stage_file` accepts (`attachments.rs:228`).
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff",
    ]

    /// `MAX_ATTACHMENT_BYTES` — 24 MiB.
    public static let maxBytes = 24 * 1024 * 1024

    /// The three up-front rejection messages, verbatim.
    public enum Rejection: Sendable, Equatable, Hashable {
        case unsupported(String)
        case unreadable(String)
        case tooLarge(String)

        public var message: String {
            switch self {
            case .unsupported(let name):
                String(
                    localized: "supermux.zeron.attachment.unsupported",
                    defaultValue: "\(name) is not a supported image.",
                    bundle: .supermuxZeronUI
                )
            case .unreadable(let name):
                String(
                    localized: "supermux.zeron.attachment.unreadable",
                    defaultValue: "\(name) could not be read.",
                    bundle: .supermuxZeronUI
                )
            case .tooLarge(let name):
                String(
                    localized: "supermux.zeron.attachment.tooLarge",
                    defaultValue: "\(name) is too large (24 MB max).",
                    bundle: .supermuxZeronUI
                )
            }
        }
    }
}

// MARK: - Strip

/// The wrapping 56 pt thumbnail strip, the pill's FIRST child in both modes.
///
/// Renders nothing at all when empty — the element is absent, not zero-height,
/// which is what keeps ``SupermuxZeronComposerFlip/attachmentStripHeight(count:innerWidth:)``
/// exactly right at count 0.
public struct SupermuxZeronAttachmentStrip<Thumbnail: View>: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let attachments: [SupermuxZeronAttachment]
    private let innerWidth: CGFloat
    private let thumbnail: (SupermuxZeronAttachment) -> Thumbnail
    private let onOpen: (SupermuxZeronAttachment) -> Void
    private let onRemove: (SupermuxZeronAttachment) -> Void

    /// - Parameters:
    ///   - innerWidth: The pill's content width, used to lay out exactly the
    ///     rows ``SupermuxZeronComposerFlip`` reserved height for. Pass the last
    ///     measured input width; 720 is the pre-measure fallback.
    ///   - thumbnail: The platform's image view for one attachment. The strip
    ///     owns the 56 pt frame, the 8 pt border and the 7 pt inner clip, so the
    ///     closure only supplies pixels.
    public init(
        theme: SupermuxZeronTheme,
        attachments: [SupermuxZeronAttachment],
        innerWidth: CGFloat = 720,
        @ViewBuilder thumbnail: @escaping (SupermuxZeronAttachment) -> Thumbnail,
        onOpen: @escaping (SupermuxZeronAttachment) -> Void = { _ in },
        onRemove: @escaping (SupermuxZeronAttachment) -> Void = { _ in }
    ) {
        self.theme = theme
        self.attachments = attachments
        self.innerWidth = innerWidth
        self.thumbnail = thumbnail
        self.onOpen = onOpen
        self.onRemove = onRemove
    }

    public var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.stripGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Metrics.stripGap) {
                        ForEach(row) { attachment in
                            SupermuxZeronAttachmentThumb(
                                theme: theme,
                                attachment: attachment,
                                onOpen: { onOpen(attachment) },
                                onRemove: { onRemove(attachment) },
                                content: { thumbnail(attachment) }
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, Metrics.stripPadX)
            .padding(.top, Metrics.stripPadTop)
            // No bottom padding — the input's own top padding provides the
            // separation.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Chunked with the SAME per-row count the analytic height used, so the
    /// rendered rows and the reserved height cannot disagree.
    private var rows: [[SupermuxZeronAttachment]] {
        let perRow = SupermuxZeronComposerFlip.attachmentsPerRow(innerWidth: innerWidth)
        return stride(from: 0, to: attachments.count, by: perRow).map { start in
            Array(attachments[start ..< min(start + perRow, attachments.count)])
        }
    }
}

// MARK: - Thumb

/// One 56 pt thumbnail with its overhanging remove button.
struct SupermuxZeronAttachmentThumb<Content: View>: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    let theme: SupermuxZeronTheme
    let attachment: SupermuxZeronAttachment
    let onOpen: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @Environment(\.supermuxZeronPulseClock) private var clockOverride
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            frame
            removeButton
                // `frost::layered`: without a fresh draw order the image paints
                // over this button inside the frosted pill.
                .zIndex(1)
        }
        // The button overhangs by 6 pt; the ZStack must not clip it.
        .padding(-Metrics.stripRemoveOffset)
        .padding(Metrics.stripRemoveOffset)
        .onHover { isHovered = $0 }
    }

    private var frame: some View {
        Button(action: onOpen) {
            body(for: attachment.state)
                .frame(width: Metrics.stripThumb, height: Metrics.stripThumb)
                // The image carries its OWN 7 pt radius — the 8 pt frame clips
                // rectangularly.
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline(0.10), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func body(for state: SupermuxZeronAttachment.State) -> some View {
        switch state {
        case .ready:
            content()
        case .loading:
            Rectangle()
                .fill(theme.ink(0.04))
                .opacity(pulseOpacity)
        case .failed:
            ZStack {
                Rectangle().fill(theme.ink(0.04))
                SupermuxZeronComposerIcon(.dangerTriangle, size: 14)
                    .foregroundStyle(theme.dangerMuted)
            }
        }
    }

    /// Leased on the ONE shared 30 fps clock, so a staging thumb breathes in
    /// lock-step with every other loader on screen (plan R12).
    private var pulseOpacity: Double {
        guard !reduceMotion else { return 0.35 }
        let clock = clockOverride ?? SupermuxZeronPulseClock.shared
        return SupermuxZeronMetrics.Loaders.skeletonOpacity(
            clock.phase(
                period: Double(SupermuxZeronMetrics.Motion.zeronPulse.durationMS) / 1000,
                leasedBy: "attachment-\(attachment.id)"
            )
        )
    }

    /// 18 pt, `rounded_full`, an OPAQUE `theme.bg` plate with a 14 pt
    /// `closeCircle` at `textMuted`. Resting opacity is **0** — fully invisible
    /// until the whole thumb group is hovered, and it SNAPS (a `group_hover`
    /// style, not a `hover_blend`).
    ///
    /// Touch has no hover, so it rests visible there: an invisible destructive
    /// control is unusable by touch (the same reasoning as the code block's copy
    /// button, plan §4).
    private var removeButton: some View {
        Button(action: onRemove) {
            SupermuxZeronComposerIcon(.closeCircle, size: 14)
                .foregroundStyle(theme.textMuted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.bg))
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -Metrics.stripRemoveOffset, y: Metrics.stripRemoveOffset)
        .opacity(removeOpacity)
        .animation(nil, value: isHovered)
        .accessibilityLabel(
            String(
                localized: "supermux.zeron.attachment.remove",
                defaultValue: "Remove attachment",
                bundle: .supermuxZeronUI
            )
        )
    }

    private var removeOpacity: Double {
        #if os(macOS)
        return isHovered ? 1 : 0
        #else
        return 1
        #endif
    }
}
