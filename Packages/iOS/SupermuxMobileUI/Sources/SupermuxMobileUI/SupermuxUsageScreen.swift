import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The phone's usage-limits sheet: one block per provider, each carrying its
/// windows as meter rows, the extra cswap accounts below the active one, and
/// an honest freshness footer.
///
/// Presented as a floating Liquid Glass sheet sized to its content
/// (``SwiftUICore/View/supermuxUsageSheet(isPresented:card:)``) rather than as
/// a full-screen sheet — the whole tracker is a handful of rows, so a full
/// sheet would be mostly empty space and would hide the workspace list for no
/// reason.
///
/// Deliberately chrome-free: no title, no summary dial, no refresh or close
/// button. The rows ARE the content, the gauge that opened the sheet already
/// carries the summary, and the sheet dismisses by swipe. Presenting refreshes
/// on its own, so a manual control only added a second way to do what arriving
/// already did.
///
/// Read-only by design — the Mac owns polling and every cswap mutation, so
/// there is no account switching here (see ``SupermuxMobileUsageStore``).
///
/// The screen does NOT own a poll loop: it renders the store the presenting
/// gauge already drives, so both surfaces show one snapshot and one request
/// cadence instead of two.
public struct SupermuxUsageScreen: View {
    private let store: SupermuxMobileUsageStore?

    /// Creates the usage screen.
    /// - Parameter store: The live usage session the presenting gauge drives,
    ///   or `nil` when disconnected (a placeholder shows).
    public init(store: SupermuxMobileUsageStore?) {
        self.store = store
    }

    public var body: some View {
        content
            .accessibilityIdentifier("SupermuxUsageScreen")
            // Opening the sheet asks for a refresh, so the numbers are current
            // on arrival instead of up to one poll period old. The Mac's
            // shared floor makes this free when the data is already fresh.
            .task { await store?.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            // Snapshot the observable state ONCE, above the rows: everything
            // below receives plain values, so no view under a lazy/list
            // boundary holds a store reference (see the SwiftUI list-boundary
            // rule in CLAUDE.md / the cmux-debugging skill).
            let usage = store.usage
            let hasLoaded = store.hasLoaded
            let initialFailureDescription = Self.initialFailureDescription(
                hasLoaded: hasLoaded,
                errorDescription: store.lastErrorDescription
            )
            if let initialFailureDescription {
                initialFailurePlaceholder(
                    initialFailureDescription,
                    isRefreshing: store.isRefreshing,
                    retry: { Task { await store.refresh() } }
                )
            } else {
                VStack(spacing: 24) {
                    providerPanel(
                        title: String(
                            localized: "supermux.usage.claude",
                            defaultValue: "Claude Code",
                            bundle: .module
                        ),
                        symbol: "asterisk",
                        provider: usage?.claude,
                        hasLoaded: hasLoaded
                    ) {
                        claudeRows(usage?.claude)
                    }
                    providerPanel(
                        title: String(
                            localized: "supermux.usage.codex",
                            defaultValue: "Codex",
                            bundle: .module
                        ),
                        symbol: "chevron.left.forwardslash.chevron.right",
                        provider: usage?.codex,
                        hasLoaded: hasLoaded
                    ) {
                        codexRows(usage?.codex)
                    }
                    footer(usage)
                }
            }
        } else {
            disconnectedPlaceholder
        }
    }

    // MARK: - Provider panels

