import SwiftUI

/// One non-active cswap account in the usage popover.
///
/// Collapsed: a single line — disclosure chevron, label, tightest-window
/// percent, and an always-visible switch button (hover-revealed controls are
/// deliberately avoided: NSPopover-hosted SwiftUI hover regions track with a
/// vertical offset, making them unreliable). Expanding the row shows every
/// limit window as the same compact bars the active account uses.
///
/// Layout matches ``SupermuxUsageBarRow``'s grid: the tightest percent uses
/// the same fixed-width trailing column, so collapsed rows line up with the
/// active account's bars above them.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                disclosureButton
                Spacer(minLength: 4)
                if isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    if !isExpanded {
                        tightestPercent
                    }
                    switchButton
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(account.windows.sortedForDisplay().enumerated()), id: \.offset) { _, window in
                        SupermuxUsageBarRow(window: window)
                    }
                }
                .padding(.leading, 13)
                .padding(.bottom, 3)
            }
        }
    }

    /// The chevron + label toggle the expansion together, so the whole
    /// leading side is one generous click target.
    private var disclosureButton: some View {
        Button {
            guard hasWindows else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hasWindows ? 1 : 0)
                    .frame(width: 9)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(account.isDisabled ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.isDisabled {
                    // Held out of cswap's rotation — a quiet pause glyph
                    // beside the dimmed label, no words needed.
                    Image(systemName: "pause.circle")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
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
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let tightest = account.windows.tightest {
            Text(verbatim: SupermuxUsageBarRow.percentText(tightest.percent))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(SupermuxUsageBarRow.color(for: tightest.severity))
                .frame(minWidth: 30, alignment: .trailing)
        } else {
            Text(String(localized: "supermux.usage.account.unavailable", defaultValue: "—"))
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var switchButton: some View {
        if let onSwitch {
            Button(action: onSwitch) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(switchDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(Color.accentColor.opacity(switchDisabled ? 0.05 : 0.1))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
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
