public import SwiftUI

/// The unified usage popover: Claude Code and Codex rate-limit windows as
/// single-line meter rows (progress fill behind the text) with reset
/// countdowns, extra cswap accounts collapsed below the active one, and a
/// freshness footer.
///
/// Purely presentational — reads the shared ``SupermuxUsageModel`` and calls
/// back into the host for refresh. Kept in the package so previews and tests
/// exercise it without the app target.
public struct SupermuxUsagePopoverView: View {
    @Bindable private var model: SupermuxUsageModel
    private let onRefresh: () -> Void
    /// Host hook for switching the active cswap account by slot number.
    private let onSwitchAccount: (Int) -> Void
    /// Host hook for `cswap switch --strategy best`.
    private let onSwitchToBest: () -> Void
    /// Host hook for `cswap enable/disable <slot>`.
    private let onSetAccountEnabled: (Int, Bool) -> Void

    /// Whole turns completed by the refresh glyph; each refresh start adds
    /// one, so the icon spins exactly once per refresh and never snaps back.
    @State private var refreshTurns = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: SupermuxUsageModel,
        onRefresh: @escaping () -> Void,
        onSwitchAccount: @escaping (Int) -> Void = { _ in },
        onSwitchToBest: @escaping () -> Void = {},
        onSetAccountEnabled: @escaping (Int, Bool) -> Void = { _, _ in }
    ) {
        self.model = model
        self.onRefresh = onRefresh
        self.onSwitchAccount = onSwitchAccount
        self.onSwitchToBest = onSwitchToBest
        self.onSetAccountEnabled = onSetAccountEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            claudeSection
            hairline
            codexSection
            footer
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
    }

    /// Section separator quieter than a full `Divider`.
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "supermux.usage.title", defaultValue: "Usage Limits"))
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(model.isRefreshing ? 0.4 : 1)
                    .animation(.easeOut(duration: 0.2), value: model.isRefreshing)
                    .rotationEffect(.degrees(Double(refreshTurns) * 360))
            }
            .buttonStyle(SupermuxPressEffectButtonStyle())
            .disabled(model.isRefreshing)
            .onChange(of: model.isRefreshing) { _, refreshing in
                guard refreshing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7)) {
                    refreshTurns += 1
                }
            }
            .help(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
            .accessibilityLabel(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerHeader(
                title: String(localized: "supermux.usage.claude", defaultValue: "Claude Code"),
                detail: claudeDetail
            )
            switch model.claude {
            case .loading:
                loadingRow
            case .notConfigured:
                noteRow(String(
                    localized: "supermux.usage.claude.notConfigured",
                    defaultValue: "Claude Code login not found"
                ))
            case .needsLogin:
                noteRow(String(
                    localized: "supermux.usage.needsLogin",
                    defaultValue: "Sign in again to see usage"
                ))
            case .failed(let message):
                noteRow(message)
            case .ready(let snapshot):
                if let active = snapshot.activeAccount {
                    accountWindows(active)
                }
                let others = snapshot.accounts.filter { $0.id != snapshot.activeAccount?.id }
                if !others.isEmpty {
                    otherAccounts(others)
                }
                if let error = model.lastSwitchError {
                    switchErrorRow(error)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.lastSwitchError)
    }

    private func switchErrorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button {
                model.dismissSwitchError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(SupermuxPressEffectButtonStyle())
            .accessibilityLabel(String(localized: "supermux.usage.switch.dismissError", defaultValue: "Dismiss"))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.08)))
    }

    private var claudeDetail: String? {
        guard let active = model.claude.snapshot?.activeAccount else { return nil }
        return active.displayName ?? (active.email.isEmpty ? nil : active.email)
    }

    @ViewBuilder
    private func accountWindows(_ account: SupermuxClaudeAccountUsage) -> some View {
        // Credential problems on the ACTIVE account get an amber note above
        // whatever (possibly last-good) windows exist — mirroring cswap's TUI.
        if let problem = SupermuxUsageAccountStatusLabel.text(for: account.status) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        if account.windows.isEmpty {
            if account.status == .ok {
                noteRow(String(
                    localized: "supermux.usage.noData",
                    defaultValue: "No usage data yet"
                ))
            }
        } else {
            windowRows(account.windows)
        }
    }

    /// A provider's meter rows as one tight block; the appear sweep staggers
    /// top-to-bottom so the popover settles in one quick cascade.
    private func windowRows(_ windows: [SupermuxUsageWindow]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.offset) { index, window in
                SupermuxUsageBarRow(window: window, appearDelay: Double(index) * 0.05)
            }
        }
    }

    /// Non-active cswap accounts, one compact line each: the tightest window
    /// percent plus the account label, with a switch action on hover — the
    /// cswap `switch <slot>` feature, one click from the tracker.
    @ViewBuilder
    private func otherAccounts(_ accounts: [SupermuxClaudeAccountUsage]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(localized: "supermux.usage.otherAccounts", defaultValue: "Other accounts"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                switchToBestButton
            }
            .animation(.smooth(duration: 0.2), value: model.isSwitchingToBest)
            ForEach(accounts) { account in
                SupermuxUsageAccountRow(
                    account: account,
                    isSwitching: model.switchingToSlot != nil && model.switchingToSlot == account.slot,
                    switchDisabled: model.switchingToSlot != nil,
                    onSwitch: account.slot.map { slot in
                        { onSwitchAccount(slot) }
                    },
                    onSetEnabled: account.slot.map { slot in
                        { enabled in onSetAccountEnabled(slot, enabled) }
                    }
                )
            }
        }
        .padding(.top, 2)
    }

    /// cswap's `switch --strategy best`: jump to the account with the most
    /// remaining quota, no picking required.
    @ViewBuilder
    private var switchToBestButton: some View {
        if model.isSwitchingToBest {
            ProgressView()
                .controlSize(.mini)
        } else {
            Button(action: onSwitchToBest) {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 7.5))
                    Text(String(localized: "supermux.usage.switchBest", defaultValue: "Best"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(SupermuxPressEffectButtonStyle())
            .disabled(model.switchingToSlot != nil)
            .help(String(localized: "supermux.usage.switchBest.help", defaultValue: "Switch to the account with the most quota left"))
            .accessibilityLabel(String(localized: "supermux.usage.switchBest.help", defaultValue: "Switch to the account with the most quota left"))
        }
    }


    // MARK: - Codex

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerHeader(
                title: String(localized: "supermux.usage.codex", defaultValue: "Codex"),
                detail: codexDetail
            )
            switch model.codex {
            case .loading:
                loadingRow
            case .notConfigured:
                noteRow(String(
                    localized: "supermux.usage.codex.notConfigured",
                    defaultValue: "Codex login not found"
                ))
            case .needsLogin:
                noteRow(String(
                    localized: "supermux.usage.needsLogin",
                    defaultValue: "Sign in again to see usage"
                ))
            case .failed(let message):
                noteRow(message)
            case .ready(let snapshot):
                windowRows(snapshot.windows)
                if snapshot.source == .sessionLog {
                    noteRow(String(
                        localized: "supermux.usage.codex.fromSessionLog",
                        defaultValue: "From last Codex session (offline)"
                    ))
                }
            }
        }
    }

    private var codexDetail: String? {
        guard let plan = model.codex.snapshot?.planType, !plan.isEmpty else { return nil }
        return plan.capitalized
    }

    // MARK: - Shared pieces

    private func providerHeader(title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "supermux.usage.loading", defaultValue: "Loading…"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private var footer: some View {
        // Honest freshness: the OLDEST snapshot's own measurement time, not
        // the last poll attempt — a failed pass that keeps last-good data
        // must not present it as just-refreshed.
        if let measured = model.oldestDisplayedDataAge {
            HStack(spacing: 4) {
                if case .ready(let snapshot) = model.claude, snapshot.source == .cswap {
                    Text(String(localized: "supermux.usage.viaCswap", defaultValue: "via cswap"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: "·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(String(
                    format: String(localized: "supermux.usage.dataAsOf", defaultValue: "data %@"),
                    measured.formatted(.relative(presentation: .named))
                ))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One usage window as a single-line "meter" row: the progress fill sits
/// behind the text (label left, reset countdown and percent right), so each
/// window costs one compact line instead of a label line plus a bar line.
///
/// The fill sweeps in from zero on first appearance (rows stagger via
/// `appearDelay`) and live percent changes animate both the fill and the
/// rolling percent digits. Decorative motion is skipped under Reduce Motion.
struct SupermuxUsageBarRow: View {
    let window: SupermuxUsageWindow
    /// Per-row stagger for the appear sweep; 0 means no extra delay.
    var appearDelay: TimeInterval = 0

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            // cswap's "(ahead)" pace marker: usage is outrunning the
            // elapsed fraction of the weekly window.
            if window.aheadOfPace == true {
                Text(String(localized: "supermux.usage.aheadOfPace", defaultValue: "ahead of pace"))
                    .font(.system(size: 8, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let resetsAt = window.resetsAt, resetsAt > Date() {
                Text(String(
                    format: String(localized: "supermux.usage.resets", defaultValue: "resets %@"),
                    SupermuxUsageCountdown.text(until: resetsAt)
                ))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(verbatim: Self.percentText(clampedPercent))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.color(for: window.severity))
                .frame(minWidth: 28, alignment: .trailing)
                .contentTransition(.numericText(value: clampedPercent))
                .animation(.smooth(duration: 0.45), value: clampedPercent)
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(meterFill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.smooth(duration: 0.55).delay(appearDelay)) {
                    hasAppeared = true
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Quiet track with a severity-tinted fill proportional to usage; text
    /// stays legible because the tint stays under ~30% opacity.
    private var meterFill: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                if clampedPercent > 0 {
                    Rectangle()
                        .fill(Self.color(for: window.severity).opacity(0.3))
                        .frame(width: max(6, proxy.size.width * displayedPercent / 100))
                        .animation(.smooth(duration: 0.5), value: clampedPercent)
                }
            }
        }
    }

    /// Zero until the appear sweep starts, then the live value.
    private var displayedPercent: Double {
        hasAppeared ? clampedPercent : 0
    }

    private var clampedPercent: Double {
        min(100, max(0, window.percent))
    }

    private var label: String {
        switch window.kind {
        case .session:
            String(localized: "supermux.usage.window.session", defaultValue: "5-hour")
        case .weekly:
            String(localized: "supermux.usage.window.weekly", defaultValue: "Weekly")
        case .scoped(let name):
            name
        }
    }

    private var accessibilityText: String {
        String(
            format: String(
                localized: "supermux.usage.window.accessibility",
                defaultValue: "%1$@ window at %2$lld percent"
            ),
            label,
            Int(clampedPercent.rounded())
        )
    }

    static func color(for severity: SupermuxUsageSeverity) -> Color {
        switch severity {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Whole-percent text like "29%", stable across locales (the popover's
    /// bars are compact UI; fractional digits just add noise).
    static func percentText(_ percent: Double) -> String {
        "\(Int(min(100, max(0, percent)).rounded()))%"
    }
}
