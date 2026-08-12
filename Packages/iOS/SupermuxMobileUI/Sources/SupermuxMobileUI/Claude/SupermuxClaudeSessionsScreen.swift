public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The phone's Claude harness session list: every session the paired Mac is
/// hosting, grouped by working directory, with a state dot per row.
///
/// Entry point: presented as a SHEET from the workspace list's fork toolbar,
/// following ``SupermuxUsageScreen``'s mount. That deliberately avoids the
/// iPhone workspace-list `UITableView` path (SUPERMUX.md's most dangerous
/// known failure mode — a SwiftUI mount there silently disappears on the
/// phone) by not touching the list at all.
///
/// Every row's state is snapshotted ABOVE the `List`, so no view below the
/// lazy boundary holds a store reference (the SwiftUI list-boundary rule in
/// CLAUDE.md).
public struct SupermuxClaudeSessionsScreen: View {
    private let store: SupermuxClaudeSessionsStore
    private let openSession: @MainActor (SupermuxClaudeSessionDTO) -> Void

    @State private var isPresentingNewSession = false
    @State private var pendingDeletion: SupermuxClaudeSessionDTO?

    /// Creates the sessions screen.
    /// - Parameters:
    ///   - store: The live sessions session.
    ///   - openSession: Navigates to a session's chat screen.
    public init(
        store: SupermuxClaudeSessionsStore,
        openSession: @escaping @MainActor (SupermuxClaudeSessionDTO) -> Void
    ) {
        self.store = store
        self.openSession = openSession
    }

    public var body: some View {
        // Snapshot the observable state ONCE, above the list.
        let groups = SupermuxClaudeSessionPresentation.groups(for: store.sessions)
        let indicators = Dictionary(
            store.sessions.map { ($0.sessionID, store.indicator(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let hasLoaded = store.hasLoaded
        let errorDescription = store.lastErrorDescription

        content(groups: groups, indicators: indicators, hasLoaded: hasLoaded, error: errorDescription)
            .navigationTitle(String(
                localized: "supermux.claude.sessions.title",
                defaultValue: "Claude",
                bundle: .module
            ))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingNewSession = true
                    } label: {
                        Label {
                            Text(String(
                                localized: "supermux.claude.newSession",
                                defaultValue: "New Session",
                                bundle: .module
                            ))
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingNewSession) {
                SupermuxClaudeNewSessionSheet(store: store) { session in
                    isPresentingNewSession = false
                    store.markOpened(id: session.sessionID)
                    openSession(session)
                }
            }
            .confirmationDialog(
                String(
                    localized: "supermux.claude.delete.title",
                    defaultValue: "Delete Session?",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { session in
                Button(role: .destructive) {
                    let id = session.sessionID
                    pendingDeletion = nil
                    Task { try? await store.deleteSession(id: id) }
                } label: {
                    Text(String(
                        localized: "supermux.claude.delete.confirm",
                        defaultValue: "Delete",
                        bundle: .module
                    ))
                }
            } message: { _ in
                Text(String(
                    localized: "supermux.claude.delete.message",
                    defaultValue: "The transcript is removed from your Mac. This cannot be undone.",
                    bundle: .module
                ))
            }
            .task { await store.run() }
            .accessibilityIdentifier("SupermuxClaudeSessionsScreen")
    }

    @ViewBuilder
    private func content(
        groups: [SupermuxClaudeSessionPresentation.Group],
        indicators: [String: SupermuxClaudeSessionIndicator],
        hasLoaded: Bool,
        error: String?
    ) -> some View {
        if !hasLoaded, error != nil {
            failurePlaceholder
        } else if hasLoaded, groups.isEmpty {
            emptyPlaceholder
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            row(session, indicator: indicators[session.sessionID] ?? .idle)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await store.refresh() }
        }
    }

    /// One session row. Receives plain values only — no store reference
    /// crosses the `ForEach` boundary; the swipe actions capture the id and
    /// call back through the screen's `store` closure instead.
    private func row(
        _ session: SupermuxClaudeSessionDTO,
        indicator: SupermuxClaudeSessionIndicator
    ) -> some View {
        let subtitle = SupermuxClaudeSessionPresentation.subtitle(for: session)
        let cost = SupermuxClaudeSessionPresentation.costLabel(session.cost)
        return Button {
            store.markOpened(id: session.sessionID)
            openSession(session)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(SupermuxClaudeStyle.body())
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let cost {
                        Text(cost)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    // A fixed slot so titles do not shift as dots come and go.
                    SupermuxClaudeStatusDot(indicator: indicator)
                        .frame(width: SupermuxClaudeStyle.statusDotSize)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = session
            } label: {
                Label {
                    Text(String(
                        localized: "supermux.claude.delete",
                        defaultValue: "Delete",
                        bundle: .module
                    ))
                } icon: {
                    Image(systemName: "trash")
                }
            }
            if session.state == .working || session.state == .starting || session.state == .idle {
                Button {
                    let id = session.sessionID
                    Task { try? await store.endSession(id: id) }
                } label: {
                    Label {
                        Text(String(
                            localized: "supermux.claude.end",
                            defaultValue: "End",
                            bundle: .module
                        ))
                    } icon: {
                        Image(systemName: "stop.circle")
                    }
                }
                .tint(.orange)
            }
        }
    }

    private var emptyPlaceholder: some View {
        ContentUnavailableView {
            Label {
                Text(String(
                    localized: "supermux.claude.empty.title",
                    defaultValue: "No Claude Sessions",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "sparkles")
            }
        } description: {
            Text(String(
                localized: "supermux.claude.empty.message",
                defaultValue: "Start a session to run Claude Code on your Mac from here.",
                bundle: .module
            ))
        } actions: {
            Button {
                isPresentingNewSession = true
            } label: {
                Text(String(
                    localized: "supermux.claude.newSession",
                    defaultValue: "New Session",
                    bundle: .module
                ))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var failurePlaceholder: some View {
        ContentUnavailableView {
            Label {
                Text(String(
                    localized: "supermux.claude.failure.title",
                    defaultValue: "Couldn’t Reach Your Mac",
                    bundle: .module
                ))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        } description: {
            Text(String(
                localized: "supermux.claude.failure.message",
                defaultValue: "Check that your Mac is awake and paired, then try again.",
                bundle: .module
            ))
        } actions: {
            Button {
                Task { await store.refresh() }
            } label: {
                Text(String(
                    localized: "supermux.common.retry",
                    defaultValue: "Retry",
                    bundle: .module
                ))
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// The session-row state dot: teal working, blue finished-not-opened, red
/// failed, nothing at all for a session with no news.
///
/// Ported from remodex's `SidebarThreadRunBadgeView`, minus its "waiting on
/// you" state — harness sessions never wait on a permission prompt.
public struct SupermuxClaudeStatusDot: View, Equatable {
    private let indicator: SupermuxClaudeSessionIndicator

    /// Creates a status dot.
    /// - Parameter indicator: The row's folded indicator.
    public init(indicator: SupermuxClaudeSessionIndicator) {
        self.indicator = indicator
    }

    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.indicator == rhs.indicator
    }

    public var body: some View {
        if SupermuxClaudeSessionPresentation.showsDot(for: indicator) {
            Circle()
                .fill(SupermuxClaudeSessionPresentation.dotColor(for: indicator))
                .frame(
                    width: SupermuxClaudeStyle.statusDotSize,
                    height: SupermuxClaudeStyle.statusDotSize
                )
                .accessibilityElement()
                .accessibilityLabel(
                    SupermuxClaudeSessionPresentation.dotAccessibilityLabel(for: indicator)
                )
        }
    }
}
