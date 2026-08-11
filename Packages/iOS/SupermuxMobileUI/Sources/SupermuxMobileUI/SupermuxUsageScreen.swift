import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The phone's usage-limits sheet: the Mac tracker's Claude Code and Codex
/// rate-limit windows as meter rows with reset countdowns, the extra cswap
/// accounts below the active one, and an honest freshness footer.
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
        NavigationStack {
            content
                .navigationTitle(String(
                    localized: "supermux.usage.title",
                    defaultValue: "Usage Limits",
                    bundle: .module
                ))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .accessibilityIdentifier("SupermuxUsageScreen")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(
                                localized: "supermux.common.done",
                                defaultValue: "Done",
                                bundle: .module
                            ))
                        }
                        .accessibilityIdentifier("SupermuxUsageDoneButton")
                    }
                }
        }
        // Opening the sheet asks for a refresh, so the numbers are current on
        // arrival instead of up to one poll period old. The Mac's shared
        // floor makes this free when the data is already fresh.
        .task {
            await store?.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            // Snapshot the observable state ONCE, above the List: every row
            // below receives plain values, so no view under the list boundary
            // holds a store reference (see the SwiftUI list-boundary rule in
            // CLAUDE.md / the cmux-debugging skill).
            let usage = store.usage
            let hasLoaded = store.hasLoaded
            List {
                providerSection(
                    title: String(
                        localized: "supermux.usage.claude",
                        defaultValue: "Claude Code",
                        bundle: .module
                    ),
                    provider: usage?.claude,
                    hasLoaded: hasLoaded
                ) {
                    claudeRows(usage?.claude)
                }
                providerSection(
                    title: String(
                        localized: "supermux.usage.codex",
                        defaultValue: "Codex",
                        bundle: .module
                    ),
                    provider: usage?.codex,
                    hasLoaded: hasLoaded
                ) {
                    codexRows(usage?.codex)
                }
                footerSection(usage)
            }
            // The grouped styles are iOS-only and this package also builds
            // for macOS, so the style is set on the iOS side only; the
            // sheet's List already defaults to inset-grouped there.
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await store.refresh() }
        } else {
            ContentUnavailableView {
                Label {
                    Text(String(
                        localized: "supermux.usage.disconnected.title",
                        defaultValue: "Not Connected",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "wifi.slash")
                }
            } description: {
                Text(String(
                    localized: "supermux.usage.disconnected.message",
                    defaultValue: "Usage limits are read from your paired Mac.",
                    bundle: .module
                ))
            }
        }
    }

    // MARK: - Provider sections

    /// One provider's section: its header (plus the detail line the Mac shows
    /// — account label or Codex plan) over either its terminal-state note or
    /// the rows the builder supplies.
    @ViewBuilder
    private func providerSection(
        title: String,
        provider: SupermuxUsageProviderDTO?,
        hasLoaded: Bool,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        Section {
            if let note = Self.stateNote(for: provider, hasLoaded: hasLoaded) {
                noteRow(note)
            } else {
                rows()
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                if let detail = Self.providerDetail(provider) {
                    Text(detail)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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
                    noteRow(String(
                        localized: "supermux.usage.noData",
                        defaultValue: "No usage data yet",
                        bundle: .module
                    ))
                }
            } else {
                windowRows(active.displayWindows)
            }
        }
        let others = (provider?.accounts ?? []).filter { $0.id != provider?.activeAccount?.id }
        ForEach(others) { account in
            SupermuxUsageAccountRow(account: account)
        }
    }

    /// Codex's own windows plus its stale-data notes.
    @ViewBuilder
    private func codexRows(_ provider: SupermuxUsageProviderDTO?) -> some View {
        windowRows(provider?.windows ?? [])
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
    private func footerSection(_ usage: SupermuxUsageStateDTO?) -> some View {
        if let measured = usage?.oldestMeasurementDate {
            Section {
                EmptyView()
            } footer: {
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
            }
        }
    }

    // MARK: - Shared pieces

    /// The meter rows for one window list, staggered top-to-bottom so the
    /// sheet settles in one quick cascade.
    private func windowRows(_ windows: [SupermuxUsageWindowDTO]) -> some View {
        ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.element.identity) { index, window in
            SupermuxUsageMeterRow(window: window, appearDelay: Double(index) * 0.05)
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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

    /// The header's detail line: Codex's capitalized plan, or Claude's active
    /// account label.
    static func providerDetail(_ provider: SupermuxUsageProviderDTO?) -> String? {
        guard let provider, provider.state == SupermuxUsageProviderDTO.readyState else { return nil }
        if let plan = provider.planType, !plan.isEmpty { return plan.capitalized }
        guard let active = provider.activeAccount else { return nil }
        return SupermuxUsageAccountLabels.name(for: active)
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func warningRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.orange)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
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

    private var windows: [SupermuxUsageWindowDTO] { account.displayWindows }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !windows.isEmpty else { return }
                withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(windows.isEmpty ? 0 : 1)
                    Text(SupermuxUsageAccountLabels.name(for: account))
                        .font(.subheadline)
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(windows.sortedForDisplay().enumerated()), id: \.element.identity) { index, window in
                        SupermuxUsageMeterRow(window: window, appearDelay: Double(index) * 0.04)
                    }
                }
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
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let tightest = windows.tightest {
            Text(verbatim: SupermuxUsageStyle.percentText(tightest.clampedPercent))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(SupermuxUsageStyle.color(for: tightest.severity))
        } else {
            Text(String(
                localized: "supermux.usage.account.unavailable",
                defaultValue: "—",
                bundle: .module
            ))
            .font(.subheadline)
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
