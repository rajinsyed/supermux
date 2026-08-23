import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Focused pane notification suppression", .serialized)
@MainActor
struct SupermuxFocusedPaneNotificationTests {
    @Test("A notification for the focused pane creates no alert state")
    func focusedPaneNotificationCreatesNoAlertState() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredAlertCount = 0
        var suppressedEffects: [TerminalNotificationPolicyEffects] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _, _ in
            deliveredAlertCount += 1
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _, effects in
            suppressedEffects.append(effects)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            for workspace in manager.tabs {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)

        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelID,
            title: "Turn complete",
            subtitle: "",
            body: "The pane is already focused"
        )

        let notification = try #require(store.notifications.first)
        #expect(notification.isRead)
        #expect(!notification.paneFlash)
        #expect(store.unreadNotificationCount == 0)
        #expect(store.unreadCount(forTabId: workspace.id) == 0)
        #expect(!store.workspaceIsUnread(forTabId: workspace.id))
        #expect(!store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelID))
        #expect(!store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelID))
        #expect(store.focusedReadIndicatorSurfaceId(forTabId: workspace.id) == nil)
        #expect(deliveredAlertCount == 0)
        let focusedEffects = try #require(suppressedEffects.first)
        #expect(suppressedEffects.count == 1)
        #expect(!focusedEffects.desktop)
        #expect(!focusedEffects.sound)
        #expect(focusedEffects.command)
    }

    @Test("Focus suppression requires an exact pane target")
    func focusSuppressionRequiresExactPaneTarget() {
        let policy = SupermuxFocusedPaneNotificationPolicy()

        #expect(policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            externalDeliverySuppressed: true
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: nil,
            externalDeliverySuppressed: true
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            externalDeliverySuppressed: false
        ))
        #expect(!policy.targetIsAlreadyVisible(
            surfaceID: UUID(),
            externalDeliverySuppressed: true,
            targetWindowIsKey: false
        ))
    }

    @Test("Focused pane policy suppresses presentation but preserves history and automation")
    func focusedPanePolicySuppressesPresentationOnly() {
        let policy = SupermuxFocusedPaneNotificationPolicy()
        let original = TerminalNotificationPolicyEffects()
        let resolved = policy.resolvedEffects(
            original,
            targetIsAlreadyVisible: true
        )

        #expect(resolved.record)
        #expect(!resolved.markUnread)
        #expect(!resolved.reorderWorkspace)
        #expect(!resolved.desktop)
        #expect(!resolved.sound)
        #expect(resolved.command)
        #expect(!resolved.paneFlash)
    }
}
