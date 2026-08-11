import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The phone's usage-limits sheet: a summary dial over one panel per provider,
/// each carrying its windows as meter rows, the extra cswap accounts below the
/// active one, and an honest freshness footer.
///
/// Presented as a floating Liquid Glass card sized to its content
/// (``SupermuxUsageSheetModifier``) rather than as a full-screen sheet — the
/// whole tracker is a handful of rows, so a full sheet would be mostly empty
/// space and would hide the workspace list for no reason.
///
/// Read-only by design — the Mac owns polling and every cswap mutation, so
/// there is no account switching here (see ``SupermuxMobileUsageStore``).
/// Pull-to-refresh and presentation both ask the Mac for its current
/// snapshot, which the Mac's own floor throttles.
///
/// The screen does NOT own a poll loop: it renders the store the presenting
/// gauge already drives, so both surfaces show one snapshot and one request
/// cadence instead of two.
public struct SupermuxUsageScreen: View {
    private let store: SupermuxMobileUsageStore?

    @Environment(\.dismiss) private var dismiss

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
            let isRefreshing = store.isRefreshing
            VStack(spacing: 14) {
                header(usage: usage, hasLoaded: hasLoaded, isRefreshing: isRefreshing)
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
        } else {
            disconnectedPlaceholder
        }
    }

    // MARK: - Header

    /// The summary line: the tightest limit as a dial, what it is in words,
    /// and the refresh control. Answers "am I about to run out?" before the
    /// reader parses a single row.
    private func header(
        usage: SupermuxUsageStateDTO?,
        hasLoaded: Bool,
        isRefreshing: Bool
    ) -> some View {
        HStack(spacing: 14) {
            SupermuxUsageGauge(window: usage?.tightestWindow, pointSize: 52, showsValue: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    localized: "supermux.usage.title",
                    defaultValue: "Usage Limits",
                    bundle: .module
                ))
                .font(.headline)
                Text(Self.headlineDetail(usage: usage, hasLoaded: hasLoaded))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            refreshButton(isRefreshing: isRefreshing)
            closeButton
        }
    }

    private func refreshButton(isRefreshing: Bool) -> some View {
        circleButton(
            label: String(
                localized: "supermux.usage.refresh",
                defaultValue: "Refresh",
                bundle: .module
            ),
            identifier: "SupermuxUsageRefreshButton",
            action: { Task { await store?.refresh() } }
        ) {
            ZStack {
                // Both states occupy the same slot, so the header does not
                // reflow when a refresh starts.
                ProgressView()
                    .controlSize(.small)
                    .opacity(isRefreshing ? 1 : 0)
                Image(systemName: "arrow.clockwise")
                    .opacity(isRefreshing ? 0 : 1)
            }
        }
        .disabled(isRefreshing)
    }

    /// The card's explicit dismiss. The sheet has no navigation bar, and its
    /// clear backdrop leaves only a 12pt margin around the card — too little
    /// to expect anyone to hit — so the close affordance has to live in the
    /// header rather than relying on tap-outside.
    private var closeButton: some View {
        circleButton(
            label: String(
                localized: "supermux.common.done",
                defaultValue: "Done",
                bundle: .module
            ),
            identifier: "SupermuxUsageDoneButton",
            action: { dismiss() }
        ) {
            Image(systemName: "xmark")
        }
    }

    private func circleButton(
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        Button(action: action) {
            icon()
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.07), in: Circle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// The header's one-line summary: which window is tightest and how full it
    /// is, or the loading/idle state when there is nothing to summarize.
    static func headlineDetail(usage: SupermuxUsageStateDTO?, hasLoaded: Bool) -> String {
        guard hasLoaded else {
            return String(localized: "supermux.usage.loading", defaultValue: "Loading…", bundle: .module)
        }
        guard let tightest = usage?.tightestWindow else {
            return String(
                localized: "supermux.usage.noData",
                defaultValue: "No usage data yet",
                bundle: .module
            )
        }
        return String(
            format: String(
                localized: "supermux.usage.headline",
                defaultValue: "%1$@ %2$@ used",
                bundle: .module
            ),
            SupermuxUsageStyle.label(for: tightest),
            SupermuxUsageStyle.percentText(tightest.clampedPercent)
        )
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
        .supermuxUsagePanel()
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
