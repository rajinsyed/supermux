import CmuxAppKitSupportUI
import SupermuxKit
import SwiftUI

extension SupermuxComposition {
    /// App-wide usage tracker model: one poll loop and one pair of provider
    /// snapshots shared by every window's sidebar footer button.
    static let usageModel = SupermuxUsageModel()
}

/// The sidebar-footer usage button that replaces cmux's help "?" button (see
/// the `sidebar-usage-button` touchpoint in `ContentView.swift`).
///
/// The icon is a tiny gauge ring filled to the tightest Claude/Codex limit;
/// clicking opens the unified usage popover. Everything the "?" popover
/// offered stays reachable through the popover's footer: Send Feedback
/// directly, and a Help item popping up a menu with the same entries
/// (Welcome, Keyboard Shortcuts, Import Browser Data, Docs, Changelog,
/// GitHub, Issues, Discord, Check for Updates, Upgrade).
struct SupermuxUsageMenuButton: View {
    /// The same feedback hook the replaced help button received.
    let onSendFeedback: () -> Void

    @State private var isPopoverPresented = false

    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    private let title = String(localized: "supermux.usage.button", defaultValue: "Usage Limits")

    var body: some View {
        let model = SupermuxComposition.usageModel
        Button {
            isPopoverPresented.toggle()
        } label: {
            SupermuxUsageGaugeIcon(
                window: model.tightestWindow,
                pointSize: SidebarFooterButtonMetrics.helpIconSize - 2
            )
            .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            popoverContent
        })
        // Drives the shared poll loop while any sidebar shows the button;
        // the model dedupes owners across windows.
        .task {
            await SupermuxComposition.usageModel.runPollLoop()
        }
        // Opening the popover asks for a refresh; the model's shared floor
        // (minimumRefreshInterval) makes this a no-op when data is recent.
        .onChange(of: isPopoverPresented) { _, isPresented in
            guard isPresented else { return }
            Task { await SupermuxComposition.usageModel.refresh() }
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SupermuxUsageMenuButton")
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SupermuxUsagePopoverView(
                model: SupermuxComposition.usageModel,
                onRefresh: {
                    Task { await SupermuxComposition.usageModel.refresh() }
                },
                onSwitchAccount: { slot in
                    Task { await SupermuxComposition.usageModel.switchClaudeAccount(toSlot: slot) }
                },
                onSwitchToBest: {
                    Task { await SupermuxComposition.usageModel.switchClaudeToBest() }
                },
                onSetAccountEnabled: { slot, enabled in
                    Task { await SupermuxComposition.usageModel.setClaudeAccountEnabled(enabled, slot: slot) }
                }
            )
            Divider()
            footerRow
        }
    }

    private var footerRow: some View {
        HStack(spacing: 0) {
            footerLink(
                title: String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
                systemImage: "bubble.left.and.text.bubble.right",
                accessibilityIdentifier: "SupermuxUsageSendFeedbackRow"
            ) {
                isPopoverPresented = false
                onSendFeedback()
            }
            Spacer(minLength: 8)
            footerLink(
                title: String(localized: "supermux.usage.helpRow", defaultValue: "Help"),
                systemImage: "questionmark.circle",
                accessibilityIdentifier: "SupermuxUsageHelpRow"
            ) {
                isPopoverPresented = false
                SupermuxUsageHelpMenu.popUpAtMouse()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerLink(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Builds and presents the help menu with the exact entries the replaced "?"
/// popover had, wired to the same actions. A programmatic NSMenu, not the
/// main-menu Help item: cmux's `CommandGroup(replacing: .help)` menu carries
/// only a subset (no Welcome/Import Browser Data/GitHub), and depending on
/// main-menu ordering would be fragile anyway.
@MainActor
enum SupermuxUsageHelpMenu {
    static func popUpAtMouse() {
        let menu = NSMenu()
        addItem(
            to: menu,
            title: String(localized: "sidebar.help.welcome", defaultValue: "Welcome to cmux!")
        ) {
            AppDelegate.shared?.openWelcomeWorkspace()
        }
        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
            addItem(
                to: menu,
                title: String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…")
            ) {
                ProUpgradePresenter.present()
            }
        }
        addItem(
            to: menu,
            title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        ) {
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(
                    debugSource: "supermuxUsageHelpMenu.keyboardShortcuts",
                    navigationTarget: .keyboardShortcuts
                )
            } else {
                AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
            }
        }
        addItem(
            to: menu,
            title: String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…")
        ) {
            BrowserDataImportCoordinator.shared.presentImportDialog()
        }
        menu.addItem(.separator())
        addLinkItem(to: menu, title: String(localized: "about.docs", defaultValue: "Docs"), url: "https://cmux.com/docs")
        addLinkItem(to: menu, title: String(localized: "sidebar.help.changelog", defaultValue: "Changelog"), url: "https://cmux.com/docs/changelog")
        addLinkItem(to: menu, title: String(localized: "about.github", defaultValue: "GitHub"), url: "https://github.com/manaflow-ai/cmux")
        addLinkItem(to: menu, title: String(localized: "sidebar.help.githubIssues", defaultValue: "GitHub Issues"), url: "https://github.com/manaflow-ai/cmux/issues")
        addLinkItem(to: menu, title: String(localized: "sidebar.help.discord", defaultValue: "Discord"), url: "https://discord.gg/xsgFEVrWCZ")
        menu.addItem(.separator())
        addItem(
            to: menu,
            title: String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")
        ) {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func addItem(to menu: NSMenu, title: String, action: @escaping @MainActor () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        menu.addItem(item)
    }

    private static func addLinkItem(to menu: NSMenu, title: String, url: String) {
        addItem(to: menu, title: title) {
            guard let url = URL(string: url) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Objective-C trampoline holding a Swift closure; retained by its menu
    /// item via `representedObject` for the menu's (transient) lifetime.
    private final class MenuAction: NSObject {
        private let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func fire() { MainActor.assumeIsolated { action() } }
    }
}
