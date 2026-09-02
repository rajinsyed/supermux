import AppKit
import Combine
import CmuxSettings
import Foundation
import SupermuxKit

/// Feeds the Changes panel's header the pull request cmux already tracks for
/// the selected workspace, so a PR button appears without any fetch of our
/// own.
///
/// cmux's sidebar probe writes the workspace's PR into `panelPullRequests`,
/// which flows through `sidebarObservationPublisher`. This observer subscribes
/// to that stream for the selected workspace only (debounced by upstream's
/// 40 ms coalesce interval, main-queue delivery) and republishes the
/// **first-in-display-order** PR — the same value the sidebar row shows —
/// only when it actually changes, so the panel never re-renders on unrelated
/// workspace telemetry.
@MainActor
final class SupermuxChangesPullRequestObserver: ObservableObject {
    /// The selected workspace's PR badge, or `nil`.
    @Published private(set) var knownPullRequest: SupermuxPullRequest?

    private static let coalesceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(40)

    private var observedWorkspaceId: UUID?
    private var cancellable: AnyCancellable?

    /// (Re)subscribes when the selected workspace changes; a no-op for the
    /// same workspace so re-renders never resubscribe.
    func observe(workspace: Workspace?) {
        guard workspace?.id != observedWorkspaceId else { return }
        observedWorkspaceId = workspace?.id
        cancellable = nil
        publishIfChanged(Self.pullRequest(for: workspace))
        guard let workspace else { return }
        cancellable = workspace.sidebarObservationPublisher
            .debounce(for: Self.coalesceInterval, scheduler: DispatchQueue.main)
            .sink { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.publishIfChanged(Self.pullRequest(for: workspace))
            }
    }

    private func publishIfChanged(_ pullRequest: SupermuxPullRequest?) {
        if pullRequest != knownPullRequest {
            knownPullRequest = pullRequest
        }
    }

    private static func pullRequest(for workspace: Workspace?) -> SupermuxPullRequest? {
        workspace?.sidebarPullRequestsInDisplayOrder().first.flatMap(SupermuxPullRequest.init(sidebarState:))
    }
}

enum SupermuxChangesPullRequestLinkOpener {
    /// Opens a PR-related link honoring cmux's PR-link routing: in the cmux
    /// browser (split right in the selected workspace) when the setting is
    /// on, else the default browser.
    @MainActor
    static func open(_ url: URL, tabManager: TabManager?) {
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(),
           let tabManager,
           let targetId = tabManager.selectedTabId,
           tabManager.openBrowser(
               inWorkspace: targetId,
               url: url,
               preferSplitRight: true,
               insertAtEnd: true
           ) != nil {
            return
        }
        _ = NSWorkspace.shared.open(url)
    }
}
