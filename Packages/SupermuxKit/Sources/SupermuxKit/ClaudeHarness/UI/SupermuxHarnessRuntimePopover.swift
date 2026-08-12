import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// The model / effort / fast-mode / thinking-budget picker.
///
/// remodex presents this as a full-screen overlay because an iOS sheet destroys
/// keyboard focus. macOS has no such constraint, so it is a `.popover` anchored
/// on the composer's model pill — but the effort **fill slider** is kept, since
/// it communicates a ladder far better than a segmented control does.
struct SupermuxHarnessRuntimePopover: View {
    let models: [ClaudeModelDescriptor]
    let selectedModel: String?
    let effortLevels: [String]
    let effortLevel: String?
    let supportsFastMode: Bool
    let fastMode: Bool
    let maxThinkingTokens: Int?
    let theme: SupermuxHarnessTheme
    let onSelectModel: (String) -> Void
    let onSelectEffort: (String) -> Void
    let onToggleFastMode: (Bool) -> Void
    let onSetThinkingBudget: (Int) -> Void

    /// The budgets offered; `0` is "off" (Claude decides).
    private static let thinkingBudgets = [0, 4_000, 10_000, 32_000]

    var body: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing10) {
            modelSection
            if !effortLevels.isEmpty {
                effortSection
            }
            if supportsFastMode {
                fastModeToggle
            }
            thinkingSection
        }
        .padding(SupermuxHarnessTokens.spacing12)
        .frame(width: 280)
        // A popover presents outside the panel hierarchy, so the panel's page
        // background never reaches it. Without an explicit fill, dark Ghostty
        // text lands on the system's (possibly light) popover chrome.
        .background(theme.popoverBackground)
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            sectionTitle(
                String(
                    localized: "supermux.harness.model.picker.title",
                    defaultValue: "Model"
                )
            )
            if models.isEmpty {
                Text(
                    String(
                        localized: "supermux.harness.model.unavailable",
                        defaultValue: "Model list unavailable."
                    )
                )
                .cmuxFont(size: SupermuxHarnessTokens.footnote)
                .foregroundStyle(theme.mutedText)
            } else {
                ForEach(models, id: \.value) { model in
                    Button {
                        onSelectModel(model.value)
                    } label: {
                        HStack(spacing: SupermuxHarnessTokens.spacing6) {
                            Image(
                                systemName: model.value == selectedModel
                                    ? "largecircle.fill.circle"
                                    : "circle"
                            )
                            .font(.system(size: SupermuxHarnessTokens.caption))
                            .foregroundStyle(
                                model.value == selectedModel ? theme.accent : theme.mutedText
                            )
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.displayName ?? model.value)
                                    .cmuxFont(size: SupermuxHarnessTokens.footnote)
                                    .foregroundStyle(theme.text)
                                if let description = model.description, !description.isEmpty {
                                    Text(description)
                                        .cmuxFont(size: SupermuxHarnessTokens.caption2)
                                        .foregroundStyle(theme.mutedText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Effort

    private var effortSection: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            sectionTitle(
                String(
                    localized: "supermux.harness.effort.title",
                    defaultValue: "Effort"
                )
            )
            SupermuxHarnessEffortSlider(
                levels: effortLevels,
                selected: effortLevel,
                theme: theme,
                onSelect: onSelectEffort
            )
            .frame(height: 34)
            if let effortLevel {
                Text(effortLevel)
                    .cmuxFont(size: SupermuxHarnessTokens.caption)
                    .foregroundStyle(theme.mutedText)
            }
        }
    }

    // MARK: - Fast mode

    private var fastModeToggle: some View {
        Button {
            onToggleFastMode(!fastMode)
        } label: {
            HStack(spacing: SupermuxHarnessTokens.spacing6) {
                Image(systemName: fastMode ? "bolt.fill" : "bolt")
                    .font(.system(size: SupermuxHarnessTokens.footnote))
                    .foregroundStyle(fastMode ? theme.toolAccent : theme.mutedText)
                Text(
                    String(
                        localized: "supermux.harness.model.fastMode",
                        defaultValue: "Fast mode"
                    )
                )
                .cmuxFont(size: SupermuxHarnessTokens.footnote)
                .foregroundStyle(theme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thinking budget

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: SupermuxHarnessTokens.spacing4) {
            sectionTitle(
                String(
                    localized: "supermux.harness.thinking.budget.title",
                    defaultValue: "Thinking budget"
                )
            )
            HStack(spacing: SupermuxHarnessTokens.spacing4) {
                ForEach(Self.thinkingBudgets, id: \.self) { budget in
                    Button {
                        onSetThinkingBudget(budget)
                    } label: {
                        Text(budgetLabel(budget))
                            .cmuxFont(size: SupermuxHarnessTokens.caption, monospacedDigit: true)
                            .foregroundStyle(
                                budget == (maxThinkingTokens ?? 0) ? theme.text : theme.mutedText
                            )
                            .padding(.horizontal, SupermuxHarnessTokens.spacing6)
                            .padding(.vertical, SupermuxHarnessTokens.spacing2)
                            .background(
                                Capsule(style: .continuous).fill(
                                    budget == (maxThinkingTokens ?? 0)
                                        ? theme.accentSoft
                                        : theme.surface
                                )
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func budgetLabel(_ budget: Int) -> String {
        guard budget > 0 else {
            return String(
                localized: "supermux.harness.thinking.budget.off",
                defaultValue: "Auto"
            )
        }
        return "\(budget / 1000)k"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: SupermuxHarnessTokens.caption2, weight: .semibold)
            .foregroundStyle(theme.mutedText)
            .textCase(.uppercase)
    }
}

/// The effort ladder as a fill slider (remodex's `ComposerEffortSlider`
/// geometry: 6pt fill inset, 4pt thumb inset, one dot per level, live commit
/// while dragging).
struct SupermuxHarnessEffortSlider: View {
    let levels: [String]
    let selected: String?
    let theme: SupermuxHarnessTheme
    let onSelect: (String) -> Void

    @State private var dragLocationX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // remodex's proportions (thumb/track = 40/60 ≈ 0.67) scaled onto a 34pt
    // macOS track: copying its absolute 6/4pt insets verbatim would shrink the
    // thumb to 14pt — a pea in a fat capsule instead of a switch knob.
    private let trackHeight: CGFloat = 34
    private let fillInset: CGFloat = 3
    private let thumbInset: CGFloat = 2
    private let dotDiameter: CGFloat = 6

    private var fillHeight: CGFloat { trackHeight - fillInset * 2 }
    private var thumbDiameter: CGFloat { fillHeight - thumbInset * 2 }

    var body: some View {
        GeometryReader { proxy in
            // Below one track height there is no room for the thumb; skip
            // drawing rather than overflow during transient layout passes.
            if proxy.size.width >= trackHeight {
                track(width: proxy.size.width)
            }
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityLabel(
            String(localized: "supermux.harness.effort.title", defaultValue: "Effort")
        )
        .accessibilityValue(selected ?? "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                accessibilitySelect(selectedIndex + 1)
            case .decrement:
                accessibilitySelect(selectedIndex - 1)
            @unknown default:
                break
            }
        }
    }

    /// VoiceOver/keyboard stepping: clamp and commit the neighbouring level.
    private func accessibilitySelect(_ index: Int) {
        guard !levels.isEmpty else { return }
        let clamped = min(max(index, 0), levels.count - 1)
        guard levels[clamped] != selected else { return }
        onSelect(levels[clamped])
    }

    private func track(width: CGFloat) -> some View {
        let centers = dotCenters(width: width)
        let thumbX = thumbCenterX(centers: centers)
        return ZStack {
            fill(trailingX: thumbX + fillHeight / 2)
            ForEach(Array(levels.enumerated()), id: \.element) { index, _ in
                Circle()
                    // popoverBackground, never pageBackground: the page colour
                    // is `.clear` under window transparency and the passed dots
                    // would vanish into the accent fill.
                    .fill(centers[index] <= thumbX ? theme.popoverBackground : theme.border)
                    .frame(width: dotDiameter, height: dotDiameter)
                    .position(x: centers[index], y: trackHeight / 2)
            }
            Circle()
                .fill(theme.text)
                .frame(width: thumbDiameter, height: thumbDiameter)
                .position(x: thumbX, y: trackHeight / 2)
        }
        .frame(width: width, height: trackHeight)
        .background(
            Capsule(style: .continuous).fill(theme.surface)
        )
        .contentShape(Capsule(style: .continuous))
        .animation(
            dragLocationX == nil && !reduceMotion
                ? SupermuxHarnessTokens.spring
                : nil,
            value: thumbX
        )
        .gesture(dragGesture(centers: centers))
    }

    private func fill(trailingX: CGFloat) -> some View {
        let width = max(trailingX - fillInset, fillHeight)
        return Capsule(style: .continuous)
            .fill(theme.accent)
            .frame(width: width, height: fillHeight)
            .position(x: fillInset + width / 2, y: trackHeight / 2)
    }

    private var selectedIndex: Int {
        levels.firstIndex(where: { $0 == selected }) ?? 0
    }

    private func dotCenters(width: CGFloat) -> [CGFloat] {
        guard !levels.isEmpty else { return [] }
        let inset = fillInset + fillHeight / 2
        let span = max(width - inset * 2, 0)
        guard levels.count > 1 else { return [inset] }
        return (0..<levels.count).map { index in
            inset + span * CGFloat(index) / CGFloat(levels.count - 1)
        }
    }

    private func thumbCenterX(centers: [CGFloat]) -> CGFloat {
        guard !centers.isEmpty else { return fillInset + fillHeight / 2 }
        if let dragLocationX {
            return min(max(dragLocationX, centers[0]), centers[centers.count - 1])
        }
        return centers[min(selectedIndex, centers.count - 1)]
    }

    private func dragGesture(centers: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragLocationX = value.location.x
                commit(at: value.location.x, centers: centers)
            }
            .onEnded { value in
                commit(at: value.location.x, centers: centers)
                dragLocationX = nil
            }
    }

    /// Live commit while dragging: the nearest dot wins, and only a *change*
    /// calls back so a drag does not spam the CLI with identical controls.
    private func commit(at x: CGFloat, centers: [CGFloat]) {
        guard !centers.isEmpty else { return }
        var nearest = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - x)
            if distance < bestDistance {
                bestDistance = distance
                nearest = index
            }
        }
        guard nearest < levels.count, levels[nearest] != selected else { return }
        onSelect(levels[nearest])
    }
}
