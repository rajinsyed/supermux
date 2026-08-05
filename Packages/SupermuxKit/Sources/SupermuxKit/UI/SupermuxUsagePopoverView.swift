public import SwiftUI

/// The unified usage popover: Claude Code and Codex rate-limit windows as
/// compact bars with reset countdowns, extra cswap accounts collapsed below
/// the active one, and a freshness footer.
///
/// Purely presentational — reads the shared ``SupermuxUsageModel`` and calls
/// back into the host for refresh. Kept in the package so previews and tests
/// exercise it without the app target.
public struct SupermuxUsagePopoverView: View {
    @Bindable private var model: SupermuxUsageModel
    private let onRefresh: () -> Void
    /// Host hook for switching the active cswap account by slot number.
    private let onSwitchAccount: (Int) -> Void

    public init(
        model: SupermuxUsageModel,
        onRefresh: @escaping () -> Void,
        onSwitchAccount: @escaping (Int) -> Void = { _ in }
    ) {
        self.model = model
        self.onRefresh = onRefresh
        self.onSwitchAccount = onSwitchAccount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            claudeSection
            Divider()
            codexSection
            footer
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
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
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
            .accessibilityLabel(String(localized: "supermux.usage.refresh", defaultValue: "Refresh now"))
        }
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeSection: some View {
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
            }
            .buttonStyle(.plain)
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
        if account.windows.isEmpty {
            noteRow(String(
                localized: "supermux.usage.noData",
                defaultValue: "No usage data yet"
            ))
        } else {
            ForEach(Array(account.windows.sortedForDisplay().enumerated()), id: \.offset) { _, window in
                SupermuxUsageBarRow(window: window)
            }
        }
    }

    /// Non-active cswap accounts, one compact line each: the tightest window
    /// percent plus the account label, with a switch action on hover — the
    /// cswap `switch <slot>` feature, one click from the tracker.
    @ViewBuilder
    private func otherAccounts(_ accounts: [SupermuxClaudeAccountUsage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "supermux.usage.otherAccounts", defaultValue: "Other accounts"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(accounts) { account in
                SupermuxUsageAccountRow(
                    account: account,
                    isSwitching: model.switchingToSlot != nil && model.switchingToSlot == account.slot,
                    switchDisabled: model.switchingToSlot != nil,
                    onSwitch: account.slot.map { slot in
                        { onSwitchAccount(slot) }
                    }
                )
            }
        }
        .padding(.top, 2)
    }


    // MARK: - Codex

    @ViewBuilder
    private var codexSection: some View {
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
            ForEach(Array(snapshot.windows.sortedForDisplay().enumerated()), id: \.offset) { _, window in
                SupermuxUsageBarRow(window: window)
            }
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

/// One labeled usage bar: window name, percent, progress track, reset countdown.
struct SupermuxUsageBarRow: View {
    let window: SupermuxUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let resetsAt = window.resetsAt, resetsAt > Date() {
                    Text(String(
                        format: String(localized: "supermux.usage.resets", defaultValue: "resets %@"),
                        resetsAt.formatted(.relative(presentation: .numeric))
                    ))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                Text(verbatim: Self.percentText(clampedPercent))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: window.severity))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Self.color(for: window.severity))
                        .frame(width: max(3, proxy.size.width * clampedPercent / 100))
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
