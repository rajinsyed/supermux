public import SwiftUI

/// The unified usage popover: Claude Code and Codex rate-limit windows as
/// compact bars with reset countdowns, extra cswap accounts collapsed below
/// the active one, and a freshness footer.
///
/// Visual language: each provider is a soft rounded card with a brand-colored
/// dot, a single type scale (11 semibold headers, 10 labels, 9 metadata), a
/// fixed-width right-aligned percent column so every row lines up, and
/// hairline separators inside cards instead of full-width dividers.
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
        VStack(alignment: .leading, spacing: 8) {
            header
            card { claudeSection }
            card { codexSection }
            footer
        }
        .padding(12)
        .frame(width: 272, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "supermux.usage.title", defaultValue: "Usage Limits"))
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
                .accessibilityLabel(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 2)
    }

    /// One provider card: quiet fill, hairline border, continuous corners.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    /// Hairline used INSIDE cards (a full `Divider` reads too heavy there).
    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeSection: some View {
        providerHeader(
            title: String(localized: "supermux.usage.claude", defaultValue: "Claude Code"),
            dotColor: Self.claudeBrandColor,
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
                hairline
                    .padding(.top, 1)
                otherAccounts(others)
            }
            if let error = model.lastSwitchError {
                switchErrorRow(error)
            }
        }
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
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "supermux.usage.switch.dismissError", defaultValue: "Dismiss"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.opacity(0.09)))
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
            windowBars(account.windows)
        }
    }

    /// A provider's bars as one block with consistent internal spacing.
    private func windowBars(_ windows: [SupermuxUsageWindow]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.offset) { _, window in
                SupermuxUsageBarRow(window: window)
            }
        }
    }

    /// Non-active cswap accounts, one compact line each: the tightest window
    /// percent plus the account label, with a one-click switch action — the
    /// cswap `switch <slot>` feature inside the tracker.
    @ViewBuilder
    private func otherAccounts(_ accounts: [SupermuxClaudeAccountUsage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(String(localized: "supermux.usage.otherAccounts", defaultValue: "Other accounts"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                switchToBestButton
            }
            .frame(height: 16)
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
                        .font(.system(size: 7))
                    Text(String(localized: "supermux.usage.switchBest", defaultValue: "Best"))
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.switchingToSlot != nil)
            .help(String(localized: "supermux.usage.switchBest.help", defaultValue: "Switch to the account with the most quota left"))
            .accessibilityLabel(String(localized: "supermux.usage.switchBest.help", defaultValue: "Switch to the account with the most quota left"))
        }
    }

    // MARK: - Codex

    @ViewBuilder
    private var codexSection: some View {
        providerHeader(
            title: String(localized: "supermux.usage.codex", defaultValue: "Codex"),
            dotColor: Self.codexBrandColor,
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
            windowBars(snapshot.windows)
            if snapshot.source == .sessionLog {
                noteRow(String(
                    localized: "supermux.usage.codex.fromSessionLog",
                    defaultValue: "From last Codex session (offline)"
                ))
            }
        }
    }

    private var codexDetail: String? {
        guard let plan = model.codex.snapshot?.planType, !plan.isEmpty else { return nil }
        return plan.capitalized
    }

    // MARK: - Shared pieces

    /// Anthropic's clay orange — identifies the Claude card at a glance.
    static let claudeBrandColor = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// OpenAI's green-teal — identifies the Codex card.
    static let codexBrandColor = Color(red: 0.06, green: 0.64, blue: 0.50)

    private func providerHeader(title: String, dotColor: Color, detail: String?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(String(localized: "supermux.usage.loading", defaultValue: "Loading…"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
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
            .padding(.horizontal, 2)
        }
    }
}

/// One labeled usage bar: window name, percent, progress track, reset countdown.
///
/// The percent sits in a fixed-width trailing column so stacked bars align
/// into a clean grid; the countdown right-aligns against it.
struct SupermuxUsageBarRow: View {
    let window: SupermuxUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // cswap's "(ahead)" pace marker: usage is outrunning the
                // elapsed fraction of the weekly window.
                if window.aheadOfPace == true {
                    Text(String(localized: "supermux.usage.aheadOfPace", defaultValue: "ahead of pace"))
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.13)))
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
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Text(verbatim: Self.percentText(clampedPercent))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: window.severity))
                    .frame(minWidth: 30, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Self.color(for: window.severity))
                        .frame(width: max(4, proxy.size.width * clampedPercent / 100))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
