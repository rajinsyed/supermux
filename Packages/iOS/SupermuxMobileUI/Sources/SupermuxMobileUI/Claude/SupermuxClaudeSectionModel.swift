public import CmuxMobileRPC
import Observation
public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// Owns the phone's Claude harness session on behalf of the toolbar entry.
///
/// **Why the button does not own this.** The entry renders inside the
/// workspace list's `showsNavigationToolbar` branch, which goes false on every
/// navigation push — a store held in the button's own `@State` would be
/// destroyed when a workspace opens and rebuilt on the way back, losing the
/// session list and restarting the subscription after routine navigation. This
/// model is held by the list itself (a stable view) and driven by
/// ``SwiftUICore/View/supermuxClaudeDriver(model:connection:)``, exactly like
/// ``SupermuxUsageSectionModel`` (touchpoint #340b) and the projects driver.
///
/// One session runs per `(connection identity, capability snapshot)` pair, so
/// a reconnect — or capabilities arriving after the `mobile.host.status` round
/// trip — replaces the store instead of driving a dead client.
@MainActor
@Observable
public final class SupermuxClaudeSectionModel {
    /// The live sessions session, or `nil` while disconnected.
    public private(set) var store: SupermuxClaudeSessionsStore?

    /// The connection's cached options snapshot (model catalog, effort levels,
    /// slash commands), fetched once per connection so the chat screen's pills
    /// and autocomplete have something to show the moment it opens.
    public private(set) var options: SupermuxClaudeOptionsDTO?

    /// Whether the toolbar entry renders: a live session whose host advertises
    /// `supermux.claude.v1`.
    public var showsEntry: Bool { store?.showsClaudeHarness == true }

    /// Sessions currently running a turn, for the entry's badge.
    public var workingCount: Int {
        store?.sessions.count { $0.state == .working || $0.state == .starting } ?? 0
    }

    /// Creates an idle model. The driver installs a session.
    public init() {}

    /// Runs one connection's harness session until cancelled.
    ///
    /// Cancellation (a navigation push covering the list) stops the event
    /// subscription but KEEPS the store installed, so reopening the sheet
    /// shows the last known list immediately and resumes against the same
    /// session rather than flashing an empty screen.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam for this connection.
    ///   - hostCapabilities: The host's raw advertised capability strings.
    ///   - connectionID: The driver's task identity for this connection.
    public func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable?
    ) async {
        if connectionID != sessionConnectionID || store == nil {
            store = SupermuxClaudeSessionsStore(
                client: client,
                capabilities: SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
            )
            sessionConnectionID = connectionID
            options = nil
        }
        guard let store, store.showsClaudeHarness else { return }
        if options == nil || options?.models.isEmpty == true {
            // Refetch while the catalog is empty, not just while nil: the Mac
            // can only serve a model list once at least one session is live,
            // so a snapshot taken before the first session exists would
            // otherwise pin an empty catalog for the whole connection.
            options = try? await store.options()
        }
        await store.run()
    }

    /// Drops the session (the connection went away), so the entry hides rather
    /// than listing sessions from a Mac that is no longer paired.
    public func endSession() {
        store = nil
        options = nil
        sessionConnectionID = nil
    }

    @ObservationIgnored private var sessionConnectionID: AnyHashable?
}

extension View {
    /// Drives a ``SupermuxClaudeSectionModel`` from the shell's connection
    /// seam. Attach to a STABLE view (the list itself), never inside the
    /// toolbar branch or a lazy row — the session's structured `.task` must
    /// outlive a navigation push.
    ///
    /// - Parameters:
    ///   - model: The Claude model the fence's `@State` owns.
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (the entry hides).
    @MainActor
    public func supermuxClaudeDriver(
        model: SupermuxClaudeSectionModel,
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    ) -> some View {
        let connectionKey = SupermuxClaudeConnectionKey(connection: connection)
        return task(id: connectionKey) {
            guard let connection else {
                model.endSession()
                return
            }
            await model.runSession(
                client: SupermuxMacClient(client: connection.rpcClient),
                hostCapabilities: connection.hostCapabilities,
                connectionID: connectionKey
            )
        }
    }
}

/// Hashable identity for one harness session: the RPC client's object identity
/// plus the capability snapshot it arrived with, mirroring
/// ``SupermuxUsageConnectionKey``.
struct SupermuxClaudeConnectionKey: Hashable {
    let clientID: ObjectIdentifier?
    let hostCapabilities: Set<String>?

    init(connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?) {
        self.clientID = connection.map { ObjectIdentifier($0.rpcClient) }
        self.hostCapabilities = connection?.hostCapabilities
    }
}

/// The workspace list's Claude harness toolbar entry.
///
/// Renders nothing unless the host advertises `supermux.claude.v1`, so a fork
/// phone paired with an upstream cmux Mac shows exactly upstream's toolbar.
///
/// Deliberately owns NO session state (see ``SupermuxClaudeSectionModel``); it
/// only presents the sheet and its navigation.
public struct SupermuxClaudeToolbarButton: View {
    private let model: SupermuxClaudeSectionModel

    @State private var isPresented = false

    /// Creates the toolbar entry.
    /// - Parameter model: The list-owned harness session (see
    ///   ``SwiftUICore/View/supermuxClaudeDriver(model:connection:)``).
    public init(model: SupermuxClaudeSectionModel) {
        self.model = model
    }

    public var body: some View {
        if model.showsEntry {
            Button {
                isPresented = true
            } label: {
                Image(systemName: "sparkles")
                    .symbolVariant(model.workingCount > 0 ? .circle.fill : .none)
            }
            .accessibilityLabel(String(
                localized: "supermux.claude.sessions.title",
                defaultValue: "Claude",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxClaudeToolbarButton")
            .sheet(isPresented: $isPresented) {
                SupermuxClaudeSessionsFlow(model: model)
            }
        }
    }
}

/// The sheet's own navigation stack: the session list, pushing one chat
/// screen at a time.
///
/// The chat store is created per pushed session and torn down with the push,
/// which is correct: the transcript is re-anchored from `claude.history` on
/// arrival, and the MAC keeps running the session regardless of whether any
/// phone is watching.
struct SupermuxClaudeSessionsFlow: View {
    let model: SupermuxClaudeSectionModel

    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = model.store {
                    SupermuxClaudeSessionsScreen(store: store) { session in
                        path.append(session.sessionID)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: String.self) { sessionID in
                if let store = model.store {
                    SupermuxClaudeChatScreen(
                        store: store.conversationStore(for: sessionID),
                        options: model.options,
                        resume: {
                            // The chat screen's ended-notice Resume: restart
                            // the Mac process for this session in place. The
                            // RPC answers OK even when startup failed, so
                            // success means the snapshot came back live.
                            guard let result = try? await store.resumeSession(id: sessionID) else {
                                return false
                            }
                            return result.session.state != .failed
                                && result.session.state != .ended
                        }
                    )
                }
            }
        }
    }
}
