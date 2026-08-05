import SwiftUI

/// One non-active cswap account line in the usage popover: label, tightest
/// window percent, and a hover-revealed Switch action (cswap's account swap,
/// one click away). Disabled (out-of-rotation) accounts render dimmed but
/// stay explicitly switchable, matching `cswap switch <slot>` semantics.
struct SupermuxUsageAccountRow: View {
    let account: SupermuxClaudeAccountUsage
    /// A switch to THIS account is in flight (row shows a spinner).
    let isSwitching: Bool
    /// Any switch is in flight (all switch buttons disable together).
    let switchDisabled: Bool
    /// `nil` when the account has no slot number (cannot be targeted).
    let onSwitch: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(account.displayName ?? account.email)
                .font(.system(size: 10.5))
                .foregroundStyle(account.isDisabled ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isSwitching {
                ProgressView()
                    .controlSize(.mini)
            } else if isHovering, let onSwitch {
                Button(action: onSwitch) {
                    Text(String(localized: "supermux.usage.switch", defaultValue: "Switch"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(switchDisabled)
                .accessibilityLabel(String(
                    format: String(localized: "supermux.usage.switch.accessibility", defaultValue: "Switch to %@"),
                    account.displayName ?? account.email
                ))
            } else {
                status
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        if let tightest = account.windows.tightest, case .ok = account.status {
            Text(verbatim: SupermuxUsageBarRow.percentText(tightest.percent))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(SupermuxUsageBarRow.color(for: tightest.severity))
        } else {
            Text(String(localized: "supermux.usage.account.unavailable", defaultValue: "—"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}