    /// One provider's panel: its title row (symbol, name, and the detail the
    /// Mac shows — account label or Codex plan) over either its terminal-state
    /// note or the rows the builder supplies.
    @ViewBuilder
    private func providerPanel(
        title: String,
        symbol: String,
        provider: SupermuxUsageProviderDTO?,
        hasLoaded: Bool,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail = Self.providerDetail(provider) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
            }
            if let note = Self.stateNote(for: provider, hasLoaded: hasLoaded) {
                noteRow(note)
            } else {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The active account's windows, then every other cswap account as a
    /// compact disclosure row. Claude only.
    @ViewBuilder
    private func claudeRows(_ provider: SupermuxUsageProviderDTO?) -> some View {
        if let active = provider?.activeAccount {
            // A credential problem on the ACTIVE account gets an amber note
            // above its (possibly last-good) windows, mirroring cswap's TUI.
            if let problem = SupermuxUsageAccountLabels.statusText(for: active) {
                warningRow(problem)
            }
            if active.displayWindows.isEmpty {
                if active.isHealthy {
                    noDataRow
                }
            } else {
                windowRows(active.displayWindows)
            }
        } else {
            // A `ready` provider with no account rows at all: without this the
            // panel would render as a bare title over empty space.
            noDataRow
        }
        let others = (provider?.accounts ?? []).filter { $0.id != provider?.activeAccount?.id }
        if !others.isEmpty {
            Divider().opacity(0.5)
            VStack(spacing: 10) {
                ForEach(others) { account in
                    SupermuxUsageAccountRow(account: account)
                }
            }
        }
    }

    /// Codex's own windows plus its stale-data notes.
    @ViewBuilder
    private func codexRows(_ provider: SupermuxUsageProviderDTO?) -> some View {
        let windows = provider?.windows ?? []
        if windows.isEmpty {
            noDataRow
        } else {
            windowRows(windows)
        }
        if provider?.needsRelogin == true {
            // Stale-but-renderable data served because the credential is
            // expired: say so, or stale reads as live.
            warningRow(String(
                localized: "supermux.usage.needsLogin",
                defaultValue: "Sign in again to see usage",
                bundle: .module
            ))
        } else if provider?.source == SupermuxUsageProviderDTO.sessionLogSource {
            noteRow(String(
                localized: "supermux.usage.codex.fromSessionLog",
                defaultValue: "From last Codex session (offline)",
                bundle: .module
            ))
        }
    }

    /// The freshness footer: the OLDEST measurement on display, not the last
    /// poll attempt — a failed pass that kept last-good data must not present
    /// it as just-refreshed.
    @ViewBuilder
    private func footer(_ usage: SupermuxUsageStateDTO?) -> some View {
        if let measured = usage?.oldestMeasurementDate {
            HStack(spacing: 4) {
                if usage?.claude.source == SupermuxUsageProviderDTO.cswapSource {
                    Text(String(
                        localized: "supermux.usage.viaCswap",
                        defaultValue: "via cswap",
                        bundle: .module
                    ))
                    Text(verbatim: "·")
                }
                Text(String(
                    format: String(
                        localized: "supermux.usage.dataAsOf",
                        defaultValue: "data %@",
                        bundle: .module
                    ),
                    measured.formatted(.relative(presentation: .named))
                ))
                .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
        }
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "supermux.usage.disconnected.title",
                defaultValue: "Not Connected",
                bundle: .module
            ))
            .font(.headline)
            Text(String(
                localized: "supermux.usage.disconnected.message",
                defaultValue: "Usage limits are read from your paired Mac.",
                bundle: .module
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// Replaces the initial loading rows after the first RPC fails, and gives
    /// the user an immediate retry instead of waiting for the poll interval.
    private func initialFailurePlaceholder(
        _ message: String,
        isRefreshing: Bool,
        retry: @escaping () -> Void
    ) -> some View {
        let retryLabel = String(
            localized: "supermux.common.retry",
            defaultValue: "Retry",
            bundle: .module
        )
        return VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(String(
                localized: "supermux.usage.failed",
                defaultValue: "Usage is unavailable right now",
                bundle: .module
            ))
            .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(retryLabel)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .accessibilityLabel(retryLabel)
            .accessibilityIdentifier("SupermuxUsageRetryButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Shared pieces

    /// The meter rows for one window list, staggered top-to-bottom so the
    /// sheet settles in one quick cascade.
    private func windowRows(_ windows: [SupermuxUsageWindowDTO]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.element.identity) { index, window in
                SupermuxUsageMeterRow(window: window, appearDelay: Double(index) * 0.05)
            }
        }
    }

    /// Product-safe copy for an initial fetch failure. The raw transport
    /// diagnostic is only a presence signal here and stays in the system log.
    /// Once a snapshot has loaded, failures keep that last-good data visible.
    static func initialFailureDescription(
        hasLoaded: Bool,
        errorDescription: String?
    ) -> String? {
        guard !hasLoaded, errorDescription != nil else { return nil }
        return String(
            localized: "supermux.usage.failed.message",
            defaultValue: "Try again. If the problem continues, check your paired Mac.",
            bundle: .module
        )
    }

    /// The note replacing a provider's rows in a non-ready state, or `nil`
    /// when its rows should render. An absent payload before the first fetch
    /// reads as loading; so does an unrecognized state from a newer Mac.
    static func stateNote(for provider: SupermuxUsageProviderDTO?, hasLoaded: Bool) -> String? {
        guard let provider, hasLoaded else {
            return String(localized: "supermux.usage.loading", defaultValue: "Loading…", bundle: .module)
        }
        switch provider.state {
        case SupermuxUsageProviderDTO.readyState:
            return nil
        case SupermuxUsageProviderDTO.notConfiguredState:
            return String(
                localized: "supermux.usage.notConfigured",
                defaultValue: "No login found on your Mac",
                bundle: .module
            )
        case SupermuxUsageProviderDTO.needsLoginState:
            return String(
                localized: "supermux.usage.needsLogin",
                defaultValue: "Sign in again to see usage",
                bundle: .module
            )
        case SupermuxUsageProviderDTO.failedState:
            return provider.message ?? String(
                localized: "supermux.usage.failed",
                defaultValue: "Usage is unavailable right now",
                bundle: .module
            )
        default:
            return String(localized: "supermux.usage.loading", defaultValue: "Loading…", bundle: .module)
        }
    }

    /// The panel title's detail: Codex's capitalized plan, or Claude's active
    /// account label.
    static func providerDetail(_ provider: SupermuxUsageProviderDTO?) -> String? {
        guard let provider, provider.state == SupermuxUsageProviderDTO.readyState else { return nil }
        if let plan = provider.planType, !plan.isEmpty { return plan.capitalized }
        guard let active = provider.activeAccount else { return nil }
        return SupermuxUsageAccountLabels.name(for: active)
    }

    /// A `ready` provider that reported nothing to show. Shared so an empty
    /// Claude account and an empty Codex column read identically.
    private var noDataRow: some View {
        noteRow(String(
            localized: "supermux.usage.noData",
            defaultValue: "No usage data yet",
            bundle: .module
        ))
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One non-active cswap account: a tappable row showing the account's label
/// and tightest-window percent, expanding to its full window list.
///
/// The Mac popover pairs this with switch/enable controls; the phone is a
/// read-only mirror, so the row only discloses. Holds plain values, never a
/// store reference — it renders below the list boundary.
struct SupermuxUsageAccountRow: View {
    let account: SupermuxUsageAccountDTO

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var windows: [SupermuxUsageWindowDTO] { account.displayWindows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !windows.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.05)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(windows.isEmpty ? 0 : 1)
                        .frame(width: 8)
                    Text(SupermuxUsageAccountLabels.name(for: account))
                        .font(.footnote)
                        .foregroundStyle(account.isDisabled == true ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    trailingValue
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(windows.isEmpty)
            .accessibilityValue(isExpanded
                ? String(localized: "supermux.usage.account.expanded", defaultValue: "expanded", bundle: .module)
                : String(localized: "supermux.usage.account.collapsed", defaultValue: "collapsed", bundle: .module))
            if isExpanded, !windows.isEmpty {
                VStack(spacing: 9) {
                    ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.element.identity) { index, window in
                        SupermuxUsageMeterRow(
                            window: window,
                            appearDelay: Double(index) * 0.04,
                            isCompact: true
                        )
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A credential problem reads like cswap's TUI — a short amber label
    /// instead of a percent; the windows shown on expand may be last-good.
    @ViewBuilder
    private var trailingValue: some View {
        if let problem = SupermuxUsageAccountLabels.statusText(for: account) {
            Text(problem)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let tightest = windows.tightest {
            HStack(spacing: 6) {
                Capsule(style: .continuous)
                    .fill(SupermuxUsageStyle.color(for: tightest.severity))
                    .frame(width: 4, height: 12)
                Text(verbatim: SupermuxUsageStyle.percentText(tightest.clampedPercent))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(String(
                localized: "supermux.usage.account.unavailable",
                defaultValue: "—",
                bundle: .module
            ))
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
    }
}

extension SupermuxUsageWindowDTO {
    /// Stable per-row identity within one window list: the kind, qualified by
    /// the provider's label for scoped windows (several scoped limits share
    /// the `scoped` kind).
    ///
    /// Identity is the KIND, never the index: index identity would morph a
    /// row into a different window when the set changes and animate a percent
    /// between two unrelated limits.
    var identity: String {
        kind == Self.scopedKind ? "\(kind)|\(label ?? "")" : kind
    }
}
