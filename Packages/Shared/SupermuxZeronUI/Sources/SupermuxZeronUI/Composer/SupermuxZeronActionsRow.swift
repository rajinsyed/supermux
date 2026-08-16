//
//  SupermuxZeronActionsRow.swift
//  SupermuxZeronUI
//
//  The 46 pt actions row's contents. Spec 04 §4, from
//  `composer.rs:5440-5542` + `pickers.rs:3526-3601`.
//
//  Effective visual order:
//    … ⟨model chip: brand icon + name⟩ ⟨effort chip⟩ ⟨paperclip⟩ ⟨send circle⟩
//
//  The `Pickers` entity renders a `justify_between` row whose LEFT cluster is
//  empty (device/project moved to the canvas) and whose right cluster holds the
//  two chips; the composer then appends attach + send. The row's own 46 pt
//  height and its padding live in ``SupermuxZeronComposerPill`` — this file is
//  only the children, so the same cluster can sit in the expanded overlay and
//  in the compact inline row with byte-identical internals (which is the whole
//  point of `CLUSTER_X_DELTA`).
//
//  ── The effort chip is a CHIP, not a suffix ──
//
//  `trigger_chip` accepts a `suffix`, but the composer passes `None` for both
//  chips. The effort text is the traits chip's own LABEL. The traits chip is
//  **omitted entirely** when the model has neither a reasoning ladder nor
//  options — "a dead trigger reads as broken".
//

public import SwiftUI

/// The actions-row children: model chip, effort chip, attach, send.
public struct SupermuxZeronActionsRow: View {
    public typealias Flip = SupermuxZeronComposerFlip

    /// Everything the row paints, as plain values.
    public struct Model: Sendable, Equatable, Hashable {
        /// The model chip's label ("Sonnet 4.6"). The chip is omitted when nil.
        public var modelLabel: String?
        /// The brand mark beside it, if any.
        public var modelIcon: SupermuxZeronComposerIcon.Name?
        /// The brand tint (Claude's `#D97757`), or nil for `textMuted`.
        public var modelIconTint: Color?
        /// The effort chip's label ("High", "High · Fast"). Omitted when nil —
        /// which is what happens when the model has no reasoning ladder and no
        /// options.
        public var effortLabel: String?
        /// Whether the effort chip departs from its defaults, which is what
        /// brightens its label from `textMuted` to `text @ 0.9`.
        public var effortCustomized: Bool
        /// Which popover is open, so its chip holds the full wash.
        public var openChip: Chip?

        public enum Chip: Sendable, Equatable, Hashable {
            case model
            case effort
        }

        public init(
            modelLabel: String? = nil,
            modelIcon: SupermuxZeronComposerIcon.Name? = nil,
            modelIconTint: Color? = nil,
            effortLabel: String? = nil,
            effortCustomized: Bool = false,
            openChip: Chip? = nil
        ) {
            self.modelLabel = modelLabel
            self.modelIcon = modelIcon
            self.modelIconTint = modelIconTint
            self.effortLabel = effortLabel
            self.effortCustomized = effortCustomized
            self.openChip = openChip
        }
    }

    private let theme: SupermuxZeronTheme
    private let model: Model
    private let sendMode: SupermuxZeronSendMode
    private let isSendBlocked: Bool
    private let showsAttach: Bool
    private let onOpenModel: () -> Void
    private let onOpenEffort: () -> Void
    private let onAttach: () -> Void
    private let onSubmit: () -> Void
    private let onInterrupt: () -> Void

    public init(
        theme: SupermuxZeronTheme,
        model: Model,
        sendMode: SupermuxZeronSendMode,
        isSendBlocked: Bool = false,
        showsAttach: Bool = true,
        onOpenModel: @escaping () -> Void = {},
        onOpenEffort: @escaping () -> Void = {},
        onAttach: @escaping () -> Void = {},
        onSubmit: @escaping () -> Void = {},
        onInterrupt: @escaping () -> Void = {}
    ) {
        self.theme = theme
        self.model = model
        self.sendMode = sendMode
        self.isSendBlocked = isSendBlocked
        self.showsAttach = showsAttach
        self.onOpenModel = onOpenModel
        self.onOpenEffort = onOpenEffort
        self.onAttach = onAttach
        self.onSubmit = onSubmit
        self.onInterrupt = onInterrupt
    }

    /// Deliberately a multi-statement `body`, i.e. a `TupleView` of siblings
    /// rather than one container: the pill wraps `actions` in the `gap-1` HStack
    /// itself, so the chips, attach and send must arrive as its direct children
    /// or the 4 pt inter-button distances collapse into one nested group.
    public var body: some View {
        // The chips take the flexible half and shrink under row pressure; the
        // attach/send pair never does.
        HStack(spacing: Flip.clusterGap) {
            Spacer(minLength: 0)
            chips
        }
        .frame(maxWidth: .infinity, alignment: .trailing)

        if showsAttach {
            SupermuxZeronAttachButton(theme: theme, action: onAttach)
                .padding(.leading, Flip.attachLeadingMargin)
        }
        SupermuxZeronSendButton(
            theme: theme,
            mode: sendMode,
            isBlocked: isSendBlocked,
            onSubmit: onSubmit,
            onInterrupt: onInterrupt
        )
    }

    @ViewBuilder
    private var chips: some View {
        if let modelLabel = model.modelLabel {
            SupermuxZeronTriggerChip(
                theme: theme,
                label: modelLabel,
                icon: model.modelIcon,
                iconTint: model.modelIconTint,
                // The model chip always passes `set = true`, so its label rests
                // at `theme.text @ 0.9` rather than muted.
                isSet: true,
                isOpen: model.openChip == .model,
                action: onOpenModel
            )
        }
        if let effortLabel = model.effortLabel {
            SupermuxZeronTriggerChip(
                theme: theme,
                label: effortLabel,
                isSet: model.effortCustomized,
                isOpen: model.openChip == .effort,
                action: onOpenEffort
            )
        }
    }
}
