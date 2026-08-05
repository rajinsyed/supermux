import SwiftUI

/// One non-active cswap account in the usage popover.
///
/// Collapsed: a single line — disclosure chevron, label, tightest-window
/// percent, and an always-visible switch button (hover-revealed controls are
/// deliberately avoided: NSPopover-hosted SwiftUI hover regions track with a
/// vertical offset, making them unreliable). Expanding the row shows every
/// limit window as the same compact bars the active account uses.
struct SupermuxUsageAccountRow: View {
    let account: SupermuxClaudeAccountUsage
    /// A switch to THIS account is in flight (row shows a spinner).
    let isSwitching: Bool
    /// Any switch is in flight (all switch buttons disable together).
    let switchDisabled: Bool
    /// `nil` when the account has no slot number (cannot be targeted).
    let onSwitch: (() -> Void)?
    /// Context-menu Enable/Disable (cswap auto-rotation hold); `nil` when the
    /// account has no slot.
    var onSetEnabled: ((Bool) -> Void)?

    @State private var isExpanded = false

    private var label: String { account.displayName ?? account.email }
    private var hasWindows: Bool { !account.windows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                disclosureButton
                Spacer(minLength: 4)
                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                } else {
                    if !isExpanded {
                        tightestPercent
                            .transition(.opacity)
                    }
                    switchButton
                }
            }
            .frame(height: 20)
            .animation(.smooth(duration: 0.2), value: isSwitching)
            .contextMenu {
                if let onSetEnabled {
                    if account.isDisabled {
                        Button(String(localized: "supermux.usage.account.enable", defaultValue: "Enable in Rotation")) {
                            onSetEnabled(true)
                        }
                    } else {
                        Button(String(localized: "supermux.usage.account.disable", defaultValue: "Hold Out of Rotation")) {
                            onSetEnabled(false)
                        }
                    }
                }
            }
            if isExpanded, hasWindows {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(account.windows.sortedForDisplay().enumerated()), id: \.offset) { index, window in
                        SupermuxUsageBarRow(window: window, appearDelay: Double(index) * 0.04)
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The chevron + label toggle the expansion together, so the whole
    /// leading side is one generous click target.
    private var disclosureButton: some View {
        Button {
            guard hasWindows else { return }
            withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasWindows ? 1 : 0)
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(account.isDisabled ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasWindows)
        .accessibilityLabel(label)
        .accessibilityValue(isExpanded
            ? String(localized: "supermux.usage.account.expanded", defaultValue: "expanded")
            : String(localized: "supermux.usage.account.collapsed", defaultValue: "collapsed"))
    }

    @ViewBuilder
    private var tightestPercent: some View {
        if let problem = SupermuxUsageAccountStatusLabel.text(for: account.status) {
            // Credential problems read like cswap's TUI: a short amber label
            // ("token expired", "re-login needed") instead of a percent. The
            // windows shown on expand may be last-good data.
            Text(problem)
                .font(.system(size: 9.5))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let tightest = account.windows.tightest {
            Text(verbatim: SupermuxUsageBarRow.percentText(tightest.percent))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(SupermuxUsageBarRow.color(for: tightest.severity))
        } else {
            Text(String(localized: "supermux.usage.account.unavailable", defaultValue: "—"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var switchButton: some View {
        if let onSwitch {
            Button(action: onSwitch) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(SupermuxPressEffectButtonStyle())
            .disabled(switchDisabled)
            .help(String(
                format: String(localized: "supermux.usage.switch.accessibility", defaultValue: "Switch to %@"),
                label
            ))
            .accessibilityLabel(String(
                format: String(localized: "supermux.usage.switch.accessibility", defaultValue: "Switch to %@"),
                label
            ))
        }
    }
}
