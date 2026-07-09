# Supermux touchpoints — registry of modified upstream files

Every upstream (cmux) file that supermux modifies is listed here. Each modification is fenced in
the file with `SUPERMUX:begin <id>` … `SUPERMUX:end <id>` comments. If an upstream merge
clobbers one, re-apply it from the "How to re-apply" instructions below, then run
`scripts/supermux-check-touchpoints.sh` to verify the registry and the code agree.

Rules for adding a touchpoint:
- Keep it as small as possible — a call into `Packages/SupermuxKit` or `Sources/Supermux` code.
- Fence it: `// SUPERMUX:begin <id>` / `// SUPERMUX:end <id>` (use `<!-- -->` in Markdown/XML).
- Register it in the table AND add a "How to re-apply" entry.

## Registry

| # | File | Fence id | What it does |
|---|------|----------|--------------|
| 1 | `CLAUDE.md` | `claude-md-pointer` | Points agents at SUPERMUX.md before they work in this repo |
| 2 | `Sources/ContentView.swift` | `sidebar-projects-section`, `sidebar-hide-project-workspaces`, `sidebar-flatrow-activity`, `sidebar-selection-faint`, `sidebar-unified-row-style`, `sidebar-projects-empty-area` | Mounts `SupermuxProjectsMount()` atop the sidebar; hides project-owned workspaces from the flat list and threads a `projectHiddenWorkspaceIds` set through `WorkspaceListRenderContext` — shift-click ranges, Close Tabs Below/Above/Other, and Move Up/Down exclude project-hidden workspaces (via a fenced `TabItemView.projectHiddenWorkspaceIds()` helper computed only in event handlers and the on-demand context-menu builder), the four Move/Close menu items disable on visible-neighbor availability instead of raw full-list indices (so they are never enabled no-ops when only hidden rows lie in that direction), and a fenced `.onChange` strips newly project-hidden ids from `selectedTabIds`; renders the agent-activity indicator on flat-list workspace rows; gives the flat-list selection the faint accent tint used by nested project rows (honoring `sidebarSelectionColorHex` — the user hue at 0.16 opacity — before falling back to `accentColor`); restyles the flat-list row to the nested project-workspace design (`sidebar-unified-row-style`: 11.5·scale title semibold-only-when-selected, spacing-2 line stack, vertical padding 4, corner radius 5, hover tint primary@0.06); subtracts the Projects-section height from the empty-area remainder so the sidebar's empty space stays unscrollable |
| 3 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the SupermuxKit package + `Sources/Supermux/` files into the cmux target, `cmuxTests/SupermuxSidebarBranchTests.swift` + `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` into the cmuxTests target, and the three `AppIcon*.icon` Icon Composer files into the app Resources phase (see #17) |
| 4 | `.github/swift-file-length-budget.tsv` | `unfenced` | Budget rows raised by exactly the fenced growth in their files (see #4 notes below) |
| 4b | `Resources/Localizable.xcstrings` | `unfenced` | Adds en+ja entries for all `supermux.*` keys (additive only; never edits non-supermux keys — sole exceptions, all for the #80 fork behavior: the en+ja values of `settings.app.workspaceInheritWorkingDirectory.subtitleOff` (#82) and of `settings.search.alias.setting.app.workspace-inherit-working-directory` (#84) are rewritten) |
| 5 | `Sources/RightSidebarPanelView.swift` | `right-sidebar-changes-mode-*`, `right-sidebar-compact-mode-bar` | Adds the `changes` right-sidebar mode (case/label/symbol/shortcut/rootsync) and renders `SupermuxChangesMount` for it; `right-sidebar-compact-mode-bar` wraps the mode-bar controls in `ViewThatFits` so the mode buttons collapse to icon-only when the sidebar is narrow (keeps the close button visible down to the lowered min width), with a third fallback putting the icon-only row in a horizontal `ScrollView` so mode buttons scroll instead of clipping at extreme narrowness; `right-sidebar-changes-mode-focushost` mounts `SupermuxChangesFocusHostBridge`/`SupermuxChangesFocusHostView` as the changes panel's background, registering a geometry-based focus host with the window's `MainWindowFocusController` |
| 6 | `Sources/RightSidebarMode+Availability.swift` | `right-sidebar-changes-mode-*` | `changes` is always available and reachable from the CLI mode argument |
| 7 | `Sources/RightSidebarToolPanel.swift` | `right-sidebar-changes-mode-*` | `.changes` joins the `.feed, .dock` no-op groups (sync/focus/intent/anchor, ×4) |
| 8 | `Sources/MainWindowFocusController.swift` | `right-sidebar-changes-mode-*` | Focus routing for the changes mode; the `right-sidebar-changes-mode-focushost` fences add a weak `changesHost` + `registerChangesHost(_:)` and changes-ownership checks in `ownsRightSidebarFocus`/`rightSidebarModeOwning`, so commit-field focus maps to the `.changes` intent and the hide path restores terminal focus |
| 9 | `Sources/ContentView+RightSidebarCommandPalette.swift` | `right-sidebar-changes-mode-*` | Palette command id for "Show Changes"; not openable as a pane |
| 10 | `CLI/cmux.swift` | `right-sidebar-changes-mode-*` | CLI accepts `cmux right-sidebar set changes` (and the `changes` alias) |
| 11 | `Sources/KeyboardShortcutSettings.swift` | `run-toggle-shortcut-*` | `supermuxToggleRun` action (case/label/default ⌘G, shared with Find Next) |
| 12 | `Sources/AppDelegate.swift` | `run-toggle-shortcut-*` | ⌘G dispatch: Find Next while find overlay is open, run toggle otherwise; auto-repeat key events are excluded from the run toggle |
| 13 | `.github/workflows/ci.yml` | `ci-package-tests` | Adds `SupermuxKit`, `Packages/Shared/SupermuxMobileCore`, and `Packages/iOS/SupermuxMobileKit` to the SPM package-test allowlist so their tests gate CI |
| 14 | `web/data/cmux.schema.json` | `unfenced` | Adds all five supermux ids — `supermuxToggleRun`, `supermuxWorkspaceSwitcherNext`, `supermuxWorkspaceSwitcherPrevious`, `supermuxCommit`, and `supermuxCommitAccelerator` — to the shortcut-action enum so cmux.json validation accepts rebinding them; also rewrites the `workspaceInheritWorkingDirectory` description for the #80 fork behavior (off = always home directory) and gives it a `descriptionKey` (`schemaDescriptions.app.workspaceInheritWorkingDirectory`, messages under #86/#87) so the docs page localizes it |
| 15 | `web/data/cmux-shortcuts.ts` | `run-toggle-shortcut-doc` | Documents the `supermuxToggleRun` ⌘G shortcut in the keyboard-shortcut registry |
| 16 | `Sources/WorkspaceContentView.swift` | `presets-bar` | Renders `SupermuxPresetsBarMount(workspace:)` above the splits (normal mode only) inside a single `VStack` wrapper that keeps upstream's dynamic `ignoresSafeArea` edges — one structural identity, so minimal-mode toggles never rebuild the workspace subtree |
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + byte-identical `AppIcon-Debug.icon` + `AppIcon-Nightly.icon` (no DEV/NIGHTLY bands — all three channels share one mark); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered icon. Wiring lives in touchpoint #3. |
| 18 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) at the end of the Automation section, and stores the `secretStore` + `errorLog` the card needs. The card itself is a new supermux-owned file, `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). **Upstream relocated this package under `Packages/macOS/`; the new card moved with it (git rename detection placed it at the new path).** |
| 20 | `Sources/GhosttyTerminalView.swift` | `browser-link-new-tab` | When a cmd-clicked terminal link opens in the embedded browser and there is no existing browser pane to reuse, open it as a new browser tab in the current pane (and switch to it) instead of creating a horizontal split |
| 21 | `Sources/App/ShortcutRoutingSupport.swift` | `run-toggle-shortcut-dispatch` | ⌘G (the supermux Run/Stop toggle, shared with Find Next) is never ceded to a focused browser's native find, so cmux always owns the chord (otherwise WebKit swallows ⌘G and it is a dead key in the browser) |
| 22 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `run-toggle-shortcut-dispatch` | Updates the browser-find routing contract for ⌘G (run-toggle chord excluded from browser-first routing) and adds the regression test |
| 23 | `Sources/KeyboardShortcutSettings.swift` | `workspace-switcher-shortcut-case`, `workspace-switcher-shortcut-label`, `workspace-switcher-shortcut-default` | Adds the two workspace-switcher shortcut actions: `supermuxWorkspaceSwitcherNext` (default ⌘\`) and `supermuxWorkspaceSwitcherPrevious` (default ⇧⌘\`) |
| 24 | `Sources/AppDelegate.swift` | `workspace-switcher-monitor` | One hook in the app-local NSEvent monitor routes every event to `SupermuxComposition.workspaceSwitcher.handleMonitorEvent(_:appDelegate:)`: idle it acts only on the open chord; while presented it owns keyDown/keyUp/flagsChanged so it can cycle and commit on ⌘ release |
| 25 | `web/data/cmux-shortcuts.ts` | `workspace-switcher-shortcut-doc` | Documents the two workspace-switcher shortcuts in the keyboard-shortcut registry (in the Workspaces section, after `prevSidebarTab`) |
| 26 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` | `right-sidebar-min-width` | Lowers the right-sidebar minimum width floor from upstream's 276 to 200 so the panel can be dragged narrower (mode bar collapses to icon-only via touchpoint #5). **Upstream relocated this package under `Packages/macOS/` (cmux package reorg).** |
| 27 | `cmuxTests/SidebarWidthPolicyTests.swift` | `right-sidebar-min-width-test` | Two right-sidebar clamp assertions read `RightSidebarWidthSettings.minimumWidth` instead of the hardcoded `276`, so they track the lowered floor |
| 28 | `Sources/KeyboardShortcutSettings.swift` | `toggle-split-zoom-rebind` | Rebinds the `toggleSplitZoom` default from ⇧⌘↩ to ⌃⌘Z (canonical table) so ⇧⌘↩ is free for the supermux Changes-panel commit accelerator |
| 29 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `toggle-split-zoom-rebind` | Mirror of the rebound ⌃⌘Z default for the settings-UI package. **Upstream relocated this package under `Packages/macOS/`.** |
| 30 | `web/data/cmux-shortcuts.ts` | `toggle-split-zoom-rebind` | Documents Toggle Pane Zoom as ⌃⌘Z in the keyboard-shortcut registry |
| 31 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `toggle-split-zoom-rebind` | The split-zoom shortcut test drives the configured default, so it presses ⌃⌘Z (was ⇧⌘↩) |
| 32 | `cmuxTests/KeyboardShortcutContextTests.swift` | `toggle-split-zoom-rebind` | Comment accuracy: toggleSplitZoom is no longer the Return-based shortcut (now ⌃⌘Z); assertions unchanged |
| 33 | `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | `toggle-split-zoom-rebind` | Two browser zoom round-trip UI tests press ⌃⌘Z instead of ⇧⌘↩ |
| 34 | `Sources/GhosttyTerminalView.swift` | `ghostty-unbind-split-zoom-return` | Unbinds Ghostty's built-ins `super+shift+enter = toggle_split_zoom` **and** `super+enter = toggle_fullscreen` so the freed ⇧⌘↩ / ⌘↩ actually reach the Changes-panel commit shortcuts in a focused terminal (without them the rebind is incomplete — same class as the numbered-tab unbinds, #5189) |
| 35 | `Sources/App/ShortcutRoutingSupport.swift` | `toggle-split-zoom-rebind` | Comment accuracy: the browser-Return rule no longer cites Toggle Pane Zoom as the Command-Return app shortcut (now ⌃⌘Z); notes ⇧⌘↩ is the commit accelerator. Logic unchanged |
| 36 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Regression test `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback` asserts the loaded Ghostty config has no `super+shift+enter` binding (companion to the #5189 numbered-fallback test) |
| 37 | `Sources/KeyboardShortcutSettings.swift` | `supermux-commit-shortcut-case`, `supermux-commit-shortcut-label`, `supermux-commit-shortcut-default` | Registers the Changes-panel `supermuxCommit` (⌘↩) and `supermuxCommitAccelerator` (⇧⌘↩) actions (case/label/default) so both are editable in Settings, live in `cmux.json`, and participate in conflict detection; applied by the panel's SwiftUI buttons (read via `SupermuxChangesMount`), not the app monitor. Settings visibility/conflict detection is actually delivered by the settings-package enum registration (#62/#63) |
| 38 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `supermux-commit-shortcut` | `testSupermuxCommitDefaultsBindReturnChords` asserts the two commit actions default to ⌘↩ / ⇧⌘↩ and do not cross-match |
| 39 | `Sources/FileExplorerView.swift` | `file-explorer-operations`, `file-explorer-operations-empty`, `file-explorer-operations-reveal` | Adds file-management to the right-sidebar file tree (local provider only): context-menu items New File/New Folder/Rename/Duplicate/Move to Trash on a clicked node, New File/New Folder on the empty area (root); the `-reveal` fence scrolls a just-created/renamed item into view after the reload. Keyboard handling (`file-explorer-operations-keys`) moved to #46 when upstream extracted the outline-view subclass into its own file (cmux #6001). All logic lives in supermux-owned files (`Sources/Supermux/SupermuxFileExplorerCommands.swift`, `SupermuxFileExplorerPrompt.swift`) and `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileSystemOperations.swift`; the fences are one-line calls into a `FileExplorerPanelView.Coordinator` extension |
| 40 | `Sources/FileExplorerStore.swift` | `file-explorer-operations-reveal` | Adds `supermuxRevealPath` + `supermuxReveal(path:)` to `FileExplorerStore` so a supermux file operation can select a just-created/renamed item by path (the selection state is `private(set)`, so this must live in the store's own file). The store fence also carries `var supermuxRevealRequestedAt: Date?` (set in `supermuxReveal`, cleared in `supermuxClearSelection`) used by the coordinator to expire a reveal after 10s, and two minimal same-id fences in `select(node:)` and `select(nodes:anchor:)` clear `supermuxRevealPath` when the selection moves to a different path. Paired with the coordinator's `-reveal` hook in touchpoint #39 |
| 41 | `Sources/TabManager.swift` | `new-workspace-standalone` | Marks every workspace created through cmux's normal new-workspace flow (`+` / ⌘T / surface tab bar) as standalone (`SupermuxWorkspaceAssociationStore.markStandalone` in `addWorkspace`) so it lands at the root of the flat list, never nested under the focused project. The project opener clears it via `associate`; the central close path clears it via `forget`. `restoreClosedWorkspace` (reopen) goes through `addWorkspace` too, so it explicitly `forget`s the mark afterwards to re-nest by directory; **session**-restore builds `Workspace` objects directly (no `addWorkspace`) and is unaffected. `releaseRestoredAwayWorkspace` `forget`s each released pre-restore workspace after the session-restore swap (it never reaches the central close path; the restored replacement re-nests by directory) |
| 42 | `Sources/TabManager+DetachedWorkspace.swift` | `new-workspace-standalone` | The detached-surface path (move-tab / move-surface to a new workspace) builds a `Workspace` directly, not via `addWorkspace`, so it marks the new workspace standalone too — a moved-out surface becomes a root-level workspace, never nested under a project whose directory it inherited |
| 43 | `Sources/TabManager.swift` | `keep-window-on-last-close` | Keeps the window open as an empty home when the last workspace closes — instead of `window.performClose`, which quit the app on the last window. `closeWorkspace(allowEmptyingWindow:)` removes the final workspace (selection clears to `nil`); the three last-workspace close sites + the bulk-close short-circuit/plan + the child-exit path route through it, failed closed-workspace restore cleanup can empty the window again, and close confirmations no longer mark last-workspace closes as window-closing. Also fenced: `detachWorkspace` leaves the source window empty (`selectedTabId = nil`) when its last workspace moves to another window instead of upstream's `addWorkspace()` refill; `restoreSessionSnapshot` restores a zero-workspace snapshot as an empty home (fallback fabrication gated on `!snapshot.workspaces.isEmpty`); and a fenced comment marks `markRemoteTmuxKillOnWindowCloseIfNeeded` as intentionally orphaned (kept verbatim for merge cleanliness). Explicit window close (red button / ⌘⇧W) is unchanged |
| 44 | `Sources/ContentView.swift` | `empty-home` | `terminalContent` renders `SupermuxEmptyHomeView` (centered "No open tabs" hint) when `tabManager.tabs` is empty, gated to the `.tabs` sidebar surface and non-interactive. New file `Sources/Supermux/SupermuxEmptyHomeView.swift` wired via touchpoint #3 (IDs `…F5`/`…F6`); `supermux.emptyHome.*` keys under #4b |
| 45 | `cmuxTests/TabManagerUnitTests.swift` | `keep-window-on-last-close` | Repurposes the child-exit window-close test to assert the window stays open (empty home), adds two tests for `closeWorkspace(allowEmptyingWindow:)` emptying the window vs. a plain close keeping the last workspace, and covers failed closed-workspace restore cleanup from empty home; plus `testDetachingLastWorkspaceLeavesEmptyHome` and `testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty` |
| 46 | `Sources/FileExplorerNSOutlineView.swift` | `file-explorer-operations-keys` | ⌘⌫ (Move to Trash) / Return (Rename) keyboard handling in the outline view's `keyDown`, placed **before** upstream's `handleOpenSelectionShortcut` so Return renames (Finder-standard) and ⌘⌫ trashes; ⌘↓ still opens via upstream's Finder alias. Return/⌘⌫ are never claimed during an active `/` quick-search (Return keeps upstream's end-search+open semantics), and `handleSupermuxFileOperationKey` yields to a user-**explicitly**-configured Open Selection binding (Settings override or cmux.json) matching the keystroke, while the built-in Return default remains shadowed. Upstream (cmux #6001) extracted `FileExplorerNSOutlineView` out of `FileExplorerView.swift` into this file, so the `-keys` fence (originally part of #39) moved here. One-line call into the `FileExplorerPanelView.Coordinator` extension |
| 47 | `CLI/CMUXCLI+ThemeSupport.swift` | `right-sidebar-changes-mode-cli-set`, `right-sidebar-changes-mode-cli-normalize` | Adds `"changes"` to `isRightSidebarCLIMode` and `normalizedRightSidebarCLIArgument` so `cmux right-sidebar set changes` / `cmux right-sidebar changes` validate and normalize. Upstream (cmux CLI refactor) moved these two helpers out of `CLI/cmux.swift` into this file, so the `-cli-set` fence (originally part of #10) moved here; `-cli-normalize` is new (the normalizer did not exist at the previous merge base) |
| 48 | `Sources/RightSidebarChromeStyle.swift` | `right-sidebar-compact-mode-bar` | Adds a `showsLabel` flag to upstream's `ModeBarButton` (icon-only when the sidebar is narrow). Upstream relocated `ModeBarButton` here from `RightSidebarPanelView.swift` and switched it to an `item:`-based API; the compact-mode-bar fence (part of #5) moved with it. `RightSidebarPanelView.modeButtonsRow` now drives the `modeBarItems`/`ModeBarButton(item:showsLabel:)` API inside `ViewThatFits` |
| 49 | `Sources/Sidebar/SidebarWorkspaceSnapshotRefreshPolicy.swift` | `sidebar-flatrow-activity` | Carries `supermuxActivity` through the frozen-snapshot `applyingContextMenuImmediateFields` rebuild (the third construction site of `SidebarWorkspaceSnapshotBuilder.Snapshot`, alongside the two in `ContentView.swift`). Previously an unfenced edit; fenced and registered during the upstream merge that added `finderDirectoryPath`/`mediaActivity` to the same initializer |
| 50 | `Sources/ContentView.swift` | `sidebar-hide-scrollbar` | Hides the left workspace sidebar's scrollbar. Two layers: (a) `VerticalTabsSidebar.configureSidebarScrollView` (the shared resolver hook for both the default projects+workspaces list and the extension-provider list) no longer calls upstream's `applySidebarOverlayScrollerConfiguration()`; it instead forces `hasHorizontalScroller`/`hasVerticalScroller` to `false` (write-only-when-differs). (b) Both sidebar `ScrollView`s get `.scrollIndicators(.hidden)` so SwiftUI itself keeps the indicator hidden — the AppKit resolver alone loses to SwiftUI, which re-asserts the scroller from its default `.scrollIndicators(.automatic)` after the resolver's deferred apply. Scrolling still works via trackpad/wheel |
| 51 | `scripts/reload.sh` | `reload-prune-leftover-base-app` | After a tagged build renames the raw `cmux DEV.app` into `cmux DEV <tag>.app`, calls the supermux-owned `scripts/supermux-prune-dev-builds.sh --reload-leftover` to deregister + delete the never-launched leftover base bundle, so macOS stops accumulating one stale "cmux DEV" row per tag in System Settings > Login Items & Extensions. The prune script is supermux-owned (no touchpoint); only this one-line call into it is fenced |
| 52 | `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift` | `force-production-auth` | Lets the DEBUG iOS build opt into the PRODUCTION Stack project + cmux.dev callback when the bundled `LocalConfig.plist` sets `STACK_ENVIRONMENT=production`, so a personally-signed DEBUG phone build pairs with the installed production Supermux Mac. Without the key, behavior is unchanged (DEBUG → development) |
| 53 | `ios/Config/cmux.entitlements` | `unfenced` | Strips `com.apple.developer.applesignin`, `aps-environment`, and `com.apple.developer.usernotifications.time-sensitive` so automatic signing can provision a personal Apple team that lacks those capabilities (comments are unsafe to fence around a plist-key removal) |
| 54 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires `LocalConfig.plist` into the iOS app's Copy Bundle Resources phase (build file `FCAB1004…`, file ref `FCAB101B…`) so the app can read it from the bundle |
| 55 | `ios/cmux/Resources/LocalConfig.plist` | `unfenced` | New supermux-owned resource read by touchpoint #52; sets `STACK_ENVIRONMENT=production`. Not an upstream modification — registered so the check guards its existence (the pbxproj entry in #54 references it) |
| 56 | `Sources/Workspace.swift` | `workspace-agent-lifecycle-observation` | One fenced line at the top of `recordAgentLifecycleChange(panelId:)` — the single choke point every agent-lifecycle set/clear routes through — calls `SupermuxWorkspaceLifecycleRelay.workspaceDidChangeAgentLifecycle(self)` (relay lives in supermux-owned `Sources/Supermux/SupermuxWorkspaceActivityResolver.swift`), making lifecycle-only mutations observable: cmux's sidebar publishers carry no lifecycle field, so without it the supermux activity indicators went stale on socket `set_agent_lifecycle`, hibernation clears, and feed-attention conclusion. Placed before the `AgentHibernationController` call, whose tracking gate drops events when disabled |
| 57 | `Sources/Workspace.swift` | `keep-window-on-last-close` | Remote-tmux close-button fallback: the last workspace of the last window closes into the empty home (`closeWorkspace(self, recordHistory: false, allowEmptyingWindow: true)`) instead of falling through to a replacement local shell in the dead mirror; the multi-window discard branch stays upstream |
| 58 | `Sources/AppDelegate.swift` | `new-workspace-standalone` | `unregisterMainWindow` prunes the association store against the union of every remaining window's workspace ids on whole-window teardown (which skips the per-workspace close path); durable directory links live in the projects model and survive, so a revived closed window re-nests by directory |
| 59 | `Sources/TerminalController.swift` | `keep-window-on-last-close` | The socket `close_workspace` command routes through `closeWorkspace(tab, allowEmptyingWindow: true)` and replies OK only when the workspace actually left `tabs` (upstream `closeTab` silently no-ops on a window's last workspace while replying OK) |
| 60 | `Sources/RemoteTmuxController.swift` | `keep-window-on-last-close` | The dead-mirror `.closeWorkspace` action drops upstream's add-a-replacement-workspace workaround and closes with `allowEmptyingWindow: true`, leaving the empty home (net −4 lines vs upstream) |
| 61 | `Sources/AppleScriptSupport.swift` | `keep-window-on-last-close` | AppleScript `close tab` (`ScriptTab.handleCloseTab`) and terminal `close` last-panel path (`ScriptTerminal.handleClose`) call `closeWorkspace(workspace, allowEmptyingWindow: true)` instead of the `tabs.count > 1` fork + `window.performClose(nil)`, so scripted last-workspace closes leave the empty home like ⌘W |
| 62 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift` | `run-toggle-shortcut-case`, `workspace-switcher-shortcut-case`, `supermux-commit-shortcut-case`, `supermux-shortcut-groups`, `supermux-shortcut-display-names` | Registers the five supermux actions (`supermuxToggleRun`, the two workspace-switcher actions, the two commit actions) in the settings-package enum that drives the Settings UI and its conflict detection (reuses the app-target fence ids for the case additions) |
| 63 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `supermux-shortcut-defaults` | Package mirror of the five supermux default strokes (⌘G, ⌘\`, ⇧⌘\`, ⌘↩, ⇧⌘↩) from `Sources/KeyboardShortcutSettings.swift`; both tables must agree |
| 64 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Stores/SecretFileStore.swift` | `secret-file-0600-write` | Temp-file-at-0600 + `rename(2)` write path removing the chmod-after-write exposure window for the AI gateway key |
| 65 | `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/SecretFileStoreTests.swift` | `secret-file-0600-write` | Regression test for the 0600 write path (same fence id as #64) |
| 66 | `cmuxTests/KeyboardShortcutContextTests.swift` | `settings-package-shortcut-action-drift` | Drift test that fails on app-target shortcut actions unmapped in the settings-package enum, plus an alignment test for the five supermux actions |
| 67 | `web/data/cmux-shortcuts.ts` | `supermux-commit-shortcut-doc` | Documents the two Changes-panel commit chords (⌘↩ / ⇧⌘↩) in the diff-viewer section of the keyboard-shortcut registry |
| 68 | `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/SupermuxShortcutActionTests.swift` | `unfenced` | Whole-file supermux-owned test inside the upstream `CmuxSettings` package test target (SupermuxAISettingsCard precedent, #18); registered so the check guards its existence |
| 69 | `Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/SupermuxAISettingsCardContractTests.swift` | `unfenced` | Whole-file supermux-owned contract test inside the upstream `CmuxSettingsUI` package test target (SupermuxAISettingsCard precedent, #18) |
| 70 | `Sources/TerminalController+ControlWorkspaceContext.swift` | `keep-window-on-last-close` | The control-socket `workspace.close` resolver (`controlCloseWorkspace`) routes through `closeWorkspace(ws, allowEmptyingWindow: true)` and returns `.resolved` only when the workspace actually left `tabs` (plain close silently no-ops on a window's last workspace while still replying `.resolved`) |
| 71 | `Sources/TerminalController+MobileWorkspaceList.swift` | `keep-window-on-last-close` | The mobile `v2MobileWorkspaceClose` API drops upstream's `tabs.count > 1` last-workspace rejection, closes via `closeWorkspace(workspace, allowEmptyingWindow: true)`, and replies ok only when the workspace actually left `tabs`; the doc comment is updated in a fence to match |
| 72 | `cmuxTests/FileExplorerStoreTests.swift` | `file-explorer-operations-reveal` | Four regression tests for pending-reveal invalidation: selecting a different path or multi-selecting away cancels a pending supermux reveal, re-selecting the reveal path keeps it, and supermuxClearSelection resets reveal state |
| 73 | `Sources/DragOverlayRoutingPolicy.swift` | `browser-hover-drag-guard` | Bug fix (re-land of fcb443d8df, dropped in the undo/re-land cycle around 544bdc1d5d): gates the browser-portal hover→drag pass-through on the left mouse button actually being held, so a stale `.drag` pasteboard (Bonsplit/sidebar tab-transfer types persist after a drag ends) can no longer misroute ordinary hover past the WKWebView. Regression test in `cmuxTests/PortalTabDragRoutingTests.swift` (#75) |
| 74 | `Sources/Panels/BrowserPanelView.swift` | `browser-hover-webkit-topmost-gate` | Bug fix: WebKit only processes hover (mouseMoved → CSS `:hover`, cursor updates, tooltips) when `window.contentView.hitTest(...)` resolves to the WKWebView or a descendant (`updateViewIsTopmostAtMouseLocation:` in WebKit's WebViewImpl.mm). cmux's browser portal hosts the web view on the theme frame — outside the contentView subtree — so that gate always failed and hover was dead in every embedded browser pane while clicks/scroll kept working. The SwiftUI-side anchor (`WebViewRepresentable.HostContainerView`) now delegates hover-time hit tests to the portal-hosted web view — but only while no tab drag is in flight (those hit tests must keep resolving to the Bonsplit/sidebar drop targets behind the portal) and only when the web view is actually topmost in its slot (find-bar/omnibar-suggestion overlays are slot siblings layered above it). Wired only in window-portal hosting mode; an inline-hosted web view already sits in the anchor's subtree. Two fences: the anchor property/test-seam/helper/`hitTest` hook, and the `updateNSView` wiring. Regression test in #75 |
| 75 | `cmuxTests/PortalTabDragRoutingTests.swift` | `browser-hover-drag-guard`, `browser-hover-webkit-topmost-gate` | Regression tests for #73 (hover with no held button must not pass through the portal; active drags still do) and #74 (the anchor delegates hover hit tests to the portal-hosted web view — including end-to-end through `hitTest` via the routing-context test seam; non-hover contexts, in-flight tab drags, occluding slot overlays, out-of-bounds points, and other-window web views are not claimed) |
| 76 | `Sources/BrowserWindowPortal.swift` | `browser-hover-drag-guard` | Injectable `pressedMouseButtons` parameter on `WindowBrowserHostView.shouldPassThroughToDragTargets` (forwards to the #73 policy; keeps the #78 tests deterministic) plus a comment at the pass-through call site noting the fork's pressed-button gate |
| 77 | `Sources/BrowserPaneDropTargetView.swift` | `browser-hover-drag-guard` | Same stale-drag-pasteboard fix one layer down: the slot's invisible pane drop target no longer captures hover-kind hit tests while no left button is held, so a stale tab-transfer/file payload can't misroute post-drag cursor updates and tooltips inside the slot (and can't defeat #74's topmost check, which hit-tests the slot) |
| 78 | `cmuxTests/BrowserPanelTests.swift` | `browser-hover-drag-guard` | Updates upstream's two hover pass-through tests to the fork contract (hover-kind pass-through requires the left button held; the sidebar-reorder test is renamed accordingly); upstream's originals asserted exactly the stale-hover behavior #73 removes and would fail deterministically on CI |
| 79 | `cmuxTests/BrowserPaneDropRoutingTests.swift` | `browser-hover-drag-guard` | Updates upstream's capture test to inject the pressed-button state and adds stale-hover regression coverage for #77 |
| 80 | `Sources/TabManager.swift` | `new-workspace-home-dir` | With "Inherit Workspace Working Directory" OFF, `implicitWorkingDirectoryForNewWorkspace` returns the home directory explicitly instead of nil. A nil cwd reaches `ghostty_surface_new` unset, and Ghostty's own `tab-inherit-working-directory` (default on) then reuses the focused surface's pwd — so the sidebar empty-area double-click and the `+` button still opened new workspaces in the focused workspace's directory despite the setting. Regression test: `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` (wired via #3) |
| 81 | `cmuxTests/WorkspaceUnitTests.swift` | `new-workspace-home-dir` | Upstream's `testDisabledInheritanceLeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback` asserted the nil-cwd contract #80 replaces; renamed to `testDisabledInheritancePinsNewWorkspaceCwdToHomeDirectory` and asserts the explicit home directory |
| 82 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AppSection.swift` | `new-workspace-home-dir` | The Inherit Working Directory toggle's OFF subtitle now says new workspaces always start in the home directory (upstream promised a Ghostty working-directory fallback that #80 removes); matching en/ja catalog values updated under #4b, schema description under #14 |
| 83 | `cmuxUITests/SettingsAppBehaviorUITests.swift` | `new-workspace-home-dir` | `Subtitle.inheritOff` now matches the fork's OFF subtitle; upstream's constant held the removed Ghostty-fallback wording, so `testInheritWorkingDirectoryToggleSwapsSubtitle` (which polls for that exact static text after clicking the toggle) failed deterministically against #82's reworded row |
| 84 | `Sources/SettingsSearchAliases.swift` | `new-workspace-home-dir` | The toggle's settings-search alias swaps the stale `ghostty` keyword for `home` (the OFF behavior no longer involves Ghostty's working-directory setting); en/ja catalog values under #4b |
| 85 | `Sources/SettingsNavigation.swift` | `new-workspace-home-dir` | Same `ghostty` → `home` keyword swap in the settings-navigation entry's search keywords |
| 86 | `web/messages/en.json` | `unfenced` | Adds `schemaDescriptions.app.workspaceInheritWorkingDirectory` so the localized docs configuration page renders the reworded #14 schema description through `descriptionKey` (the sibling mechanism 32 other schema properties use) instead of the English-only `description` fallback |
| 87 | `web/messages/ja.json` | `unfenced` | Japanese translation for the #86 message key |
| 88 | `skills/cmux-settings/references/all-keys.md` | `unfenced` | Regenerated the `app.workspaceInheritWorkingDirectory` description row to match the #14 schema description (the file is auto-generated from `web/data/cmux.schema.json` and had the removed Ghostty-fallback wording) |
| 89 | `ios/cmuxUITests/cmuxUITests.swift` | `uitest-ticket-compat-version` | Adds `macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion` to the mock-host attach-ticket fixture in `attachURL(port:)`, matching what every real Mac-minted ticket carries (`MobileHostService`). Without it the ticket decodes to compat 0 ("unknown compatibility"), `MobileShellComposite.versionWarning` blocks pairing behind a "Continue anyway" sheet, and every connection-dependent cmuxUITest times out. Upstream-latent bug (upstream CI runs `-skip-testing:cmuxUITests` on PRs, so it never sees it) |
| 90 | `cmux.xcworkspace/contents.xcworkspacedata` | `unfenced` | Adds the supermux-owned package FileRefs to the workspace groups: `Packages/Shared/SupermuxMobileCore` (Shared group) and `Packages/iOS/SupermuxMobileKit` (iOS group). Generated file — regenerate with `python3 scripts/check-workspace-package-groups.py --write` (the `Packages/` folder layout is the source of truth), never hand-edit |
| 91 | `Sources/TerminalController.swift` | `mobile-supermux-dispatch` | One case in the `mobileHostHandleRPC` switch routes the whole `mobile.supermux.*` namespace to `v2MobileSupermuxDispatch` (fork-owned `Sources/Supermux/TerminalController+SupermuxMobile.swift`), mirroring the adjacent `mobile.chat.*` prefix case |
| 92 | `Sources/Mobile/MobileHostService.swift` | `mobile-supermux-authz` | In `ticketAuthorizationError(authorization:request:)`, after the alias/conflict guards and before the upstream method switch, delegates every `mobile.supermux.*` method to the fail-closed `SupermuxMobileAuthorization.ticketError` table (fork-owned `Sources/Supermux/SupermuxMobileAuthorization.swift`); reachable in tests via the existing `debugTicketAuthorizationError` seam |
| 93 | `Sources/Mobile/MobileHostService+Capabilities.swift` | `mobile-supermux-capabilities` | Appends `SupermuxMobileCapabilities.advertised` (fork-owned `Sources/Supermux/SupermuxMobileCapabilities.swift`) to `mobileHostCapabilities` so the phone can gate supermux screens on `supermux.*.v1` entries |
| 94 | `Sources/AppDelegate.swift` | `mobile-supermux-observers` | One line at the top of `ensureMobileWorkspaceListObserver(for:)` calls `SupermuxMobileHostGlue.activateIfNeeded()` (fork-owned `Sources/Supermux/SupermuxMobileObservers.swift`) so fork mobile observers activate exactly where upstream constructs `MobileWorkspaceListObserver` |
| 95 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the `SupermuxMobileCore` package (local package reference + product dependency on the `cmux` and `cmuxTests` targets), the fifteen `Sources/Supermux/` mobile files (`TerminalController+SupermuxMobile.swift`, `SupermuxMobileHost+Projects.swift`, `SupermuxMobileHost+Worktrees.swift`, `SupermuxMobileHost+PresetsActions.swift`, `SupermuxMobileHost+Changes.swift`, `SupermuxMobileHost+ChangesSync.swift`, `SupermuxMobileHost+Run.swift`, `SupermuxMobileHost+Files.swift`, `SupermuxMobileAuthorization.swift`, `SupermuxMobileCapabilities.swift`, `SupermuxMobileObservers.swift`, `SupermuxMobileActivityObserver.swift`, `SupermuxMobileRunObserver.swift`, `SupermuxMobileChangesWatchRegistry.swift`, `SupermuxMobileWorkspaceListAugmenter.swift`) into the cmux target, and `cmuxTests/SupermuxMobileAuthorizationTests.swift` + `cmuxTests/SupermuxMobileObserversTests.swift` + `cmuxTests/SupermuxMobileChangesWatchRegistryTests.swift` + `cmuxTests/SupermuxMobileRunObserverTests.swift` into the cmuxTests target (all ids prefixed `50BE0002…`) |
| 96 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-client-mount` | One computed property `supermuxConnectionSeam` (next to `remoteClientForAgentChat`) exposes the live `MobileCoreRPCClient` + `supportedHostCapabilities` snapshot to the fork's supermux phone stores; `nil` unless connected. All tracked `@Observable` reads, so the fork's section driver re-runs (and rebuilds `SupermuxMacClient` + stores) on every (re)connect and on capability arrival |
| 97 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-projects-section` | Four 1-line fences: `import SupermuxMobileUI`; a `@State` `SupermuxProjectsSectionModel`; the `SupermuxProjectsMobileSection(section:actions:)` mount inside the `List` above the workspace/group section; the `.supermuxProjectsSectionDriver(model:connection:workspaces:selectWorkspace:)` session driver on the `List` (fed by the #96 seam; `workspaces` + `selectWorkspace` feed the §6 open-workspace join and nested-row navigation). Section renders nothing without `supermux.projects.v1` |
| 98 | `Packages/iOS/CmuxMobileShellUI/Package.swift` | `supermux-mobile-shellui-deps` | Two fenced 1-line additions: `.package(path: "../SupermuxMobileUI")` in `dependencies` and `"SupermuxMobileUI"` in the `CmuxMobileShellUI` target dependencies (fork-owned Projects section package) |
| 99 | `Sources/TerminalController+MobileWorkspaceList.swift` | `mobile-supermux-workspace-fields` | Two fence blocks in `mobileWorkspacePayload`: the upstream `return [` becomes `let payload: [String: Any] = [`, and after the literal a fenced `return SupermuxMobileWorkspaceListAugmenter.augment(payload, workspace: workspace)` merges the additive §6 fields (`supermux_project_id` / `supermux_activity`; fork-owned `Sources/Supermux/SupermuxMobileWorkspaceListAugmenter.swift` → package-tested `SupermuxMobileWorkspaceFields` in SupermuxKit) |
| 100 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-workspace-fields` | Two fence blocks in `Workspace`: the OPTIONAL `supermuxProjectID` / `supermuxActivity` stored lets and their snake_case `CodingKeys` (`supermux_project_id` / `supermux_activity`). Synthesized decoding, so pre-mission payloads (keys absent) decode unchanged — regression-tested by `SupermuxWorkspaceListFieldsDecodeTests` |
| 101 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-workspace-fields` | One fence block: defaulted `public var supermuxProjectID/supermuxActivity: String? = nil` following the `machineColorIndex` pattern, so upstream initializers and call sites need no change |
| 102 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-workspace-fields` | One fence block after `self.init(...)` in `init(remote:)`: copies the two decoded fields onto the preview (aggregation's `var stamped = workspace` copies then carry them everywhere) |
| 103 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-project-workspaces`, `supermux-mobile-row-activity` | Hide filter: a fenced `supermuxFlatWorkspaces` helper (delegates to the `supermuxFlatRows(hidingProjectAssociated:)` array extension, active only while the Projects section is visible AND no search/filter) plus two fenced one-line swaps where upstream read `workspaces` (`filteredWorkspaces`, `groupedListItems`). Row dot: one fenced `.supermuxWorkspaceActivityDot(rawActivity:)` modifier on `WorkspaceNavigationRow` in `workspaceRow` |
| 104 | `ios/cmux/AppCompositionRoot.swift` | `uitest-clear-paired-mac-state` | When `UITestConfig.mockDataEnabled` and the harness sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1`, deletes `Application Support/cmux/` (the `MobilePairedMacStore` sqlite + WAL/SHM) once at composition-root init, before `CMUXMobileRootScene` opens the store. Fixes cross-test pairing-state leakage on the shared simulator: since #89 made pairing actually complete, a persisted paired Mac from a prior test/run auto-navigated past `MobileAddDeviceForm` and its dead-host reconnect churn broke 3 cmuxUITests (cmuxUITests.swift:245/:586). No-op for real installs: the mock gate is DEBUG-only and the env var is only set by the XCUITest harness (#105) |
| 105 | `ios/cmuxUITests/cmuxUITests.swift` | `uitest-clear-paired-mac-launch` | `launchApp` sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1` on every harness launch so each test starts from an unpaired slate (consumed by #104) |
| 106 | `ios/cmuxUITests/cmuxUITests.swift` | `uitest-new-workspace-menu-item` | `testWorkspaceToolbarCreatesWorkspaceAndTerminal` creates the workspace via the terminal dropdown's `MobileNewWorkspaceMenuItem` instead of tapping a nav-bar `MobileTerminalNewWorkspaceButton`, because this upstream snapshot's iOS `WorkspaceDetailView` only mounts `newWorkspaceToolbarButton` in the non-iOS `#else` toolbar branch — on iOS the identifier does not exist and the tap times out deterministically (cmuxUITests.swift:245). Upstream never noticed (PR CI runs `-skip-testing:cmuxUITests`) and a newer upstream restores a nav-bar button; all behavioral assertions (host `workspace.create`, `workspace-3`/`workspace-3-terminal-1` selection, menu-item existence) are unchanged |
| 107 | `scripts/check-package-resolved-policy.py` | `fix-resolved-policy-path-deps` | Manifest diffs whose `.package(…)` changes are limited to path-based dependencies (`.package(path:)`, including brand-new path-referenced manifests) no longer demand a `Package.resolved` diff — SwiftPM never records path deps in any lockfile, so that demand was unsatisfiable (`swift package resolve` rewrites nothing). Pinned url dependency changes still require lockfile churn. Also silences the `fatal: path … exists on disk, but not in <merge-base>` stderr noise from `git show` on manifests new since the merge-base (three fence blocks: helper `lockfile_recorded_dependency_calls`, the changed-roots skip in `main`, and `file_text_at`) |
| 108 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-workspace-tools` | Two 1-line fences: `import SupermuxMobileUI`, and the `.supermuxWorkspaceTools(connection:workspaceID:workspaceName:)` modifier on the detail `body`'s outer `Group`. Mounts the fork's capability-gated Changes and Files toolbar entries (fork-owned `SupermuxMobileUI/SupermuxWorkspaceTools.swift`) which present `SupermuxChangesScreen` / `SupermuxFileBrowserScreen` as sheets; fed by the #96 `supermuxConnectionSeam`. Each entry hides without its capability (`supermux.changes.v1` / `supermux.files.v1`) |
| 109 | `scripts/lint-ios-package-conventions.sh` | `lint-ios-conventions-fork-scopes` | Adds the fork mobile packages (`Packages/Shared/SupermuxMobileCore`, `Packages/iOS/SupermuxMobile*`) to the lint's SCOPES so the iOS conventions lint (CI job `package-conventions-lint` in `.github/workflows/test-ios.yml`) mechanically enforces its per-line rules on them; deliberate constant/text namespace holders in the fork packages carry inline `lint:allow` justifications |
| 110 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-search` | One comment-only fence replacing upstream's `.searchable(text: $searchText)` on the workspace `List`: the fork removes the main list's (bottom-placed) search bar per direct user request. `searchText` stays `""` so upstream's query filtering (`trimmedQuery`, `matchesQuery`, search-flattened sections) compiles unchanged but is inert. Trade-off: no free-text workspace search on the phone; the Unread filter and grouping remain |

## How to re-apply

### 2. `Sources/ContentView.swift` — `sidebar-projects-section` + `sidebar-hide-project-workspaces`

**`sidebar-projects-section`:** in
`VerticalTabsSidebar.workspaceScrollContent(renderContext:minHeight:emptyAreaHeight:)`, the
content `VStack(spacing: 0)` starts with the projects mount, before `workspaceRows`:

```swift
VStack(spacing: 0) {
    // SUPERMUX:begin sidebar-projects-section
    SupermuxProjectsMount()
    // SUPERMUX:end sidebar-projects-section
    workspaceRows(renderContext: renderContext)
    ...
```

**`sidebar-hide-project-workspaces`:** in `VerticalTabsSidebar.body`, the `tabs` passed to
`SidebarWorkspaceRenderItem.renderItems(tabs:groupsById:)` is filtered so project-owned
workspaces don't duplicate in the flat list (they render nested under their project):

```swift
let mainListTabs = SupermuxMainListFilter.tabsForMainList(tabs, tabManager: tabManager)
let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
    tabs: mainListTabs, groupsById: workspaceGroupById)
```

If upstream restructures the sidebar, the requirements are: render `SupermuxProjectsMount()` once
at the top of the scrollable workspace list, and feed the flat-list row builder
`SupermuxMainListFilter.tabsForMainList(tabs, tabManager: tabManager)` instead of the raw `tabs`
(a no-op when no projects are registered; the `tabManager:` parameter selects the calling
window's resolution cache). The filter also threads a `projectHiddenWorkspaceIds` set through
`WorkspaceListRenderContext`: shift-click ranges, Close Tabs Below/Above, and Move Up/Down
exclude project-hidden workspaces (via a fenced `TabItemView.projectHiddenWorkspaceIds()` helper
computed only in event handlers — never in `body`), and a fenced `.onChange` strips newly
project-hidden ids from `selectedTabIds`.

**`sidebar-flatrow-activity`:** four small edits give flat-list workspace rows the same agent
activity indicator as the nested rows (amber braille spinner / red pulsing dot / green dot):
1. `import SupermuxKit` near the top imports.
2. A `let supermuxActivity: SupermuxWorkspaceActivity` field on
   `SidebarWorkspaceSnapshotBuilder.Snapshot` (it is `Equatable`-synthesized, so the row
   re-renders when activity changes).
3. In `makeWorkspaceSnapshot()`, set `supermuxActivity: SupermuxWorkspaceActivityResolver.activity(for: tab)`.
4. In the row's title `HStack`, after `Text(workspaceSnapshot.title)` (on the row's trailing
   edge, ahead of the close button), render `SupermuxAgentActivityIndicator(activity:size:)`
   when `supermuxActivity.isVisible` — so the status dot reads as a trailing indicator rather
   than a leading icon.
The indicator is reactive via the existing workspace observation (it changes with
`statusEntries`/`progress`, which the snapshot already observes). If upstream restructures the
snapshot/row, the requirement is just: derive activity per workspace and render the indicator
on the row's trailing edge.

**`sidebar-selection-faint`:** two computed properties on `SidebarWorkspaceRow` are overridden so
the flat-list selection highlight matches the nested project-workspace rows
(`SupermuxOpenWorkspaceRowView`) — a faint accent tint with normal text instead of the loud solid
selection card with inverted white text:

```swift
private var usesInvertedActiveForeground: Bool {
    // SUPERMUX:begin sidebar-selection-faint
    false
    // SUPERMUX:end sidebar-selection-faint
}

private var backgroundColor: Color {
    // SUPERMUX:begin sidebar-selection-faint
    if isActive {
        return Color.accentColor.opacity(0.16)
    }
    // SUPERMUX:end sidebar-selection-faint
    let style = sidebarWorkspaceRowBackgroundStyle( … )   // upstream body unchanged
    guard let color = style.color else { return .clear }
    return Color(nsColor: color).opacity(style.opacity)
}
```

If upstream restructures the row styling, the requirement is: the selected flat-list row fills with
`Color.accentColor.opacity(0.16)` (the same expression the nested rows use) and its text stays in
the normal primary/secondary palette (no white-on-solid inversion). The non-active multi-select /
custom-color tints and the original `usesInvertedActiveForeground == isActive` logic are otherwise
untouched. The default `activeTabIndicatorStyle` is `.leftRail`, so no active border or leading rail
is drawn by default; those paths are deliberately left as upstream.

**`sidebar-unified-row-style`:** five small edits in `TabItemView` restyle the flat-list
workspace row to the nested project-workspace design (`SupermuxOpenWorkspaceRowView`), so root
workspaces and project workspaces read as one system:
1. `titleFontWeight` returns `isActive ? .semibold : .regular` (upstream: always `.semibold`).
2. The title `Text(displayedTitle)` font size is `scaledFontSize(11.5)` (upstream: `12.5`).
3. The row's outer `VStack` uses `spacing: 2` (upstream: `4`).
4. The row chrome uses `.padding(.vertical, 4)` (upstream: `8`) and
   `RoundedRectangle(cornerRadius: 5)` for both the fill and the stroke overlay (upstream: `6`).
5. `backgroundColor`'s no-style fallback returns `Color.primary.opacity(0.06)` while
   `rowInteractionState.isPointerHovering` (upstream: unconditional `.clear`), matching the
   nested rows' hover tint without touching the multi-select / custom-color tints.
If upstream restructures the row, the requirement is: flat-list rows must visually match the
nested project-workspace rows — 11.5·scale title (semibold only when selected), compact line
stack, 5pt-radius chrome with the faint selection tint (`sidebar-selection-faint`) and a
primary-at-0.06 hover tint. All hover reads go through the already-rendered
`rowInteractionState` — no new `@State` or observation, so the Equatable typing-latency
contract is untouched.

**`sidebar-projects-empty-area`:** cmux sizes the sidebar scroll content to exactly fill the
viewport when everything fits — the empty drop/tap area below the last workspace row is a finite
remainder (`SidebarWorkspaceScrollLayout.emptyAreaHeight`), not `maxHeight: .infinity`, which is what
stops the document from overflowing and showing a phantom scroller / scrollable empty space
(https://github.com/manaflow-ai/cmux/issues/3241). That fit assumes the workspace rows are the only
content. Because `sidebar-projects-section` inserts `SupermuxProjectsMount()` above the rows in the
same scroll content, its height must be subtracted from the remainder or the document overflows the
viewport by exactly the section's height and the empty space becomes scrollable. Three small edits in
`VerticalTabsSidebar`, all under this one fence id:
1. A `@State private var supermuxProjectsSectionHeight: CGFloat = 0` field (next to
   `workspaceRowsMeasurement`).
2. In `workspaceScrollArea`, the `emptyAreaHeight` call passes
   `contentMinHeight: max(0, contentMinHeight - supermuxProjectsSectionHeight)` instead of the raw
   `contentMinHeight`.
3. In the workspace `ScrollView` modifier chain (next to the
   `SidebarWorkspaceRowsHeightPreferenceKey` handler) an
   `.onPreferenceChange(SupermuxProjectsSectionHeightPreferenceKey.self)` writes the measured height
   into that `@State` (accepts growth immediately; dedupes only shrink jitter with a 0.5pt
   tolerance, so a stale-low height never inflates the filler into sub-point overflow).

The height is published by `SupermuxProjectsMount` itself via a `GeometryReader` background writing
`SupermuxProjectsSectionHeightPreferenceKey` (both supermux-owned, so no upstream surface). If
upstream restructures the sidebar scroll sizing, the requirement is: whatever the empty/filler region
below the workspace rows is sized to, subtract the measured height of the Projects section first, so
`projects + rows + filler ≤ one viewport`.

### 3. `cmux.xcodeproj/project.pbxproj` — unfenced (comments are not safe there)

Sixteen ID-based additions, all using the reserved supermux ID prefix `50BE0001…`. To re-apply by
hand, mirror how `CmuxSocketControl` is wired and how `CmuxSidebarActionDispatch.swift` is
listed, with these exact IDs:

| ID | Section | Entry |
|----|---------|-------|
| `50BE000100000000000000A1` | XCLocalSwiftPackageReference | `relativePath = Packages/SupermuxKit` (also listed in the project's `packageReferences`) |
| `50BE000100000000000000A2` | XCSwiftPackageProductDependency | `productName = SupermuxKit` (also listed in the `cmux` target's `packageProductDependencies`) |
| `50BE000100000000000000A3` | PBXBuildFile | `SupermuxKit in Frameworks` (also listed in the `cmux` target's Frameworks phase `files`) |
| `50BE000100000000000000B1` | PBXFileReference | `SupermuxAppGlue.swift` |
| `50BE000100000000000000B2` | PBXBuildFile | `SupermuxAppGlue.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B3` | PBXGroup | group `Supermux` (path = `Supermux`, children = `…B1`, `…C3`, `…B4`, `…B8`, `…B6`), listed in the `A5001041 /* Sources */` group's `children` |
| `50BE000100000000000000B4` | PBXFileReference | `SupermuxRunSupport.swift` |
| `50BE000100000000000000B5` | PBXBuildFile | `SupermuxRunSupport.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B6` | PBXFileReference | `SupermuxWorkspaceActivityResolver.swift` (also listed in the `Supermux` group's `children`) |
| `50BE000100000000000000B7` | PBXBuildFile | `SupermuxWorkspaceActivityResolver.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B8` | PBXFileReference | `SupermuxSidebarFontScaleStore.swift` (also listed in the `Supermux` group's `children`) |
| `50BE000100000000000000B9` | PBXBuildFile | `SupermuxSidebarFontScaleStore.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000C3` | PBXFileReference | `SupermuxProjectsSectionHeightPreferenceKey.swift` (also listed in the `Supermux` group's `children`) |
| `50BE000100000000000000C4` | PBXBuildFile | `SupermuxProjectsSectionHeightPreferenceKey.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000C2` | PBXFileReference | `SupermuxSidebarBranchTests.swift` (also listed in the cmuxTests group's `children`) |
| `50BE000100000000000000C1` | PBXBuildFile | `SupermuxSidebarBranchTests.swift in Sources` (also listed in the `cmuxTests` target's Sources phase `files`) |
| `50BE000100000000000000D2` | PBXFileReference | `SupermuxNewWorkspaceHomeDirectoryTests.swift` (also listed in the cmuxTests group's `children`) |
| `50BE000100000000000000D1` | PBXBuildFile | `SupermuxNewWorkspaceHomeDirectoryTests.swift in Sources` (also listed in the `cmuxTests` target's Sources phase `files`) |

After re-applying run `python3 scripts/normalize-pbxproj.py && ./scripts/check-pbxproj.sh`.
The workspace-switcher feature (touchpoints #23–25) adds nine more `Sources/Supermux/`
files under the same reserved prefix: file references `50BE0001…00D1`–`…00D9` and build
files `50BE0001…00E1`–`…00E9` (each listed in the `Supermux` group's `children` and the
`cmux` target's Sources phase, mirroring the rows above). The path for
`SupermuxWorkspaceSwitcherController+Items.swift` MUST be quoted (`path = "…+Items.swift";`)
because `+` is not a legal bare character in the OpenStep plist xcodebuild parses; the
lenient `check-pbxproj.sh` does not catch an unquoted `+`, but the project fails to open.

The file-explorer-operations feature (touchpoint #39) adds two more `Sources/Supermux/`
files under the same reserved prefix: file references `50BE0001…00F1` (`SupermuxFileExplorerCommands.swift`)
and `…00F2` (`SupermuxFileExplorerPrompt.swift`), with build files `…00F3`/`…00F4` (each listed
in the `Supermux` group's `children` and the `cmux` target's Sources phase, mirroring the rows
above). The matching domain logic (`SupermuxFileSystemOperations.swift`) and its unit test live in
the `SupermuxKit` SPM package, so they need no pbxproj wiring.

The empty-home feature (touchpoint #44) adds one more `Sources/Supermux/` file under the
same reserved prefix: file reference `50BE0001…00F5` and build file `50BE0001…00F6` for
`SupermuxEmptyHomeView.swift` (listed in the `Supermux` group's `children` and the `cmux`
target's Sources phase, mirroring the rows above).

The sidebar main-list filter and project-opener glue add two more `Sources/Supermux/` files
under the same reserved prefix: file references `50BE0001…00A4` (`SupermuxMainListFilter.swift`)
and `50BE0001…00A6` (`SupermuxTabManagerOpener.swift`), with build files `…00A5`/`…00A7` (each
listed in the `Supermux` group's `children` and the `cmux` target's Sources phase, mirroring the
rows above).

Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `85`.

### 4. `.github/swift-file-length-budget.tsv` — unfenced

Several rows carry supermux's fenced growth over upstream. Each was raised by exactly the
number of fenced lines added to that file — never to absorb unrelated debt:

| Row | Δ | Reason |
|-----|---|--------|
| `Sources/ContentView.swift` | +9, +14, +28, +26, +19 | `sidebar-projects-section` mount (+3) and `sidebar-hide-project-workspaces` filter (+6); `sidebar-selection-faint` (+14: faint-tint `backgroundColor` + `usesInvertedActiveForeground` overrides); `sidebar-projects-empty-area` (+28: `@State` height + empty-area subtraction + `.onPreferenceChange` handler, 19311→19339). Budget also absorbed a pre-existing 2-line drift (HEAD file was 19297 vs a 19295 budget). `empty-home` (+26: `SupermuxEmptyHomeView` mount in `terminalContent`, the startup-recovery auto-add suppression, and clearing the titlebar title on empty, 16751→16777); `sidebar-hide-scrollbar` (+19: replaces the one-line `applySidebarOverlayScrollerConfiguration()` call in `configureSidebarScrollView` with the inlined hidden-scroller config and folds the now-stale upstream overlay-scroller doc comment into the fence; plus `.scrollIndicators(.hidden)` on both sidebar `ScrollView`s — workspace list and extension-provider list — so SwiftUI does not re-assert the scroller, 16236→16255); +86: `sidebar-hide-project-workspaces` render-context threading + selection pruning, `sidebar-selection-faint` user-hue tint, and the `empty-home` startup-recovery early-return (16255→16341); +38: `sidebar-hide-project-workspaces` closeOtherTabs visible-rows scoping + the context-menu visible-neighbor enablement block for Move Up/Down and Close Below/Above/Other (16341→16379); +25: `sidebar-unified-row-style` flat-row restyle to the nested project-workspace design (16380→16405) |
| `Sources/TabManager.swift` | +25, +28, +24, +6 | `new-workspace-standalone` (+25: `markStandalone` call in `addWorkspace`, the central close-path `forget` cleanup, and the `forget` clear in `restoreClosedWorkspace` so reopened project workspaces re-nest); `keep-window-on-last-close` (+28: `allowEmptyingWindow` param/guard, selection-to-`nil`, the three last-workspace close sites + bulk short-circuit/plan, the child-exit path, close-confirmation metadata cleanup, and failed closed-workspace restore cleanup, 6116→6169); `keep-window-on-last-close` (+24: `detachWorkspace` empty-source handling, zero-workspace snapshot restore, orphaned-helper comment, 6228→6252); `new-workspace-standalone` (+6: `forget` in `releaseRestoredAwayWorkspace`, 6252→6258); `new-workspace-home-dir` (+6: fenced home-directory return in `implicitWorkingDirectoryForNewWorkspace`, 6258→6264) |
| `cmuxTests/TabManagerUnitTests.swift` | +69, +21 | `keep-window-on-last-close` (repurposed `testChildExitOnLastWorkspaceKeepsWindowOpenAsEmptyHome`, updated all-workspaces confirmation copy expectations, two new empty-home close tests, and failed restore cleanup coverage, 3926→3995); +21: `testDetachingLastWorkspaceLeavesEmptyHome` + `testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty` (3995→4016) |
| `cmuxTests/WorkspaceUnitTests.swift` | +10 | `new-workspace-home-dir` (repurposed the disabled-inheritance test to assert the explicit home directory, 7366→7376) |
| `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AppSection.swift` | +2 | `new-workspace-home-dir` (fence around the rewritten OFF subtitle, 928→930) |
| `Sources/SettingsNavigation.swift` | +2 | `new-workspace-home-dir` (fence around the toggle's search-keyword swap, 606→608) |
| `Sources/WorkspaceContentView.swift` | +12, −8 | `presets-bar` mount above the splits; reshaped from the if/else branch to the single-identity `VStack` wrapper (816→820, net +4 over upstream) |
| `Sources/RightSidebarPanelView.swift` | +18, +35, +3, +71 | `right-sidebar-changes-mode-*` (case/label/symbol/shortcut/rootsync/content, +18); `right-sidebar-compact-mode-bar` (+35: `ViewThatFits` wrapper with pinned trailing controls + `modeButtonsRow(showsLabels:)` helper + `showsLabel` pill param/conditional, 743→778); `right-sidebar-changes-mode-content` (+3: `SupermuxChangesMount` now also passes `isVisible: fileExplorerState.isVisible`, 778→781); +71: third icon-only-scroll `ViewThatFits` fallback + `right-sidebar-changes-mode-focushost` mount (624→695) |
| `Sources/RightSidebarToolPanel.swift` | (within budget) | `.changes` added to 4 existing case groups |
| `Sources/MainWindowFocusController.swift` | +10, +23 | changes-mode focus routing; `right-sidebar-changes-mode-focushost` host registration + ownership checks (834→857) |
| `Sources/KeyboardShortcutSettings.swift` | +13, +18, +4, +22, +1 | `supermuxToggleRun` action (+13); `workspace-switcher-shortcut-*` (+18: case/label/default for the two switcher actions, 2586→2604); `toggle-split-zoom-rebind` (+4: fence + comment around the rebound default, 2604→2608); `supermux-commit-shortcut` (+22: case/label/default for the two commit actions, 2608→2630); +1: comment-only correction in the commit default noting both Ghostty unbinds (2665→2666) |
| `cmuxTests/KeyboardShortcutContextTests.swift` | +2, +35 | `toggle-split-zoom-rebind` (fence around the updated rationale comment, 688→690); `settings-package-shortcut-action-drift` (+35: drift + alignment tests, 690→725) |
| `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | +6 | `toggle-split-zoom-rebind` (fences around the two browser zoom round-trip tests, 1677→1683) |
| `Sources/AppDelegate.swift` | +12, +10, +10 | `run-toggle-shortcut-dispatch` (+12: dispatch + fenced auto-repeat exclusion, was +10); `workspace-switcher-monitor` (+10, 17788→17798); `new-workspace-standalone` (+10: association prune in `unregisterMainWindow`, →17874) |
| `Sources/App/ShortcutRoutingSupport.swift` | +11, +5 | `run-toggle-shortcut-dispatch` (⌘G never browser-first); `toggle-split-zoom-rebind` (+5: fenced comment correcting the stale Toggle Pane Zoom reference, 945→950) |
| `cmuxTests/AppDelegateShortcutRoutingTests.swift` | +61, +35 | `run-toggle-shortcut-dispatch` (contract update + regression tests, incl. `testRunToggleDispatchRejectsAutoRepeatKeyEvents`; fenced region 26→55 lines); `toggle-split-zoom-rebind` (fenced `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback` + second kVK_Return probe with `[.command]`; fenced region 26→35 lines, →12241) |
| `Sources/GhosttyTerminalView.swift` | +21 | `ghostty-unbind-split-zoom-return` (fenced second `loadInlineGhosttyConfig` unbinding both `super+shift+enter` and `super+enter`; fence 16→21 lines, →12270) |
| `CLI/cmux.swift` | +4 | `changes` CLI mode |
| `Sources/FileExplorerView.swift` | +14, +6 | `file-explorer-operations` (+3: end-of-menu call), `file-explorer-operations-empty` (+5: empty-area `else` block adding root New File/Folder), `file-explorer-operations-keys` (+6: ⌘⌫/Return hook in the outline `keyDown`), 2355→2369; `file-explorer-operations-reveal` (+6: scroll-into-view hook in `reloadIfNeeded`, 2369→2375) |
| `Sources/FileExplorerStore.swift` | +17, +14, +16 | `file-explorer-operations-reveal` (`supermuxRevealPath` property + `supermuxReveal(path:)` method, 1446→1463; then `supermuxClearSelection()` + the `setRootPath` reveal-flag clear, 1463→1477; then +16: `supermuxRevealRequestedAt` in the main fence (+6) and the two new selection-clear fences in `select(node:)` (+6) / `select(nodes:anchor:)` (+4), 1478→1494) |
| `cmuxTests/FileExplorerStoreTests.swift` | +55 | four supermux-reveal regression tests, fenced as `file-explorer-operations-reveal` (#72) (1204→1259) |
| `Sources/Workspace.swift` | +3, +10 | `workspace-agent-lifecycle-observation` (+3: one relay call + two fence comments in `recordAgentLifecycleChange`); `keep-window-on-last-close` (+10: remote-tmux close-button last-window fallback, 12828→12841) |
| `Sources/TerminalController.swift` | +7 | `keep-window-on-last-close` (9 fenced lines replacing the upstream `closeTab` call + unconditional OK reply in socket `close_workspace`, 13832→13839) |
| `Sources/TerminalController+ControlWorkspaceContext.swift` | +8 | `keep-window-on-last-close` (9 fenced lines replacing the plain `closeWorkspace(ws)` call in the control-socket `workspace.close` resolver with the empty-home close + removal verification, 754→762) |
| `Sources/RemoteTmuxController.swift` | −4 | `keep-window-on-last-close` (11 fenced lines replacing upstream's add-a-replacement-workspace workaround in the dead-mirror `.closeWorkspace` action, 1093→1089) |
| `Sources/AppleScriptSupport.swift` | −10 | `keep-window-on-last-close` replaces the scripted `tabs.count > 1` close forks with `closeWorkspace(allowEmptyingWindow: true)` (715→705) |
| `Sources/DragOverlayRoutingPolicy.swift` | (no tsv row — under the 500-line floor) | `browser-hover-drag-guard` (+14: injectable `pressedMouseButtons` parameter + pointerHover pressed-button guard, 385→399) |
| `Sources/Panels/BrowserPanelView.swift` | +71 | `browser-hover-webkit-topmost-gate` (anchor `portalHoverHitTestWebView` + `portalHoverRoutingContextOverride` test seam + `portalHoverDelegationTarget(at:routingContext:pressedMouseButtons:dragPasteboardTypes:)` with in-flight-drag exclusion and slot-topmost check + `hitTest` delegation hook, and the `updateNSView` wiring gated on window-portal hosting, 7986→8057) |
| `cmuxTests/PortalTabDragRoutingTests.swift` | +201 | `browser-hover-drag-guard` + `browser-hover-webkit-topmost-gate` regression tests (594→795) |
| `Sources/BrowserWindowPortal.swift` | +13 | `browser-hover-drag-guard` (injectable `pressedMouseButtons` on `shouldPassThroughToDragTargets` + pass-through call-site comment, 4187→4200) |
| `cmuxTests/BrowserPanelTests.swift` | +23 | `browser-hover-drag-guard` (hover pass-through tests updated to the fork contract, 4367→4390; still under the pre-existing 4401 budget) |
| `Sources/BrowserPaneDropTargetView.swift` | (no tsv row — under the 500-line floor) | `browser-hover-drag-guard` (+15: injectable `pressedMouseButtons` parameter + pointerHover pressed-button guard in `shouldCaptureHitTesting`, 414→429) |
| `cmuxTests/BrowserPaneDropRoutingTests.swift` | (no tsv row — under the 500-line floor) | `browser-hover-drag-guard` (+50: capture test updated + stale-hover regression test, 428→478) |

After a merge, re-run and re-bump only by the measured fenced delta:

```bash
python3 scripts/swift_file_length_budget.py --budget .github/swift-file-length-budget.tsv
```

### 4b. `Resources/Localizable.xcstrings` — additive supermux keys

All `supermux.*` keys (en + ja) live here because cmux packages resolve `String(localized:)`
against the app bundle. The merge is **additive only** — `scripts/supermux-merge-loc.py`
rewrites only `supermux.*` entries and leaves every other key byte-identical. On an upstream
merge conflict here, union both sides (supermux keys never collide with cmux keys) or simply
re-run the regen pipeline (see "Localization" in SUPERMUX.md). Verify no non-supermux key
changed: `git diff <base> -- Resources/Localizable.xcstrings | grep '^[-+]' | grep -v supermux`.

### 5–9. The `changes` right-sidebar mode (one feature, five files)

The pattern is mechanical: `RightSidebarMode` gained a `case changes`. Every exhaustive
`switch` over the enum needs the new case. If a merge clobbers one of these fences, the
compiler lists every unhandled switch — re-add `.changes` at each:
- behave like `.files` for **availability** (always available),
- behave like `.feed`/`.dock` (no-op / nil / break) for **tool-panel sync, focus intent, and
  pane-mode** switches,
- label "Changes" (`supermux.rightSidebar.mode.changes`), symbol `plusminus.circle`,
  `shortcutAction: nil`, CLI argument `"changes"`, palette id `palette.showRightSidebarChanges`,
- content view: `SupermuxChangesMount(workspaceDirectory: tabManager.selectedWorkspace?.currentDirectory)`.
Find every site with: `grep -rn "case .dock" Sources/ | grep -v changes`.

### 16. `Sources/WorkspaceContentView.swift` — `presets-bar`

`WorkspaceContentView.body` returns the workspace's content (upstream's
canvas-vs-bonsplit `Group`). The fence wraps that return so the presets bar
renders once per workspace, above the splits, in normal mode only:

```swift
// SUPERMUX:begin presets-bar
let workspaceContent = Group { … }   // upstream's canvas-vs-bonsplit content
VStack(spacing: 0) {
    if !isMinimalMode {
        SupermuxPresetsBarMount(workspace: workspace)
    }
    workspaceContent
}
.ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
// SUPERMUX:end presets-bar
```

This preserves upstream's dynamic-edges single structural identity
(`bonsplitView.ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])`):
only the bar appears/disappears on a minimal-mode toggle, so the workspace
subtree is never rebuilt. If upstream restructures this view, the requirement
is: render `SupermuxPresetsBarMount` once above the split container for
normal-mode workspaces, keep one structural identity across minimal-mode
toggles, and leave minimal mode's top-safe-area-ignoring layout untouched.

### 17. App icon — Icon Composer `.icon` files (unfenced)

The supermux brand is shipped as Icon Composer "Liquid Glass" `.icon` files (Xcode 26),
not PNG appiconsets. The upstream PNG appiconsets were **deleted** and replaced by three
top-level `.icon` folders. These are tool-managed/binary, so they can't be fenced; an
upstream merge that re-introduces `AppIcon*.appiconset` or rewrites the icon must be
re-done.

Files:
- `AppIcon.icon/` — Release. `icon.json` = one `glass:false` layer `supermux.jpg` (the
  orange/black mark with the white lightning-S, exported from Icon Composer). The image is
  opaque and scaled `1.85` so it fills the canvas and the system squircle crops it — which is
  why the `automatic-gradient` fill declared behind it never shows. This is the source of
  truth from Icon Composer.
- `AppIcon-Debug.icon/` and `AppIcon-Nightly.icon/` — byte-identical copies of the Release
  bundle. As of the 2026 rebrand there are **no DEV/NIGHTLY bands** (the new orange
  background would have swallowed the old `#FF6B00` DEV band), so all three channels render
  the same mark and a Debug/tagged build is no longer visually distinct from Release in the
  Dock. Re-introduce per-channel badges in the Debug/Nightly bundles if that distinction is
  wanted again.
- `Assets.xcassets/AppIcon{Light,Dark}.imageset/` — 1024 PNGs used by the dock-tile plugin
  (`Sources/AppIconDockTilePlugin.swift`, which overrides the *running* dock icon) and the
  Settings icon picker. Re-sourced from the actual rendered icon via
  `NSWorkspace.icon(forFile:)` — point it at the built app, or at a throwaway `.app` that
  wraps the `actool`-compiled `Assets.car` (`xcrun actool AppIcon.icon --compile … --app-icon
  AppIcon --platform macosx`) when you only need the render and not a full app build, so the
  Dock matches Finder. Light and dark are identical (the mark has no separate appearance
  variants).

Wiring (touchpoint #3, `cmux.xcodeproj/project.pbxproj`): each `.icon` needs a
`PBXFileReference` with `lastKnownFileType = folder.iconcomposer.icon`, a `PBXBuildFile`,
and membership in the **app target's `PBXResourcesBuildPhase`** — otherwise actool ignores
it. `ASSETCATALOG_COMPILER_APPICON_NAME` selects the name only: `AppIcon` (Release),
`AppIcon-Debug` (Debug), and `AppIcon-Nightly` via the CI env override in
`.github/workflows/{nightly,ci}.yml`. A same-named `.appiconset` must NOT coexist (actool
errors on the duplicate), which is why the appiconsets were removed. actool auto-generates
the legacy `.icns`/Assets.car fallbacks from the `.icon` for the 14.0 deployment target.

iOS (`ios/cmux/Assets.xcassets/AppIcon.appiconset/`) is intentionally left to the iOS
target and not rebranded here.

### 1. `CLAUDE.md` — `claude-md-pointer`

Append at end of file:

```markdown
<!-- SUPERMUX:begin claude-md-pointer -->
## Supermux fork

This checkout is **supermux**, a fork of cmux. Before making any change, read `SUPERMUX.md`
(fork rules, feature scope, upstream-merge playbook) and `SUPERMUX-TOUCHPOINTS.md` (registry of
modified upstream files). Supermux code lives in `Packages/SupermuxKit/` and `Sources/Supermux/`;
keep edits to upstream files inside `SUPERMUX:begin/end` fences and registered in the manifest.
<!-- SUPERMUX:end claude-md-pointer -->
```

### 18. `Sources/CmuxSettingsUI/.../AutomationSection.swift` — `ai-settings`

The settings section stack (`SettingsWindowScene.sectionStack`) is a closed,
hard-coded list inside the upstream `CmuxSettingsUI` package with no app-side
injection seam, and that package cannot import `SupermuxKit` (a reverse
dependency). So the AI settings UI is a **new, self-contained file** in the same
package —
`Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift`
— that depends only on `CmuxSettings`/SwiftUI. It shares one contract with
`SupermuxKit.SupermuxAIConfig`: the secret file name (`supermux-ai-gateway-key`)
and the model-override UserDefaults key (`supermux.ai.model`), duplicated as
literals in both places.

Three small fenced edits in `AutomationSection.swift` mount it:

```swift
// in the struct's stored properties:
// SUPERMUX:begin ai-settings
private let supermuxSecretStore: SecretFileStore
private let supermuxErrorLog: SettingsErrorLog
// SUPERMUX:end ai-settings

// at the end of init(...):
// SUPERMUX:begin ai-settings
self.supermuxSecretStore = secretStore
self.supermuxErrorLog = errorLog
// SUPERMUX:end ai-settings

// at the end of the body's `Group { ... }`, after portCard:
// SUPERMUX:begin ai-settings
SupermuxAISettingsCard(secretStore: supermuxSecretStore, errorLog: supermuxErrorLog)
// SUPERMUX:end ai-settings
```

`AutomationSection.init` already receives `secretStore` and `errorLog`; the only
additions are storing them and rendering the card. If upstream restructures the
section, the requirement is: surface a `SecureField`-backed card writing the
`supermux-ai-gateway-key` secret somewhere in Settings. The app composition root
(`SupermuxComposition` in `Sources/Supermux/SupermuxAppGlue.swift`) reads the
same secret file (via `SecretFileStore` rooted at `CmuxStateDirectory`) to power
the AI features — no fence there (it is a supermux-owned file).

### 20. `Sources/GhosttyTerminalView.swift` — `browser-link-new-tab`

`GhosttyTerminalView.openEmbeddedBrowserLink(url:sourceWorkspaceId:sourcePanelId:host:)`
chooses where a cmd-clicked terminal link opens in the embedded browser. Upstream
reuses an existing right-side browser pane when one exists, and otherwise creates a
new horizontal **split** (`newBrowserSplit`). The fence replaces only that split
fallback so the link instead opens as a **new browser tab in the current pane and
switches to it** (`newBrowserSurface(inPane:url:focus:true)`), keeping a split only
when the source pane can't be resolved. The reuse-an-existing-browser-pane branch is
left untouched.

The whole `else { … }` body is fenced; the upstream `if let targetPane = …` reuse
branch and the surrounding `let openedInBrowser: Bool` / external-fallback code are
unchanged:

```swift
} else {
    // SUPERMUX:begin browser-link-new-tab
    if let sourcePane = workspace.paneId(forPanelId: sourcePanelId) {
        openedInBrowser = workspace.newBrowserSurface(inPane: sourcePane, url: url, focus: true) != nil
    } else {
        openedInBrowser = workspace.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, url: url) != nil
    }
    // SUPERMUX:end browser-link-new-tab
}
```

If upstream restructures this method, the requirement is: when no existing browser
pane is reused, open the link via `newBrowserSurface(inPane:url:focus:true)` on the
source link's pane (`workspace.paneId(forPanelId: sourcePanelId)`) rather than
`newBrowserSplit(...)`. Budget row for `Sources/GhosttyTerminalView.swift` carries
+12 for this fence.

### 21–22. `Sources/App/ShortcutRoutingSupport.swift` + tests — `run-toggle-shortcut-dispatch`

Supermux shares ⌘G between Find Next (while a find overlay is open) and the Run/Stop
toggle (otherwise) — see touchpoints #11/#12. Upstream's browser-find pre-routing
(`shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst`) assumed ⌘G is purely
Find Next, so with a browser surface focused and no find bar open it ceded the chord to
the focused web view's native find. WebKit has no ⌘G action, so it silently swallowed
the chord and neither Find Next nor the run toggle fired — ⌘G was a dead key in the
browser. This is the single shared predicate that both the window pre-routing
(`AppDelegate.cmux_performKeyEquivalent`) and `shouldLetFocusedBrowserOwnFindShortcut`
consult, so fixing it here repairs every routing layer at once.

**`Sources/App/ShortcutRoutingSupport.swift`:** inside
`shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst`, right after
`guard let shortcut = browserFindCommandEquivalent(for: event)`:

```swift
// SUPERMUX:begin run-toggle-shortcut-dispatch
// ⌘G (Find Next's default) doubles as the supermux Run/Stop toggle, so cmux
// owns the chord whether or not a find overlay is open. Never cede it to a
// focused browser's native find: WebKit has no ⌘G action and silently
// swallows it, which left the chord dead while the browser was focused.
if case .findNext = shortcut,
   KeyboardShortcutSettings.shortcut(for: .supermuxToggleRun).matches(event: event) {
    return false
}
// SUPERMUX:end run-toggle-shortcut-dispatch
```

Gating on `.findNext` *and* the configured `supermuxToggleRun` chord keeps this a no-op
when the user rebinds either action off ⌘G (Find Next then routes browser-first as
upstream; an unbound action's `matches` is always false). If upstream restructures this
helper, the requirement is: the ⌘G run-toggle chord must never route browser-first.

**`cmuxTests/AppDelegateShortcutRoutingTests.swift`:** the upstream contract test
`testBrowserFirstFindShortcutRoutingRecognizesBrowserLocalFindCommandFamily` drops its
`cmd-g` case (now supermux-owned), `testBrowserFirstFindShortcutRoutingFallsBackToKeyCodeForNonLatinInput`
repoints to ⌘⌥G (Find Previous, still browser-first) to keep keyCode-fallback coverage,
and a new fenced `testBrowserFirstFindShortcutRoutingExcludesSupermuxRunToggleChord`
asserts ⌘G (both Latin and keyCode-fallback forms) is not routed browser-first.

### 23–25. Workspace switcher (shortcut actions + event hook + docs)

The Cmd+`-held, app-switcher-style **workspace switcher**. All behavior lives in
supermux-owned files (`Packages/SupermuxKit/Sources/SupermuxKit/SupermuxWorkspaceSwitcher*.swift`
for the pure ordering/model, and `Sources/Supermux/SupermuxWorkspaceSwitcher*.swift` for the
controller/overlay/preview); these three upstream hooks just register and route the chord.

**23. `Sources/KeyboardShortcutSettings.swift` — three fences.** Two new `Action` cases with a
label and a default chord each, mirroring `supermuxToggleRun`:

```swift
// in the Action enum, after the run-toggle case fence:
// SUPERMUX:begin workspace-switcher-shortcut-case
case supermuxWorkspaceSwitcherNext
case supermuxWorkspaceSwitcherPrevious
// SUPERMUX:end workspace-switcher-shortcut-case

// in `var label`, after the run-toggle label fence:
// SUPERMUX:begin workspace-switcher-shortcut-label
case .supermuxWorkspaceSwitcherNext: return String(localized: "supermux.shortcut.workspaceSwitcherNext.label", defaultValue: "Workspace Switcher")
case .supermuxWorkspaceSwitcherPrevious: return String(localized: "supermux.shortcut.workspaceSwitcherPrevious.label", defaultValue: "Workspace Switcher (Reverse)")
// SUPERMUX:end workspace-switcher-shortcut-label

// in `var defaultShortcut`, after the run-toggle default fence:
// SUPERMUX:begin workspace-switcher-shortcut-default
case .supermuxWorkspaceSwitcherNext:
    return StoredShortcut(key: "`", command: true, shift: false, option: false, control: false)
case .supermuxWorkspaceSwitcherPrevious:
    return StoredShortcut(key: "`", command: true, shift: true, option: false, control: false)
// SUPERMUX:end workspace-switcher-shortcut-default
```

`isPublicShortcutAction` defaults to `true`, so both actions show up in Settings and are
config-rebindable automatically. ⌘\` and ⇧⌘\` are in `hardcodedSystemWideHotkeyConflicts`
(reserved only for the *global* show/hide hotkey) — that list does not block an in-app action
from binding the chord. If upstream restructures the enum, the requirement is: two single-stroke
actions defaulting to ⌘\` / ⇧⌘\`.

**24. `Sources/AppDelegate.swift` — `workspace-switcher-monitor`.** One hook at the top of the
`installShortcutMonitor()` closure, after the `ShortcutRecorderEventRouter` check and *before*
the `.systemDefined` early-return (so it also sees `.flagsChanged`):

```swift
// SUPERMUX:begin workspace-switcher-monitor
if SupermuxComposition.workspaceSwitcher.handleMonitorEvent(event, appDelegate: self) {
    return nil
}
// SUPERMUX:end workspace-switcher-monitor
```

`handleMonitorEvent` returns `false` immediately for the typing hot path (anything that is not a
Command-modified keyDown while idle), so it adds no latency. While presented it owns
keyDown/keyUp/flagsChanged and commits the switch on ⌘ release via `TabManager.selectWorkspace`.
If upstream restructures the monitor, the requirement is: give the switcher controller first
crack at every app-local event and swallow it when the controller consumes it.

**25. `web/data/cmux-shortcuts.ts` — `workspace-switcher-shortcut-doc`.** Two registry rows in
the Workspaces section (after `prevSidebarTab`), documenting ⌘\` (cycle) and ⇧⌘\` (reverse).
Pair with the
`web/data/cmux.schema.json` enum additions (touchpoint #14) and the `supermux.*` localization
keys in `Resources/Localizable.xcstrings` (touchpoint #4b).

### 5 (cont.) + 26–27. Narrower right sidebar (`right-sidebar-min-width` + `right-sidebar-compact-mode-bar`)

Lets the right sidebar be dragged narrower than upstream's 276 pt floor without clipping the
header's close button. Two parts:

**26. `Packages/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` —
`right-sidebar-min-width`.** Lower the floor constant:

```swift
// SUPERMUX:begin right-sidebar-min-width
// (comment) …
public static let minimumWidth = 200.0
// SUPERMUX:end right-sidebar-min-width
```

This is the single source of truth for the drag clamp (`ContentView.clampedRightSidebarWidth`)
and the max-width settings editor's lower bound. If upstream changes the constant, keep our
lowered value inside the fence. Pick the value to match what the icon-only mode bar needs for the
default mode set (files/find/sessions/changes); going lower risks clipping the close button when
the beta feed/dock modes are also enabled.

**5 (cont.) `Sources/RightSidebarPanelView.swift` — `right-sidebar-compact-mode-bar`.** The mode
buttons must collapse to icon-only when narrow, else the labeled pills overflow and the
`.clipped()` panel hides the trailing close button. Only the mode buttons go through
`ViewThatFits` (labeled, then icon-only); the open-as-pane and close controls are laid out as
fixed trailing siblings so they are **pinned and never clip** — even with all beta modes enabled
at the minimum width (where even icon-only mode buttons overflow, the overflow clips a leading
mode icon instead of the close button):

```swift
ZStack {
    WindowDragHandleView()            // stays as background so dragging still moves the window
    // SUPERMUX:begin right-sidebar-compact-mode-bar
    HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
        ViewThatFits(in: .horizontal) {
            modeButtonsRow(showsLabels: true)
            modeButtonsRow(showsLabels: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        if fileExplorerState.mode.canOpenAsPane {
            openAsPaneButton(mode: fileExplorerState.mode)
        }
        closeButton
    }
    // SUPERMUX:end right-sidebar-compact-mode-bar
}
```

`modeButtonsRow(showsLabels:)` is a new helper holding just the mode-button `HStack` (the
`ForEach` over `availableModes`). `ModeBarButton` gains a `showsLabel` flag that drops the
`Text(mode.label)` when false. If upstream restructures `modeBar`, the requirement is: render the
mode buttons through `ViewThatFits` with a labeled and an icon-only variant inside a
`maxWidth: .infinity` clipped frame, with open-as-pane/close pinned outside it, and keep the drag
handle as the ZStack background. Budget bump for this file is recorded in the #4 table.

**27. `cmuxTests/SidebarWidthPolicyTests.swift` — `right-sidebar-min-width-test`.** Two clamp
assertions that previously hardcoded `276` now read `CGFloat(RightSidebarWidthSettings.minimumWidth)`
so they track the floor regardless of its value.

### 28–33. Toggle Pane Zoom rebind (`toggle-split-zoom-rebind`)

supermux's Changes panel binds **⇧⌘↩** to its Commit accelerator (typed-message commit or AI
"Generate & Commit", whichever applies — see `SupermuxChangesPanelView.commitArea` /
`commitShiftReturnAccelerator`, a supermux-owned file with no fence). But ⇧⌘↩ was the cmux default
for **Toggle Pane Zoom** (`toggleSplitZoom`), and the app-local NSEvent monitor in `AppDelegate`
consumes that chord before any SwiftUI button shortcut can fire. So the commit accelerator only
works once Toggle Pane Zoom is moved off ⇧⌘↩. All six edits share the fence id
`toggle-split-zoom-rebind`; the new default is **⌃⌘Z** ("Z" for Zoom; pairs with ⌃⌘= equalize, and
deliberately *not* ⌃⌘↩ which some screen recorders use — see the rationale comment in #32).

- **28. `Sources/KeyboardShortcutSettings.swift`** (canonical `defaultStroke` table) and
  **29. `Packages/CmuxSettings/.../ShortcutAction+Defaults.swift`** (the settings-UI package mirror):
  the `case .toggleSplitZoom` default returns `key: "z", command: true, control: true` instead of
  `key: "\r", command: true, shift: true`. Both tables must agree.
- **30. `web/data/cmux-shortcuts.ts`:** the `toggleSplitZoom` registry row's `combos` is
  `[["⌃", "⌘", "Z"]]` (was `[["⌘", "⇧", "↩"]]`).
- **31. `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift`:** the whole
  `testCmdControlZFocusedBrowserTogglesSplitZoom` method is fenced; it builds a ⌃⌘Z key event
  (`key: "z", modifiers: [.command, .control], keyCode: 6`) instead of ⇧⌘↩ and asserts the
  configured `toggleSplitZoom` shortcut matches it. The browser-focused assertion now verifies
  the **app monitor** toggles zoom (`debugHandleShortcutMonitorEvent`) rather than the browser
  webView's `performKeyEquivalent`: a Return-key shortcut (⇧⌘↩) routed through the browser's
  Return-key branch (`handleBrowserSurfaceKeyEquivalent` → full dispatcher), but a non-Return
  chord (⌃⌘Z) is owned by the local key monitor, which fires ahead of the responder chain — so
  the browser never claims it in real use.
- **32. `cmuxTests/KeyboardShortcutContextTests.swift`:** comment-only — the rationale for
  `toggleBrowserFocusMode`'s ⌥⌘↩ default no longer calls Toggle Pane Zoom "the other Return-based
  shortcut". Assertions are unchanged (⌥⌘↩ still differs from and does not conflict with ⌃⌘Z).
- **33. `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift`:** the two browser zoom round-trip
  tests (`testCmdControlZKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused`,
  `testCmdControlZHidesBrowserPortalWhenTerminalPaneZooms`) press `app.typeKey("z", [.command, .control])`
  instead of ⇧⌘↩, with matching renamed methods and assertion messages.

If upstream changes the `toggleSplitZoom` default or these tests, keep our ⌃⌘Z value inside the
fence. If upstream adds a different action on ⌃⌘Z, pick another free, non-`⌃⌘↩` chord for zoom and
update all six sites. Budget bumps for #28/#32/#33 are in the #4 table; #29 (a package file) and
#31 (a test) are not budget-tracked.

### 34–36. Completing the rebind: Ghostty must release ⇧⌘↩ too

Moving the cmux *default* off ⇧⌘↩ (#28–33) is necessary but **not sufficient**: Ghostty has its
own built-in keybind `super+shift+enter = toggle_split_zoom` (`ghostty/src/config/Config.zig`,
the submodule cmux does not patch). When a terminal surface is first responder, cmux's
`cmux_performKeyEquivalent` hands a Command-modified Return to the Ghostty surface on a main-menu
miss, and Ghostty consumes it for split zoom **before** the SwiftUI commit accelerator's key
equivalent is ever reached — so without unbinding it, ⇧⌘↩ in a focused terminal still zooms and
never commits (the same "rebind looks hardcoded because Ghostty keeps its fallback" failure as the
numbered-tab unbinds, https://github.com/manaflow-ai/cmux/issues/5189).

- **34. `Sources/GhosttyTerminalView.swift`:** a fenced second `loadInlineGhosttyConfig` call in
  `loadCmuxOwnedGhosttyKeybindOverrides` adds `keybind = super+shift+enter=unbind` **and**
  `keybind = super+enter=unbind` (prefix `supermux-owned-keybind-overrides`): the first frees
  ⇧⌘↩ (`toggle_split_zoom`) for the commit accelerator, the second frees ⌘↩
  (`toggle_fullscreen`) for `supermuxCommit`. Both parse to the physical Enter trigger, exactly
  matching the default bindings, and Ghostty's `unbind` removes them (`Binding.zig`), after
  which the chords fall through to the SwiftUI commit buttons. If upstream adds these unbinds
  itself, drop this fence; if it changes the triggers, mirror the new triggers here.
- **35. `Sources/App/ShortcutRoutingSupport.swift`:** a fenced comment in
  `shouldDispatchBrowserReturnViaFirstResponderKeyDown` no longer cites Toggle Pane Zoom as the
  example Command-Return app shortcut (it is ⌃⌘Z now, not Return-based); it notes ⇧⌘↩ is the
  Changes-panel commit accelerator. Comment-only — the routing logic is unchanged.
- **36. `cmuxTests/AppDelegateShortcutRoutingTests.swift`:** a fenced regression test,
  `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback`, asserts the loaded Ghostty config has no
  `super+shift+enter` binding and no `super+enter` binding (a second kVK_Return probe with
  `[.command]`, via the same `ghosttyConfigKeyIsBinding` helper as the #5189 numbered-fallback
  test). Red without #34, green with it.

Budget bumps for #34/#35/#36 are in the #4 table.

### 37–38. Commit shortcut promoted to the registry (`supermux-commit-shortcut`)

The Changes-panel Commit chords were hardcoded SwiftUI `.keyboardShortcut`s, so they
were not editable in Settings, not in `cmux.json`, and invisible to conflict detection.
They are now registered actions, following the `supermuxToggleRun` pattern, but applied
via SwiftUI rather than the app monitor (the action is inherently panel-scoped, so a
global monitor handler would have to route to the focused panel's model).

- **37. `Sources/KeyboardShortcutSettings.swift`:** three fences (`-case`, `-label`,
  `-default`) add `case supermuxCommit` (default ⌘↩) and `case supermuxCommitAccelerator`
  (default ⇧⌘↩) with localized labels (`supermux.shortcut.commit.label` /
  `…commitAccelerator.label`). Because the app monitor has **no** handler for these, it
  never consumes the chords; the Changes panel applies them. Return was free among defaults
  once Toggle Pane Zoom moved to ⌃⌘Z (#28), so neither default conflicts.
- **38. `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift`:** `testSupermuxCommit
  DefaultsBindReturnChords` clears any overrides, then asserts the two defaults match
  ⌘↩ / ⇧⌘↩ and do not cross-match.

The wiring lives in supermux-owned files (no fence): `SupermuxChangesMount`
(`Sources/Supermux/SupermuxAppGlue.swift`) resolves each configured shortcut to a SwiftUI
`KeyboardShortcut` and passes it (plus the primary's display string for the button help)
into `SupermuxChangesPanelView`, which applies them to the visible Commit button and the
invisible accelerator. If upstream adds an action on ⌘↩ or ⇧⌘↩, rebind these or accept the
conflict warning. The Settings UI's action list and conflict detection are driven by the
settings-package enum, so the actions are also registered there (#62/#63) — without that
registration the "editable in Settings" claim does not hold. Budget bump for #37 is in the #4
table; #38 (a small test file) is not budget-tracked.

### 39. `Sources/FileExplorerView.swift` — file-explorer file operations

Adds create/rename/duplicate/trash to the right-sidebar file tree. All behavior lives in
supermux-owned files; the three fences are one-line calls into a
`FileExplorerPanelView.Coordinator` extension:

- `Sources/Supermux/SupermuxFileExplorerCommands.swift` — the `NSMenu` item builders
  (`addSupermuxFileOperationItems` / `addSupermuxRootFileOperationItems`), the shared `@objc`
  command handlers (`supermuxNewFile`/`supermuxNewFolder`/`supermuxRename`/`supermuxDuplicate`/
  `supermuxMoveToTrash`), and the keyboard entrypoint `handleSupermuxFileOperationKey`.
- `Sources/Supermux/SupermuxFileExplorerPrompt.swift` — the `SupermuxFileOpRequest` carrier, the
  localized `supermux.fileOps.*` strings, and the sheet-based name prompt / trash confirmation /
  error presentation.
- `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileSystemOperations.swift` — the pure,
  unit-tested filesystem create/rename/duplicate/trash logic (name validation, collision handling,
  English, locale-independent " copy" naming — deliberately not localized, since it is an
  on-disk filename, not UI text).
- `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileExplorerSelection.swift` — the pure,
  unit-tested selection/reconciliation seams (`authoritativePaths`, `contextTargetPaths`,
  `fileOpAction`/`FileOpReveal`, `revealAfterTrash`) that back the destructive-action targeting,
  post-op reveal/clear, and stale-workspace handling.

**`file-explorer-operations`:** at the end of the `Coordinator.menuNeedsUpdate(_:)` node branch
(after the Copy Relative Path item):

```swift
menu.addItem(copyRelItem)
// SUPERMUX:begin file-explorer-operations
menu.addSupermuxFileOperationItems(coordinator: self, clickedNode: node)
// SUPERMUX:end file-explorer-operations
```

**`file-explorer-operations-empty`:** in the same method's `guard` for a clicked node, the `else`
adds root-scoped New File/New Folder when the empty area is right-clicked, then returns:

```swift
guard clickedRow >= 0,
      let node = outlineView.item(atRow: clickedRow) as? FileExplorerNode else {
    // SUPERMUX:begin file-explorer-operations-empty
    menu.addSupermuxRootFileOperationItems(coordinator: self)
    // SUPERMUX:end file-explorer-operations-empty
    return
}
```

**`file-explorer-operations-keys`:** in `FileExplorerNSOutlineView.keyDown(with:)`, immediately
after the quick-search block (so quick-search still owns those keys while active):

```swift
if quickSearchActive, handleQuickSearchKey(event) {
    return
}

// SUPERMUX:begin file-explorer-operations-keys
if !quickSearchActive,
   fileExplorerCoordinator?.handleSupermuxFileOperationKey(event, in: self) == true {
    return
}
// SUPERMUX:end file-explorer-operations-keys
```

Return/⌘⌫ are never claimed during an active `/` quick-search — the `!quickSearchActive` guard
keeps Return's upstream meaning there (end quick-search, open the selection), otherwise the
rename sheet would open over a zombie query that keeps eating keystrokes. And
`handleSupermuxFileOperationKey` yields to a user-**explicitly**-configured Open Selection
binding (Settings override or cmux.json) matching the keystroke, while the built-in Return
default remains shadowed.

If upstream restructures the explorer, the requirement is: populate the tree's context menu with
the supermux file-operation items (node branch and empty-area branch) and route ⌘⌫/Return through
`handleSupermuxFileOperationKey` before the outline view's own navigation handling. Operations are
local-provider only. Budget bump for this file is in the #4 table; the pbxproj additions for the
two new app files are in the #3 note.

**`file-explorer-operations-reveal` (#39 + #40, two files):** a just-created or renamed item is
selected and scrolled into view after the post-operation reload.

- **#40 `Sources/FileExplorerStore.swift`:** add a `var supermuxRevealPath: String?` and a
  `func supermuxReveal(path:)` that sets `selectedPath`/`selectedPaths` (which are `private(set)`,
  so this must live in the store) and stores `supermuxRevealPath`. The app handlers call
  `store.supermuxReveal(path: created/renamed.path)` before the reload. The store fence also
  carries `var supermuxRevealRequestedAt: Date?` (set in `supermuxReveal`, cleared in
  `supermuxClearSelection`) so the coordinator can expire a stale reveal, and two minimal
  same-id fences in `select(node:)` and `select(nodes:anchor:)` clear `supermuxRevealPath` when
  the user moves the selection to a different path before the reveal lands.
- **#39 `Sources/FileExplorerView.swift`:** in `Coordinator.reloadIfNeeded()`, right after the
  `withProgrammaticOutlineUpdate { … applyStoredSelection(…) }` block:

  ```swift
  // SUPERMUX:begin file-explorer-operations-reveal
  if let revealPath = store.supermuxRevealPath,
     supermuxRevealRowIfPresent(revealPath, in: outlineView) {
      store.supermuxRevealPath = nil
  }
  // SUPERMUX:end file-explorer-operations-reveal
  ```

  `supermuxRevealRowIfPresent` (supermux-owned, in `SupermuxFileExplorerCommands.swift`) scrolls the
  row for the path if present and returns whether it found it, so the flag is cleared only once the
  row actually exists (the item may appear a reload later when its parent folder finishes loading).
  It also expires a stale reveal: when `supermuxRevealRequestedAt` is older than 10s it clears
  `store.supermuxRevealPath` and returns false, so a reveal whose row never materializes cannot
  hijack a much-later reload. Post-op refresh contract: the explicit `reload()` +
  `refreshGitStatus()` after a file operation is skipped when every mutated parent directory
  equals the watched root (the root `FileWatcher` delivers the refresh ~300ms later); failure
  paths always refresh explicitly.
  If upstream restructures the store/reload, the requirement is: after a file op, select the new
  path and scroll it into view once its row loads. The four pending-reveal invalidation
  regression tests live in a `file-explorer-operations-reveal` fenced block in
  `cmuxTests/FileExplorerStoreTests.swift` (#72), reusing this feature's fence id.

### 41. `Sources/TabManager.swift` — `new-workspace-standalone`

The `+` / New Workspace button must always create a workspace at the **root** of the flat
list, never nested under the focused project — the user nests intentionally by double-clicking
a project. Supermux project nesting is decided per-render by
`SupermuxWorkspaceAssociationStore.projectId(forWorkspace:directory:in:)`, which (besides an
explicit session association) matches by directory: the durable directory link and the worktree
matcher. A `+` workspace inherits the focused workspace's directory
(`addWorkspace(inheritWorkingDirectory: true)`), so when focused in a project it inherited the
project's root/worktree directory and got re-captured.

One fenced line in `TabManager.addWorkspace`, right after `newWorkspace.owningTabManager = self`:

```swift
// SUPERMUX:begin new-workspace-standalone
SupermuxComposition.workspaceAssociations.markStandalone(workspaceId: newWorkspace.id)
// SUPERMUX:end new-workspace-standalone
```

This is the store's own stated rule ("workspaces created via cmux's normal flow stay
standalone"). `markStandalone` adds the id to a session-scoped set that `projectId(...)` checks
**first** (returns `nil`); the project opener's `associate(...)` clears it so project-originated
opens still nest; the central `closeWorkspace` removal path calls `forget(...)` after the workspace
is actually removed, clearing both the session association and standalone mark while preserving
durable directory links.

Restore and move paths need care because they don't all go through `addWorkspace`:
- **Session restore** builds `Workspace` objects directly (no `addWorkspace`), so restored
  project main/worktree workspaces re-nest by directory unaffected.
- **`restoreClosedWorkspace`** (reopen, ⌘⇧T) *does* call `addWorkspace`, so it would wrongly mark
  the reopened workspace standalone — it explicitly `forget`s the mark right after, restoring
  directory-based nesting (a reopened project workspace re-nests; the only residual imprecision is
  a standalone `+` workspace that sat exactly at a project's durable-linked root or inside a
  worktree dir, which re-nests on reopen — matching pre-change behavior and not worth persisting
  per-workspace standalone state through closed-workspace history).
- **`TabManager+DetachedWorkspace`** (move-tab / move-surface) builds a `Workspace` directly, so it
  marks the new workspace standalone too (touchpoint #42).
- **`releaseRestoredAwayWorkspace`** (session restore's teardown of the replaced pre-restore
  workspaces) never reaches the central `closeWorkspace` forget, so a fenced call `forget`s each
  released workspace's association/standalone entries itself, right after
  `workspace.owningTabManager = nil`; the restored replacements re-nest by directory:

  ```swift
  // SUPERMUX:begin new-workspace-standalone
  // A released pre-restore workspace never reaches the central
  // closeWorkspace forget, so drop its association/standalone entries
  // here (the restored replacement re-nests by directory).
  SupermuxComposition.workspaceAssociations.forget(workspaceId: workspace.id)
  // SUPERMUX:end new-workspace-standalone
  ```
- **Whole-window teardown** (`AppDelegate.unregisterMainWindow`, registry row #58) skips the
  per-workspace close path entirely, so a fenced call prunes the association store against the
  union of every remaining window's workspace ids
  (`SupermuxComposition.workspaceAssociations.prune(retainingWorkspaceIds:)`) — never one
  window's list, which would drop the other windows' links. Durable directory links live in the
  projects model and survive, so a revived closed window re-nests by directory.

Native cmux workspace groups (`groupId`) are deliberately untouched. If upstream restructures
`addWorkspace`, the requirement is: mark every workspace created by the normal new-workspace flow
standalone (and the detached-surface create), while restore/reopen paths re-nest by directory. The
`SupermuxWorkspaceAssociationStore` API additions live in the package (no fence).

### 43–45. Empty home — keep the window open on last-tab close (`keep-window-on-last-close` + `empty-home`)

Closing the last workspace used to escalate to `window.performClose(nil)`, and on the last
window `handleMainTerminalWindowShouldClose` → `handleQuitShortcutWarning` quit the app. Supermux
keeps the window open as a "home" (the always-present Projects sidebar) with zero workspaces.

**`Sources/TabManager.swift` (`keep-window-on-last-close`):**
1. `closeWorkspace` gains a fenced `allowEmptyingWindow: Bool = false` parameter; the guard
   becomes `guard tabs.count > 1 || allowEmptyingWindow else { return }`; and the post-remove
   selection update sets `selectedTabId = nil` when `tabs.isEmpty` (the upstream `tabs[newIndex]`
   would crash on the empty array).
2. The three last-workspace close sites that called `window.performClose(nil)` —
   `closeWorkspaceIfRunningProcess`, the bulk-close anchor branch, and `closePanelAfterChildExited`
   — now call `closeWorkspace(workspace, allowEmptyingWindow: true)`.
3. The bulk-close top short-circuit (`plan.workspaces.count == tabs.count` → close window) is
   omitted so the loop empties the window instead; `closeWorkspacesPlan`'s `willCloseWindow` is
   forced `false` so the confirmation copy reads "Close workspaces?" not "Close window?". The
   pinned-workspace confirmation also passes `acceptCmdD: false`, because closing the final
   workspace is no longer a window-closing action.
4. `restoreClosedWorkspace` failure cleanup passes `allowEmptyingWindow: true` so a malformed or
   unrestorable closed-workspace snapshot does not leave behind its temporary workspace when the
   reopen was attempted from the empty-home state.
5. `detachWorkspace` (move the workspace to another window) leaves the source window empty
   (`selectedTabId = nil`) when its last workspace moves out, instead of upstream's
   `addWorkspace()` refill; `restoreSessionSnapshot` restores a snapshot persisted with zero
   workspaces as an empty home (the fallback workspace fabrication is gated on
   `!snapshot.workspaces.isEmpty`); and a fenced comment marks
   `markRemoteTmuxKillOnWindowCloseIfNeeded` as intentionally orphaned (kept verbatim for merge
   cleanliness).

   The explicit window-close paths (red button / ⌘⇧W / `closeWindow`) are intentionally left as
   upstream — closing the *window* still quits on the last window; only closing the last *tab*
   keeps it open.

The same fence id also covers the non-UI last-close entrypoints so every path lands on the empty
home instead of a silent no-op or a fabricated replacement workspace: AppleScript closes
(registry row #61), the socket `close_workspace` command (#59), the remote-tmux dead-mirror
`.closeWorkspace` action (#60), and the remote-tmux close-button fallback in
`Sources/Workspace.swift` (#57).

**`Sources/ContentView.swift` (`empty-home`):** `terminalContent` renders `SupermuxEmptyHomeView`
(centered "No open tabs" hint) inside the existing `ZStack` when `tabManager.tabs.isEmpty`, gated
to the `.tabs` sidebar surface and non-interactive. The one-shot startup recovery's upstream
`if tabManager.tabs.isEmpty { addWorkspace() }` block is suppressed, because zero workspaces is a
valid supermux runtime state and the delayed recovery could otherwise refill a window the user had
intentionally emptied. The startup-recovery fence early-returns when `tabs` is empty (running
only `syncSidebarSelectedWorkspaceIds`/`applyUITestSidebarSelectionIfNeeded`), so an
intentionally-empty window no longer logs a spurious `startup.recovery` breadcrumb.

**`cmuxTests/TabManagerUnitTests.swift` (`keep-window-on-last-close`):** the child-exit
window-close test is repurposed to assert the window stays open (no close request, tabs empty,
selection `nil`), all-workspace close confirmation expectations now use "Close workspaces?", plus
two new tests cover `closeWorkspace(allowEmptyingWindow:)` emptying the window and the plain close
still keeping the last workspace. `testFailedClosedWorkspaceRestoreFromEmptyHomeCleansUpTemporaryWorkspace`
covers cubic's review finding that failed closed-workspace restore cleanup must not leave a
temporary workspace behind when reopening from empty home. Two more fenced tests,
`testDetachingLastWorkspaceLeavesEmptyHome` and
`testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty`, cover the `detachWorkspace` and
zero-workspace snapshot-restore paths.

New supermux-owned file `Sources/Supermux/SupermuxEmptyHomeView.swift` (wired via touchpoint #3,
IDs `…F5`/`…F6`); `supermux.emptyHome.{title,subtitle}` localization keys (en+ja) under #4b.
If upstream restructures these paths, the requirement is: closing the last *tab* removes it and
keeps the window open with an empty-state view; closing the *window* is unchanged.

### 50. `Sources/ContentView.swift` — `sidebar-hide-scrollbar`

`VerticalTabsSidebar.configureSidebarScrollView(_:)` is the resolver hook that configures the left
sidebar's backing `NSScrollView`. It is the single chokepoint for both the default
projects+workspaces list (`workspaceScrollArea`) and the extension-provider list
(`extensionSidebarScrollArea`); the supermux Projects section mounts inside the same scroll view, so
hiding the scroller here covers projects + workspaces in one place. Upstream's body was a single
call to `scrollView.applySidebarOverlayScrollerConfiguration()`, preceded by a doc comment
describing that stable overlay/autohide config. The fence starts above the doc comment (so the now-
stale comment is replaced/owned by supermux) and replaces the body:

```swift
// SUPERMUX:begin sidebar-hide-scrollbar
// The workspace sidebar … hides its scrollers entirely … (rationale comment;
// replaces upstream's stale overlay/autohide doc comment)
private func configureSidebarScrollView(_ scrollView: NSScrollView?) {
    guard let scrollView else { return }
    if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
    if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
    // SUPERMUX:end sidebar-hide-scrollbar
}
```

Do **not** keep the upstream `applySidebarOverlayScrollerConfiguration()` call and hide the scroller
afterwards: that helper forces `hasVerticalScroller = true`, so each resolver re-apply (frequent
during agent activity) would write `true` then `false`, re-tiling AppKit's scrollers every time —
the exact #3241 stuck-knob churn the helper was written to avoid. Owning the config directly and
only writing a property when it differs keeps every re-resolve a pure no-op.

**The AppKit resolver is not enough on its own.** SwiftUI's `ScrollView` representable re-asserts
`hasVerticalScroller` from its default `.scrollIndicators(.automatic)` on every update pass, and the
resolver applies its config one runloop hop later (a deferred `Task { @MainActor }`), so SwiftUI
wins and the bar stays visible. The fix is a second fence (same id) adding `.scrollIndicators(.hidden)`
to **both** sidebar `ScrollView`s — the workspace list in `workspaceScrollArea` (`ScrollView(.vertical)`)
and the built-in extension-provider list in `extensionSidebarTimelineContent` (the else-branch helper
that `extensionSidebarScrollAreaContent` delegates to — the only extension branch using this
`ScrollView`/`SidebarScrollViewResolver`) — placed right after the `ScrollView { … }` closing brace,
before `.background(SidebarScrollViewResolver …)`. With SwiftUI told
to hide the indicator, the two layers agree and the bar never reappears.

If upstream restructures the sidebar scroll configuration, the requirement is: the left sidebar's
`NSScrollView` has both scrollers hidden (`hasVerticalScroller`/`hasHorizontalScroller == false`)
written idempotently, **and** the SwiftUI `ScrollView`s carry `.scrollIndicators(.hidden)` so SwiftUI
does not re-show them — with scrolling still driven by trackpad/wheel. Budget row for
`Sources/ContentView.swift` carries +19 for this fence (16236→16255).

### 51. `scripts/reload.sh` — `reload-prune-leftover-base-app`

A tagged build (`reload.sh --tag <tag>`) builds the raw `cmux DEV.app`, copies it to a staging
bundle, rewrites the copy's `CFBundleIdentifier`/name, and `mv`s the copy to
`cmux DEV <tag>.app`. The original `cmux DEV.app` is left behind in the same
`Build/Products/Debug/` dir. It is never launched, but macOS still registers its bundled sidebar
ExtensionKit app-extension and Dock Tile plugin, so every distinct tag adds a stale "cmux DEV" row
to System Settings → General → Login Items & Extensions (both the "Allow in the Background" and
"Added Extensions" lists). The fence deletes that leftover right after the final `mv`.

In the block that finalizes the tagged app (after `APP_PATH="$TAG_APP_FINAL_PATH"`):

```bash
if [[ -n "${TAG_APP_FINAL_PATH:-}" && -n "${TAG_APP_STAGING_PATH:-}" ]]; then
  rm -rf "$TAG_APP_FINAL_PATH"
  mv "$TAG_APP_STAGING_PATH" "$TAG_APP_FINAL_PATH"
  APP_PATH="$TAG_APP_FINAL_PATH"
  # SUPERMUX:begin reload-prune-leftover-base-app
  SUPERMUX_PRUNE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/supermux-prune-dev-builds.sh"
  if [[ -x "$SUPERMUX_PRUNE" ]]; then
    "$SUPERMUX_PRUNE" --reload-leftover "$TAG_APP_FINAL_PATH" >/dev/null 2>&1 || true
  fi
  # SUPERMUX:end reload-prune-leftover-base-app
fi
```

`scripts/supermux-prune-dev-builds.sh` is supermux-owned (not an upstream touchpoint); only this
one-line call into it is fenced. `--reload-leftover <final-app>` deregisters (`lsregister -u`) and
removes the sibling base `cmux DEV.app` plus any dead `.<name>.reload-*.app` staging copies, keeping
the final app and any staging whose reload pid is still running (so a concurrent same-tag reload is
never disturbed). The same script (no args) is the manual full cleanup: `--apply` deregisters + removes all
redundant leftovers, `--prune-derived` also sweeps DerivedData (via `cleanup-dev-builds.sh`), and
`--rebuild-lsdb` rebuilds the LaunchServices DB. Active/running/`--keep` tags are always protected.

### 52–55. iOS phone build — production-auth override on a personally-signed DEBUG build

These four touchpoints let a locally-built DEBUG iOS app (personal Apple team) pair with the
**installed production Supermux Mac**. The stock DEBUG build authenticates against the *development*
Stack project, so its user id never matches the production Mac and pairing is rejected; and the
stock entitlements require capabilities a personal team cannot provision. All four are needed
together.

**52. `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift` — `force-production-auth`.**
In `init(...)`, right before `AuthConfig(environment:overrides:)` is built, derive `isDevelopment`
from the bundled `LocalConfig.plist` instead of the raw `#if DEBUG` flag:

```swift
// SUPERMUX:begin force-production-auth (LocalConfig STACK_ENVIRONMENT=production)
// Lets a tagged DEBUG build opt into the PRODUCTION Stack project AND its
// cmux.dev callback, so it can pair with the installed production Supermux
// Mac. Without the key, behavior is unchanged (DEBUG -> development).
let overrides = Self.localConfigStringOverrides(in: bundle)
let isDevelopment = overrides["STACK_ENVIRONMENT"]?.lowercased() == "production"
    ? false
    : Self.isDevelopmentBuild
// SUPERMUX:end force-production-auth
```

`localConfigStringOverrides(in:)` already exists upstream and is reused for the `AuthConfig`
overrides table. If upstream restructures the composition root, the requirement is: when the bundled
`LocalConfig.plist` says `STACK_ENVIRONMENT=production`, resolve the auth config for `.production`
even in a DEBUG build.

**53. `ios/Config/cmux.entitlements` — unfenced.** Remove the three capability keys the personal team
can't provision: the `com.apple.developer.applesignin` array, the `aps-environment` string, and the
`com.apple.developer.usernotifications.time-sensitive` bool. Tradeoff: no APNs push and the
Apple-sign-in button is dead (Google / email-code sign-in still work). To restore the stock file:
`git checkout <upstream> -- ios/Config/cmux.entitlements`. A plist-key *removal* can't be wrapped in a
comment fence, so this file is `unfenced` — re-apply by deleting the same three keys after a merge.

**54. `ios/cmux-ios.xcodeproj/project.pbxproj` — unfenced.** Add `LocalConfig.plist` to the app's
Copy Bundle Resources, mirroring the existing `Localizable.xcstrings` entries with reserved IDs:
a `PBXBuildFile` `FCAB10042DF5000000A66F90` (`LocalConfig.plist in Resources`), a `PBXFileReference`
`FCAB101B2DF5000000A66F90` (`lastKnownFileType = text.plist.xml; path = LocalConfig.plist`), the file
ref listed in the `Resources` group's `children`, and the build file listed in the app target's
`PBXResourcesBuildPhase` `files`. Verify: `plutil -lint ios/cmux-ios.xcodeproj/project.pbxproj`.

**55. `ios/cmux/Resources/LocalConfig.plist` — new supermux-owned resource.** A one-key plist,
`STACK_ENVIRONMENT=production`, read by touchpoint #52 and bundled via #54. Contains no secret (the
production Stack project id + publishable key are already in
`Packages/Shared/CMUXAuthCore/.../CMUXAuthConfig.swift` / `CmuxAuthRuntime/.../AuthConfig.swift`).
Because a Copy-Bundle-Resources entry points at it, a fresh clone/CI must have the file present or
the iOS build fails with "Build input file cannot be found" — which is why it is committed rather
than gitignored.

**Rebuilding the phone app** (personal team cert lasts ~1 year; rerun to renew):

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /opt/homebrew/bin/bash \
  ios/scripts/reload.sh --tag rajin --device-only --team NRGUG8GVV4 \
  --allow-device-registration --no-setup
```

Needs Homebrew bash 5 (`ios/scripts/reload.sh` trips a bash 3.2 empty-array bug under `set -u`) and
the Xcode 27 beta toolchain (stable Xcode couldn't see the device). iPhone connected via USB +
trusted. The Mac side must have `mobile.iOSPairingHost.enabled` on; the phone reaches it over
Tailscale (LAN-speed / direct at home).

### 56. `Sources/Workspace.swift` — `workspace-agent-lifecycle-observation`

In `Sources/Workspace.swift`, inside `private func recordAgentLifecycleChange(panelId: UUID)`,
insert as the first statement:

```swift
// SUPERMUX:begin workspace-agent-lifecycle-observation
SupermuxWorkspaceLifecycleRelay.workspaceDidChangeAgentLifecycle(self)
// SUPERMUX:end workspace-agent-lifecycle-observation
```

(+3 lines; must precede the `AgentHibernationController.shared.recordAgentLifecycleChange` call,
whose tracking gate drops events when hibernation is disabled.) The relay lives in supermux-owned
`Sources/Supermux/SupermuxWorkspaceActivityResolver.swift`. This is the single choke point every
agent-lifecycle set/clear routes through; without it, lifecycle-only mutations (socket
`set_agent_lifecycle`, hibernation clears, feed-attention conclusion) are invisible to the
supermux activity indicators because cmux's sidebar publishers carry no lifecycle field.

### 57/59–61/70–71. `keep-window-on-last-close` beyond TabManager

The empty-home close behavior (see #43–45) has six more carriers; each fence replaces an
upstream workaround that assumed a window can never have zero workspaces. (#58, the
`new-workspace-standalone` prune in `AppDelegate.unregisterMainWindow`, is covered in §41.)

- **57. `Sources/Workspace.swift`** — in the remote-tmux close-button fallback (after the
  multi-window discard branch, which stays upstream), the last workspace of the last window
  closes via `manager.closeWorkspace(self, recordHistory: false, allowEmptyingWindow: true)` +
  `scheduleTerminalGeometryReconcile()` instead of falling through to a replacement local shell
  in the dead mirror.
- **59. `Sources/TerminalController.swift`** — the socket `close_workspace` command calls
  `tabManager.closeWorkspace(tab, allowEmptyingWindow: true)` and replies `OK` only when the
  workspace actually left `tabs` (upstream's `closeTab` silently no-ops on a window's last
  workspace while replying `OK`).
- **60. `Sources/RemoteTmuxController.swift`** — the dead-mirror `.closeWorkspace` action
  resolves the owning manager and calls `closeWorkspace(workspace, allowEmptyingWindow: true)`;
  upstream's add-a-replacement-workspace-first workaround is deleted inside the fence.
- **61. `Sources/AppleScriptSupport.swift`** — `ScriptTab.handleCloseTab` and the
  `ScriptTerminal.handleClose` last-panel path call
  `closeWorkspace(workspace, allowEmptyingWindow: true)` instead of the `tabs.count > 1` fork +
  `window.performClose(nil)`.
- **70. `Sources/TerminalController+ControlWorkspaceContext.swift`** — the control-socket
  `workspace.close` resolver (`controlCloseWorkspace`) calls
  `closeWorkspace(ws, allowEmptyingWindow: true)` and returns `.resolved` only when the
  workspace actually left `tabs`; the plain close silently no-op'd on a window's last
  workspace while still reporting `.resolved`.
- **71. `Sources/TerminalController+MobileWorkspaceList.swift`** — `v2MobileWorkspaceClose`
  drops upstream's `tabs.count > 1` rejection (which returned `protected` for the last
  workspace), closes via `closeWorkspace(workspace, allowEmptyingWindow: true)`, and replies
  ok only when the workspace actually left `tabs`. A second fence updates the function's doc
  comment.

If upstream restructures any of these, the requirement is: every last-workspace close entrypoint
(UI, AppleScript, socket, control socket, mobile API, remote-tmux) routes through
`closeWorkspace(_:allowEmptyingWindow: true)`, verifies removal before reporting success, and
never fabricates a replacement workspace or closes/quits the window.

### 62–67. Settings-package shortcut registration + secret 0600 write

- **62. `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift`** — five
  fences register the supermux actions in the settings-package enum (the app-target registration
  in #11/#23/#37 alone does not surface them in the Settings UI or its conflict detection):
  `run-toggle-shortcut-case`, `workspace-switcher-shortcut-case`, `supermux-commit-shortcut-case`
  (reused ids) add the five cases; `supermux-shortcut-groups` places them in the Settings groups;
  `supermux-shortcut-display-names` adds the display names.
- **63. `…/ShortcutAction+Defaults.swift`** — `supermux-shortcut-defaults` mirrors the five
  default strokes (⌘G, ⌘\`, ⇧⌘\`, ⌘↩, ⇧⌘↩) from `Sources/KeyboardShortcutSettings.swift`. Both
  tables must agree; the drift test in #66 enforces it.
- **64/65. `…/Stores/SecretFileStore.swift` + `…/Tests/CmuxSettingsTests/SecretFileStoreTests.swift`**
  — `secret-file-0600-write` writes the secret to a temp file created at mode 0600 and
  `rename(2)`s it into place, removing the chmod-after-write exposure window for the AI gateway
  key; the test fence is the regression coverage.
- **66. `cmuxTests/KeyboardShortcutContextTests.swift`** — `settings-package-shortcut-action-drift`
  fails when an app-target shortcut action is unmapped in the package enum and asserts the five
  supermux actions align across both tables.
- **67. `web/data/cmux-shortcuts.ts`** — `supermux-commit-shortcut-doc` adds the two commit rows
  (⌘↩ / ⇧⌘↩, Changes panel) to the diff-viewer section of the shortcut registry.

Whole-file supermux-owned package tests #68/#69 need no fences; they are registered so the check
guards their existence. Budget: the package files stay under the 500-line threshold, so only the
app-target files in the #4 table carry bumps.

### 73. `Sources/DragOverlayRoutingPolicy.swift` — `browser-hover-drag-guard`

**Symptom:** hovering in the embedded browser stops working (CSS `:hover` states, hover
menus, tooltips, link highlights stop responding) after the user drags a pane tab or a
sidebar tab.

**Cause (upstream cmux bug).** `DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting`
returns `true` for hover-type events (`mouseMoved`/`cursorUpdate`/`mouseEntered`/`mouseExited`)
whenever the `.drag` pasteboard carries a Bonsplit/sidebar tab-transfer type. That branch
exists so an in-flight tab drag over the browser passes through to the SwiftUI/Bonsplit drop
targets behind the `WindowBrowserHostView` portal (a tab drag surfaces as hover/cursor events
with no pressed-button bit on the event). But the `.drag` pasteboard keeps its declared types
after a drag *ends* — nothing clears it in production — so a stale tab-transfer payload makes
every later hover pass through the portal, routing `mouseMoved` past the `WKWebView`. The
browser portal is the only portal that routes `.pointerHover` (the terminal portal gates on
`.pointerDrag`), which is why the bug is browser-specific.

**Fix.** Add a defaulted `pressedMouseButtons: Int = NSEvent.pressedMouseButtons` parameter and
gate only the `.pointerHover` case on the left button actually being held
(`(pressedMouseButtons & 1) != 0`). A real drag holds the button, so pass-through still works
during the drag; ordinary post-drag hover (button up) reaches the web view again. Both the
parameter and the guard are fenced. The defaulted parameter keeps every existing call site
(`WindowBrowserHostView.shouldPassThroughToDragTargets`, and
`shouldPassThroughTerminalPortalHitTesting`) unchanged while making the gate injectable for the
regression test. If upstream restructures this function or fixes the staleness itself, drop the
fence and take upstream's fix. History note: this fix originally landed as fcb443d8df and was
lost when that commit was undone (only its ⌘G-routing and link-in-new-tab parts were re-landed
in 544bdc1d5d). Regression test: `cmuxTests/PortalTabDragRoutingTests.swift` →
`testBrowserPortalDoesNotPassHoverThroughWithoutPressedMouseButton` (see #75).

### 74–75. `Sources/Panels/BrowserPanelView.swift` + tests — `browser-hover-webkit-topmost-gate`

**Symptom:** hover never works in embedded browser panes — no CSS `:hover`, no cursor changes
(pointer over links, I-beam over text), no tooltips — while clicks, scrolling, and typing all
work. Reproduces on every freshly opened browser tab.

**Cause (upstream cmux bug, WebKit-version dependent).** Modern WebKit routes macOS hover
through `WKMouseTrackingObserver` (the owner of the WKWebView's tracking areas), whose
`mouseMoved:`/`mouseEntered:` handlers first call `updateViewIsTopmostAtMouseLocation:`:

```objc
RetainPtr hitView = [[view window].contentView hitTest:
    [[view window].contentView.superview convertPoint:event.locationInWindow fromView:nil]];
_viewIsTopmostAtLastMouseLocation = [hitView isDescendantOf:view.get()];
```

WebKit forwards the event to the page only when the **window contentView's** hit test resolves
to the web view or one of its descendants. cmux hosts browser web views in the window-level
portal (`WindowBrowserHostView`), which `WindowContentOverlayTargetResolver` installs on the
window **theme frame, outside the contentView subtree**. `contentView.hitTest` therefore
resolves to the SwiftUI-side geometry anchor (`WebViewRepresentable.HostContainerView`) instead
of the web view, the gate never passes, and WebKit silently drops every hover event.

**Fix.** The anchor delegates hover-time hit tests to the portal-hosted web view. Two fences in
`Sources/Panels/BrowserPanelView.swift`:

1. In `WebViewRepresentable.HostContainerView`: a `weak var portalHoverHitTestWebView: WKWebView?`,
   a `portalHoverRoutingContextOverride` test seam (`hitTest` cannot receive a routing context, so
   it reads `NSApp.currentEvent` unless a test injects one), and
   `portalHoverDelegationTarget(at:routingContext:pressedMouseButtons:dragPasteboardTypes:)`.
   The helper returns the hosted page web view only when ALL of these hold, in order:
   - the routing context is `.pointerHover` (real event routing — clicks, drags, scroll — is
     handled by the portal host above the contentView and never consults the anchor);
   - the web view is hosted in this window (not hidden, has a superview);
   - no tab drag is in flight: if the left button is held AND
     `DragOverlayRoutingPolicy.shouldPassThroughPortalHitTesting` says the drag pasteboard
     carries a tab-transfer payload, the hit test must keep resolving to the Bonsplit/sidebar
     drop targets behind the portal (which the portal host deliberately passes through to), so
     the anchor returns nil. The pasteboard is only read while the button is held, keeping
     plain hover cheap;
   - the web view is actually topmost within its slot at the point: the helper hit-tests the
     slot (`webView.superview`), which resolves the find-bar / omnibar-suggestion overlays
     layered above the web view via each overlay's own hit-test gating. Requires #77 so a stale
     drag payload can't make the slot's invisible drop target swallow this check.
   `hitTest` consults the helper after the sidebar-resizer and hosted-inspector-divider
   branches, before `super.hitTest`. The docked-DevTools frontend needs no delegation: DevTools
   docking forces local inline hosting, where both web views sit inside the anchor's subtree.
2. In `WebViewRepresentable.updateNSView`: one line keeping `portalHoverHitTestWebView` pointed
   at the panel's current web view in window-portal hosting mode, and `nil` in local inline
   hosting (where `super.hitTest` already resolves the web view naturally).

If upstream restructures the anchor or the portal, the requirement is: a hit test rooted at
`window.contentView` over visible browser page area must resolve to the hosted `WKWebView` (or a
descendant) for hover-kind events — and must NOT do so while a tab drag is in flight or where a
slot overlay occludes the page. Regression test: `cmuxTests/PortalTabDragRoutingTests.swift` →
`testBrowserAnchorDelegatesHoverHitTestToPortalHostedWebView` (fenced, see #75).

### 76–79. Sibling guards + fork-contract test updates — `browser-hover-drag-guard`

The #73 policy change ripples into three sibling surfaces; all four edits share the
`browser-hover-drag-guard` fence id:

- **`Sources/BrowserWindowPortal.swift` (#76):** `WindowBrowserHostView.shouldPassThroughToDragTargets`
  gains a defaulted injectable `pressedMouseButtons` forwarded to the policy, mirroring #73's
  seam so the wrapper-level tests in #78 are deterministic. A fenced comment at the hover
  pass-through call site records that the policy now gates hover-kind pass-through on the
  physically held button (upstream's comment alone reads as if button state is ignored).
- **`Sources/BrowserPaneDropTargetView.swift` (#77):** `shouldCaptureHitTesting` gains the same
  defaulted `pressedMouseButtons` plus a guard: hover-kind events with no left button held never
  capture. Without it, a stale tab-transfer/file payload makes the slot's invisible, frontmost
  drop target claim every post-drag hover-time hit test inside the slot (misrouting cursor
  updates/tooltips away from the web view and find bar) and would defeat #74's slot-topmost
  check. Drop delivery (`pointerUp`) and in-flight drag events are unaffected.
- **`cmuxTests/BrowserPanelTests.swift` (#78):** upstream's
  `testDragHoverEventsPassThroughForTabTransferOnBrowserHoverEvents` and
  `testDragHoverEventsPassThroughForSidebarReorderWithoutMouseButtonState` asserted exactly the
  stale-hover pass-through #73 removes (they fail deterministically on CI where
  `NSEvent.pressedMouseButtons == 0`). Both are fenced and updated to the fork contract
  (pass-through with button held, no pass-through without); the second is renamed
  `testDragHoverEventsPassThroughForSidebarReorderOnlyWhileMouseButtonHeld`.
- **`cmuxTests/BrowserPaneDropRoutingTests.swift` (#79):**
  `testHitTestingCapturesOnlyForRelevantDragEvents` injects `pressedMouseButtons: 1` so it keeps
  testing payload filtering, and the new
  `testHitTestingDoesNotCaptureStaleHoverWithoutPressedMouseButton` pins #77.

If upstream fixes the drag-pasteboard staleness at the source (clearing it when a drag ends),
drop all `browser-hover-drag-guard` fences and take upstream's fix; the #75/#78/#79 tests tell
you whether the symptom is truly gone.

### 80. `Sources/TabManager.swift` — `new-workspace-home-dir`

In `implicitWorkingDirectoryForNewWorkspace(from:)`, the `guard` on the
`app.workspaceInheritWorkingDirectory` setting used to `return nil` when the setting is off.
Replace that `return nil` with a fenced explicit home-directory return:

```swift
guard settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory) else {
    // SUPERMUX:begin new-workspace-home-dir
    // Returning nil here still inherits: the surface spawns with no
    // explicit cwd and Ghostty's own tab-inherit-working-directory
    // (default on) reuses the focused surface's pwd. Pin the home
    // directory explicitly so turning the setting off takes effect.
    return FileManager.default.homeDirectoryForCurrentUser.path
    // SUPERMUX:end new-workspace-home-dir
}
```

Why: every plain new-workspace entrypoint (sidebar empty-area double-click, sidebar `+`,
⌘N, palette) funnels into `addWorkspace`, which passes this value down to the initial
`TerminalPanel` → `ghostty_surface_new`. When it is nil, `apprt.surface.newConfig` in the
ghostty submodule copies the previously focused surface's pwd into the new surface's config
(`tab-inherit-working-directory` defaults to true), so the cmux-level setting appeared to do
nothing. Regression coverage: `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift`
(pbxproj IDs `50BE0001…00D1`/`…00D2`, see #3).

Second consumer, on purpose: `addWorkspace(fromDetachedSurface:)`
(`Sources/TabManager+DetachedWorkspace.swift:38`) also calls
`implicitWorkingDirectoryForNewWorkspace` as the fallback behind `detached.directory`, so
with the setting off a detach-drop without a transfer directory now gets the explicit home
pin instead of nil. That is observationally identical today — `Workspace.init` already
displayed home as `currentDirectory` when `workingDirectory` was nil — which is why
upstream's unfenced tests `testDisabledInheritanceLeavesDetachedWorkspaceFallbackCwdUnset…`
and `testDetachedWorkspaceTransferDirectoryWinsWhenInheritanceIsDisabled`
(`cmuxTests/WorkspaceUnitTests.swift` ~3084/3105) keep passing unmodified; if an upstream
merge changes those tests or the nil-cwd display fallback, re-check this path.

The behavior change ripples into these sibling surfaces (fenced ones share the
`new-workspace-home-dir` id):

- **`cmuxTests/WorkspaceUnitTests.swift` (#81):** upstream's
  `testDisabledInheritanceLeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback` asserted
  `requestedWorkingDirectory == nil` — exactly the contract #80 replaces. It is fenced,
  renamed `testDisabledInheritancePinsNewWorkspaceCwdToHomeDirectory`, and asserts
  `FileManager.default.homeDirectoryForCurrentUser.path`. The plain-path sibling tests
  (inherit-on, explicit per-call `inheritWorkingDirectory: false`, explicit-override) are
  untouched; the two detached-path disabled-inheritance tests are also untouched but their
  mechanism changed (see the second-consumer note above).
- **`Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AppSection.swift` (#82):**
  the toggle's OFF subtitle `defaultValue` becomes "New workspaces always start in your home
  directory." (fenced around the `:` branch of the subtitle ternary).
- **`cmuxUITests/SettingsAppBehaviorUITests.swift` (#83):** `Subtitle.inheritOff` must match
  the #82 `defaultValue` verbatim or `testInheritWorkingDirectoryToggleSwapsSubtitle` fails.
- **`Resources/Localizable.xcstrings` (#4b, unfenced):** the en+ja values of
  `settings.app.workspaceInheritWorkingDirectory.subtitleOff` are rewritten to match
  (en: "New workspaces always start in your home directory."; ja:
  "新規ワークスペースは常にホームディレクトリで開始します。"), and the en+ja values of
  `settings.search.alias.setting.app.workspace-inherit-working-directory` swap
  `ghostty`/`Ghostty` for `home`/`ホーム` (#84).
- **`Sources/SettingsSearchAliases.swift` (#84) and `Sources/SettingsNavigation.swift`
  (#85):** the settings-search keywords for the toggle drop the stale `ghostty` term for
  `home`.
- **`web/data/cmux.schema.json` (#14, unfenced):** the `workspaceInheritWorkingDirectory`
  description's "when false" clause becomes "new workspaces always start in the home
  directory.", plus a `descriptionKey` pointing at
  `schemaDescriptions.app.workspaceInheritWorkingDirectory` in `web/messages/en.json` (#86)
  and `web/messages/ja.json` (#87) so the docs configuration page localizes it.
- **`skills/cmux-settings/references/all-keys.md` (#88, unfenced):** the generated
  description row is refreshed from the schema.

Deliberate trade-off: with the setting off, a user-configured Ghostty `working-directory`
config value is now overridden by the home pin even at first launch (the one case upstream's
nil fallback genuinely honored it). "Off = always home" is the fork's product decision.

If upstream ever fixes the inheritance leak itself (e.g. passing an explicit cwd or a
no-inherit flag to `ghostty_surface_new` when the setting is off), drop all
`new-workspace-home-dir` fences and take upstream's fix; the #81 test and
`SupermuxNewWorkspaceHomeDirectoryTests` tell you whether the symptom is truly gone.

## iOS / mobile sync

### 89. `ios/cmuxUITests/cmuxUITests.swift` — `uitest-ticket-compat-version`

The XCUITest mock-host harness (`launchConnectedApp` → `attachURL(port:)`) builds a
`CmxAttachTicket` fixture for the in-runner `MobileSyncMockHostServer` and injects it via
`CMUX_UITEST_ATTACH_URL`. Upstream's fixture omits `macPairingCompatibilityVersion`, but
`CmxAttachTicketInput.decode` normalizes a missing compat version to `0`
(`withUnknownCompatibilityVersionForPairingURL`), and
`MobileShellComposite.versionWarning(for:)` treats `0 != CmxMobileDefaults.pairingCompatibilityVersion`
as a cross-compatibility pairing → `connectPairingURLResult` returns `.needsUserApproval` and the
app parks behind a `MobilePairingVersionWarning` sheet ("Continue anyway") that no test ever taps.
Every connection-dependent cmuxUITest (9 of 12) then times out waiting for
`MobileWorkspaceRow-workspace-main` / `MobileTerminalSurface`.

This is an upstream-latent test-fixture bug, not app misbehavior: every real Mac-minted ticket
carries the compat level (`MobileHostService` passes
`macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion`), and upstream CI
never notices because `.github/workflows/test-ios.yml` runs `-skip-testing:cmuxUITests` on pull
requests ("Full UI tests currently exceed the pull-request simulator budget on macos-26").

The fence adds the one missing argument to the fixture initializer:

```swift
let ticket = try CmxAttachTicket(
    ...
    macDisplayName: "UI Test Mac",
    // SUPERMUX:begin uitest-ticket-compat-version (fixture must carry the compat level like real Mac-minted tickets)
    macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
    // SUPERMUX:end uitest-ticket-compat-version
    routes: [route],
    ...
```

Re-apply note: if upstream adds the compat version to the fixture itself (or removes the
`versionWarning` gate for compat 0), drop this fence and take upstream. If upstream rewrites
`attachURL(port:)`, the requirement is: the UITest fixture ticket must decode with
`macPairingCompatibilityVersion == CmxMobileDefaults.pairingCompatibilityVersion` so the pairing
version warning does not fire under the mock harness.

### 13 (cont.) + 90. `Packages/Shared/SupermuxMobileCore` registration (ci.yml allowlist + workspace group)

`Packages/Shared/SupermuxMobileCore` is the supermux-owned zero-dependency wire-contract package
for the iOS companion app (`mobile.supermux.*` method/topic/capability constants + Codable DTOs +
the `SupermuxWireJSON` Codable↔`[String: Any]` bridge). Two upstream files register it:

- **`.github/workflows/ci.yml` (#13, inside the existing `ci-package-tests` fence):** upstream's
  `PACKAGES=(...)` allowlist in the package-tests job never lists fork packages, so the fence runs
  `swift test --package-path Packages/Shared/SupermuxMobileCore` explicitly (same pattern as
  `Packages/SupermuxKit`). Re-apply: restore the fenced block after the group-agnostic loop; keep
  every fork package the fence tests listed there.
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the Shared group. Re-apply after any merge by running
  `python3 scripts/check-workspace-package-groups.py --write` (the `Packages/` directory layout is
  the source of truth); CI's `--check` fails on drift. Never hand-edit the workspace file.

The package itself is fork-owned (no fences inside it). It intentionally has zero dependencies and
no `Package.resolved` (SwiftPM only writes one when dependencies exist); if it ever gains a
dependency, track the generated package-local `Package.resolved` per repo policy.

### 91–95. Mac host plumbing for `mobile.supermux.*` (dispatch, authz, capabilities, observers, wiring)

The Mac side of the iOS supermux parity plane. All logic lives in fork-owned files
(`Sources/Supermux/TerminalController+SupermuxMobile.swift`, `SupermuxMobileHost+Projects.swift`,
`SupermuxMobileAuthorization.swift`, `SupermuxMobileCapabilities.swift`,
`SupermuxMobileObservers.swift`, and `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/`); four
1–3-line fences hook it into upstream:

- **`Sources/TerminalController.swift` (#91, `mobile-supermux-dispatch`):** one
  `case let method where method.hasPrefix("mobile.supermux."):` in the `mobileHostHandleRPC`
  switch, placed right after the `mobile.chat.` prefix case. Re-apply: keep it anywhere in that
  switch before `default:`; the router body is fork-owned.
- **`Sources/Mobile/MobileHostService.swift` (#92, `mobile-supermux-authz`):** a 3-line guard in
  `ticketAuthorizationError(authorization:request:)` — AFTER the workspace/terminal alias and
  conflict guards (they must keep applying to supermux methods) and BEFORE upstream's method
  switch — returning `SupermuxMobileAuthorization.ticketError(method:params:ticket:)` for the
  whole prefix. The fork table fails closed (`default:` = scoped-ticket `forbidden`), so a merge
  that drops this fence makes every supermux method hit upstream's own fail-closed `default:` —
  safe, but the phone loses scoped-ticket access; `cmuxTests/SupermuxMobileAuthorizationTests`
  goes red either way.
- **`Sources/Mobile/MobileHostService+Capabilities.swift` (#93, `mobile-supermux-capabilities`):**
  `+ SupermuxMobileCapabilities.advertised` appended to upstream's array literal in
  `mobileHostCapabilities`. Re-apply: any composition that folds the fork list into the returned
  array works; never inline `supermux.*` strings into upstream's literal.
- **`Sources/AppDelegate.swift` (#94, `mobile-supermux-observers`):**
  `SupermuxMobileHostGlue.activateIfNeeded()` at the top of
  `ensureMobileWorkspaceListObserver(for:)`. Re-apply: the call must run wherever upstream
  constructs `MobileWorkspaceListObserver`, so fork observers exist exactly when the mobile event
  plane is live. Idempotent — safe to call from several sites.
- **`cmux.xcodeproj/project.pbxproj` (#95, unfenced):** `SupermuxMobileCore` local package
  reference + product dependency (cmux + cmuxTests targets), the `Sources/Supermux/` mobile
  files (see the #95 table row for the current list) in the cmux target, and
  `cmuxTests/SupermuxMobileAuthorizationTests.swift`,
  `cmuxTests/SupermuxMobileObserversTests.swift`,
  `cmuxTests/SupermuxMobileChangesWatchRegistryTests.swift`, and
  `cmuxTests/SupermuxMobileRunObserverTests.swift` in the cmuxTests
  target. Ids prefixed `50BE0002…`; re-add via Xcode or by copying any `50BE0001…` sibling's
  four-entry shape, then run `python3 scripts/normalize-pbxproj.py`.
- **`.github/swift-file-length-budget.tsv` (#4):** rows for `TerminalController.swift` (+4),
  `MobileHostService.swift` (+5), and `AppDelegate.swift` (+3) raised by exactly the fenced growth.

`Packages/SupermuxKit/Package.swift` (fork-owned, no fence) gains a path dependency on
`../Shared/SupermuxMobileCore`; both stay path-only, so still no `Package.resolved` is generated.

### 13 (cont.) + 90 (cont.). `Packages/iOS/SupermuxMobileKit` registration (ci.yml allowlist + workspace group)

`Packages/iOS/SupermuxMobileKit` is the supermux-owned iOS domain layer for the companion app:
the `SupermuxMacCalling` seam (typed `mobile.supermux.*` request/response + event streams), the
production `SupermuxMacClient` adapter over `CmuxMobileRPC`'s `MobileCoreRPCClient`, the
`SupermuxMobileCapabilities` gate (one accessor per `supermux.*.v1`), the etag-keyed
`SupermuxProjectIconCache`, and the `@Observable` phone stores (`SupermuxMobileProjectsStore`).
Dependencies are path-only (`../../Shared/SupermuxMobileCore`, `../CmuxMobileRPC`), so no
`Package.resolved` is generated. Two upstream files register it:

- **`.github/workflows/ci.yml` (#13, inside the existing `ci-package-tests` fence):**
  `swift test --package-path Packages/iOS/SupermuxMobileKit` appended after the SupermuxMobileCore
  entry, same pattern and re-apply note as that entry (restore the fenced block; keep every fork
  package listed).
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the iOS group. Re-apply after any merge by running
  `python3 scripts/check-workspace-package-groups.py --write`; never hand-edit.

The package itself is fork-owned (no fences inside it). Note: the fork packages are included in
`scripts/lint-ios-package-conventions.sh`'s SCOPES via the `lint-ios-conventions-fork-scopes`
fence (#109), so the lint's per-line rules ARE mechanically enforced here; the deliberate
constant/text namespace holders carry inline `/// lint:allow …` justifications.

### 96–98 (+ 13/90 cont.). iOS Projects section (`Packages/iOS/SupermuxMobileUI` + shell mount)

`Packages/iOS/SupermuxMobileUI` is the supermux-owned iOS screens package for the companion app
(deps, all path-only: `SupermuxMobileKit`, `SupermuxMobileCore`, and `CmuxMobileRPC` — the latter
declared directly so the shell's typed `(rpcClient: MobileCoreRPCClient, …)` seam can be named in
the driver API; no `Package.resolved` is generated). It owns its `Resources/Localizable.xcstrings`
(every `supermux.*` key localized in BOTH `en` and `ja`; a package test parses the catalog and
fails on any missing/empty translation) and contains `SupermuxProjectsSectionModel` (one
`SupermuxMobileProjectsStore` per connection session), the value-snapshot types
(`SupermuxProjectsSectionSnapshot` / `SupermuxProjectRowSnapshot` / `SupermuxProjectsSectionActions`),
`SupermuxProjectsMobileSection` (collapsible section; rows = custom icon → SF symbol → letter
avatar tinted by `color_hex`), the read-only `SupermuxProjectDetailScreen`, and the
`supermuxProjectsSectionDriver` view extension. Upstream touchpoints:

- **`MobileShellComposite.swift` (#96, `supermux-mobile-client-mount`):** the 3-line computed
  `supermuxConnectionSeam` next to `remoteClientForAgentChat`. Re-apply: any placement inside the
  class works; it must read `connectionState`, `remoteClient`, and `supportedHostCapabilities`
  (all observation-tracked) and return `nil` unless `.connected`. Raise the
  `.github/swift-file-length-budget.tsv` row by the fenced growth (+5).
- **`WorkspaceListView.swift` (#97, `supermux-mobile-projects-section`, four 1-line fences):**
  the import; `@State private var supermuxProjects = SupermuxProjectsSectionModel()`;
  `SupermuxProjectsMobileSection(section: supermuxProjects.snapshot, actions: supermuxProjects.actions)`
  as the first section-level entry before the workspaces `Section` (below the connection-status
  rows); `.supermuxProjectsSectionDriver(model: supermuxProjects, connection: store?.supermuxConnectionSeam)`
  directly on the `List` (NOT inside it — the driver's `.task(id:)` must live on a stable view).
  Re-apply: keep the mount above the workspace/group sections and the driver on the `List`.
- **`Packages/iOS/CmuxMobileShellUI/Package.swift` (#98, `supermux-mobile-shellui-deps`):** the
  package + target dependency lines. Re-apply: both lines, same fence id.
- **`.github/workflows/ci.yml` (#13, inside the existing `ci-package-tests` fence):**
  `swift test --package-path Packages/iOS/SupermuxMobileUI` appended after the SupermuxMobileKit
  entry (same pattern; restore the fenced block, keep every fork package listed).
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the iOS group. Re-apply with `python3 scripts/check-workspace-package-groups.py --write`;
  never hand-edit.

Same `lint-ios-package-conventions.sh` coverage as SupermuxMobileKit above (the #109
`lint-ios-conventions-fork-scopes` fence adds the fork packages to SCOPES).

### 99–103. Workspace-list augmentation (§6: `supermux_project_id` / `supermux_activity`)

The Mac merges two ADDITIVE, optional fields into every `workspace.list` workspace payload and the
phone folds project-owned rows under the Projects section, shows agent-activity dots, and lists a
project's open workspaces inside `SupermuxProjectDetailScreen`. Field computation is fork-owned and
package-tested (`SupermuxMobileWorkspaceFields` in `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/`,
RPC-WSL-01 suite `SupermuxMobileWorkspaceFieldsTests`); the app-target adapter
`Sources/Supermux/SupermuxMobileWorkspaceListAugmenter.swift` feeds it the ONE shared activity
resolution (`SupermuxWorkspaceActivityResolver`) and the sidebar's association resolution
(`SupermuxWorkspaceAssociationStore.projectId(forWorkspace:directory:in:)`), so the phone and the
Mac sidebar can never disagree. Both fields travel only for project-associated workspaces; an
idle associated workspace carries the project id alone. `Sources/Supermux/SupermuxMobileActivityObserver.swift`
re-emits the EXISTING `workspace.updated` topic (payload `[:]`, trailing 80 ms throttle) on agent
lifecycle changes (`SupermuxWorkspaceLifecycleRelay`) and association/projects changes
(Observation-tracked summary hash) — upstream's `MobileWorkspaceListObserver.summaryHash` is
deliberately untouched. The host now also advertises `supermux.activity.v1`.

- **`Sources/TerminalController+MobileWorkspaceList.swift` (#99, `mobile-supermux-workspace-fields`):**
  re-apply by rebinding upstream's returned literal (`return [` → `let payload: [String: Any] = [`)
  inside the first fence block and returning `SupermuxMobileWorkspaceListAugmenter.augment(payload,
  workspace: workspace)` in the second. If upstream restructures `mobileWorkspacePayload`, the
  requirement is: the augmenter wraps the final per-workspace dictionary on every payload path.
- **`MobileSyncWorkspaceListResponse.swift` (#100) / `MobileWorkspacePreview.swift` (#101) /
  `MobileWorkspacePreview+RemoteMapping.swift` (#102, all `supermux-mobile-workspace-fields`):** the
  decode → preview plumbing. All three additions are optional/defaulted so upstream inits, tests,
  and old payloads are untouched; `PROTO-03` regression suite
  `SupermuxWorkspaceListFieldsDecodeTests` (CmuxMobileRPCTests) locks the wire shape both ways.
  The aggregated multi-Mac path needs no fence: `derivedWorkspaces` mutates copies
  (`var stamped = workspace`), which carries the new fields automatically.
- **`WorkspaceListView.swift` (#103, `supermux-mobile-hide-project-workspaces` +
  `supermux-mobile-row-activity`):** the hide filter must stay gated on
  `supermuxProjects.snapshot.isVisible && trimmedQuery.isEmpty && !filter.isActive` so rows never
  become unreachable while disconnected/upstream-paired and never unsearchable; only LOOSE
  (ungrouped) project-owned rows hide, mirroring the Mac's `SupermuxProjectResolutionCache.filter`.
  The dot modifier attaches to `WorkspaceNavigationRow` before the row insets. The #97 driver fence
  gained `workspaces:` + `selectWorkspace:` arguments (pass the shell's closure as a literal —
  `{ selectWorkspace($0) }` — because `@MainActor` function types are implicitly `@Sendable` and a
  stored plain closure won't convert).

`Packages/iOS/SupermuxMobileUI` additions are fork-owned (no fences): the `supermuxFlatRows` array extension (SupermuxWorkspaceListPartition.swift),
`SupermuxProjectWorkspaceRowSnapshot`, `SupermuxWorkspaceActivityDot` (palette mirrors the Mac's
`SupermuxActivityPalette`), the section model's open-workspace join, and the detail screen's real
Workspaces section. Its `Package.swift` gained a path dep on `../CmuxMobileShellModel` (target +
test target) so the partition/mapping can name `MobileWorkspacePreview`. New localization keys
`supermux.activity.working/needsInput/ready` exist in BOTH en and ja in the package catalog.

### 104–105. XCUITest paired-Mac state hygiene (`uitest-clear-paired-mac-state` / `-launch`)

Since #89 fixed the mock-host connect flow, XCUITest pairings actually complete and the app
persists the paired mock Mac in `Application Support/cmux/paired-macs.sqlite3` inside the shared
simulator app container (`/tmp/cmux-ios-readiness` runs reuse the same "iPhone 17" device). That
state leaked across tests and runs: `testAddDeviceManualHostValidationUsesStableIdentifiers` and
`testAddDevicePairButtonStaysVisibleWhenKeyboardOpens` launched onto `MobileWorkspaceShell` with a
dead-host reconnect error instead of the `MobileAddDeviceForm` they expect (cmuxUITests.swift:586),
and `testWorkspaceToolbarCreatesWorkspaceAndTerminal` had its navigation disrupted by stale-pairing
reconnect churn (cmuxUITests.swift:245, then a runner crash + 600s diagnostics timeout).

Two fences make every harness launch start from an unpaired slate, siblings of the existing
`CMUX_UITEST_CLEAR_AUTH` reset path:

- **`ios/cmux/AppCompositionRoot.swift` (#104, `uitest-clear-paired-mac-state`):** at the top of
  `AppCompositionRoot.init` (runs exactly once per process, before `CMUXMobileRootScene` opens
  `MobilePairedMacStore`), when `UITestConfig.mockDataEnabled` AND
  `CMUX_UITEST_CLEAR_PAIRED_MACS=1`, remove the `Application Support/cmux` directory (`try?`, so a
  missing directory is a no-op). Do NOT move this into `CMUXMobileRootScene.init` — that view is
  re-initialized on body re-evaluation and would delete a freshly persisted pairing mid-session.
- **`ios/cmuxUITests/cmuxUITests.swift` (#105, `uitest-clear-paired-mac-launch`):** one line in
  `launchApp` right after the `CMUX_UITEST_MOCK_DATA` assignment sets
  `CMUX_UITEST_CLEAR_PAIRED_MACS=1` for every harness launch.

Re-apply note: if upstream adds its own persisted-pairing reset hook (or erases the simulator per
run in CI), drop both fences and take upstream. Otherwise the requirement is: every mock-harness
launch must start with no persisted paired Mac, the clear must run before the paired-Mac store is
opened, exactly once per process, and must never fire outside the DEBUG mock harness
(`UITestConfig.mockDataEnabled` gates it; real installs never see the env var). Tests must NOT be
weakened to tolerate leaked pairing state instead.

### 106. `ios/cmuxUITests/cmuxUITests.swift` — `uitest-new-workspace-menu-item`

`testWorkspaceToolbarCreatesWorkspaceAndTerminal` tapped `app.buttons["MobileTerminalNewWorkspaceButton"]`,
but in this upstream snapshot the iOS `WorkspaceDetailView.toolbar` mounts only
`glassTitle` + `chatToggleButton` + `terminalPickerToolbarButton` in `topBarTrailing`;
`newWorkspaceToolbarButton` (which carries that identifier) sits solely in the non-iOS `#else`
branch. On iOS the New Workspace action lives in the terminal dropdown menu as
`MobileNewWorkspaceMenuItem` (`terminalPickerMenuContent`). The test therefore failed
deterministically at cmuxUITests.swift:245 even from a clean pairing slate — this is test/UI
drift, not the #104/#105 state leakage (upstream PR CI skips cmuxUITests, so upstream never saw
it; a NEWER upstream restores a nav-bar new-workspace button alongside `MobileWorkspaceBackButton`
/ `MobileWorkspaceTitleMenu`).

The fence swaps the single tap for the same two-step pattern the test already uses for New
Terminal (`MobileTerminalDropdown` → `tapMenuItem`), leaving every behavioral assertion
(`assertHostSelection` for `workspace-3`/`workspace-3-terminal-1`, terminal menu-item existence,
new-terminal flow) untouched:

```swift
// SUPERMUX:begin uitest-new-workspace-menu-item (this snapshot's iOS mounts New Workspace in the terminal dropdown, not a nav-bar MobileTerminalNewWorkspaceButton)
tap(app.buttons["MobileTerminalDropdown"], in: app)
tapMenuItem(app.buttons["MobileNewWorkspaceMenuItem"], in: app)
// SUPERMUX:end uitest-new-workspace-menu-item
```

Re-apply note: on the next upstream merge, take upstream's version of this test wholesale and
drop this fence — upstream's newer UI re-adds a nav-bar create button and rewrites the test
around `MobileWorkspaceBackButton`/`MobileWorkspaceTitleMenu`. The requirement while this
snapshot's UI stands: the test must drive New Workspace through a control that actually exists on
iOS, without weakening the mock-host `workspace.create`/selection assertions.

### 107. `scripts/check-package-resolved-policy.py` — `fix-resolved-policy-path-deps`

Upstream's POL-03 gate diffs `merge-base(origin/main, HEAD)..HEAD` and, whenever a manifest in a
tracked lockfile's dependency closure changed its `.package(…)` calls, demands a diff in that
`Package.resolved`. That demand is unsatisfiable for PATH-ONLY dependency changes: SwiftPM never
records `.package(path:)` dependencies in any lockfile, so `swift package resolve` rewrites
nothing and no legitimate lockfile diff can exist. The fork's new path-only packages
(`SupermuxMobileCore/Kit/UI` + the fenced `CmuxMobileShellUI` path dep) made the script exit 1 at
HEAD with no possible fix on the lockfile side.

Three fence blocks, all sharing the `fix-resolved-policy-path-deps` id:

- **`lockfile_recorded_dependency_calls(calls)`** (module-level helper): filters dependency calls
  down to those SwiftPM records in a lockfile — a call counts as recorded when it has a `url:`
  argument or has no `path:` argument (registry/url pins), so path-only calls are excluded.
- **`main`'s changed-roots loop:** after the existing `current_calls == previous_calls`
  short-circuit, also `continue` when the *lockfile-recorded* calls are unchanged between
  merge-base and HEAD. A brand-new path-only manifest reads as `previous_calls == []` with zero
  recorded calls on both sides, so it passes; any added/removed/edited `url:` pin still differs
  and still requires lockfile churn (verified: a scratch commit adding
  `.package(url: …, from: …)` to `CmuxMobileShellUI/Package.swift` without lockfile churn exits
  1 naming both affected lockfiles, and exits 0 once the lockfiles are touched in the same range).
- **`file_text_at`:** runs `git show` with stderr suppressed and returns `""` on failure, because
  a manifest new since the merge-base has no blob at that ref — expected, previously leaked
  `fatal: path … exists on disk, but not in <merge-base>` noise into the check output.

Re-apply note: if upstream rewrites the script, re-apply by keeping the invariant "a manifest
dependency change requires a lockfile diff only if the change is visible to Package.resolved
(url/registry pins)". If upstream ships its own path-dep exemption, drop all three fences and
take upstream. Do NOT weaken the pinned-dependency protection: url-pin changes without lockfile
churn must keep failing (re-run the scratch-worktree red/green check above after any merge).
Note: the policy script has NO automated tests in-repo — the scratch-worktree red/green check
described above is the only verification of this fence's behavior, so it must be repeated by
hand after any merge that touches the script.

### 108. `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` — `supermux-mobile-workspace-tools`

The iOS Changes AND Files screens' mount point (architecture §7: workspace-detail toolbar
entries). All logic is fork-owned in `Packages/iOS/SupermuxMobileUI`
(`SupermuxWorkspaceTools.swift` — the `supermuxWorkspaceTools` view modifier + capability gates
— plus `SupermuxChangesScreen` / `SupermuxDiffScreen` / `SupermuxFileBrowserScreen` and their
`SupermuxMobileKit` stores `SupermuxMobileChangesStore` / `SupermuxMobileFileBrowserStore`). Two
1-line fences, same fence id:

- the `import SupermuxMobileUI` in the import block;
- `.supermuxWorkspaceTools(connection: store.supermuxConnectionSeam, workspaceID:
  workspace.id.rawValue, workspaceName: workspace.name)` on the outer `Group` in `body`, BEFORE
  `.mobileConnectionRecoveryOverlay` — the outer Group so the toolbar entry rides every detail
  branch (terminal / browser / chat) and survives upstream reshuffles of the inner `.toolbar`
  blocks.

The modifier adds `topBarTrailing` toolbar buttons (each hidden unless the #96 seam is connected
AND the host advertises its capability — `supermux.changes.v1` for Changes, `supermux.files.v1`
for Files; an upstream Mac renders exactly today's UI) and `.sheet`s presenting
`SupermuxChangesScreen` / `SupermuxFileBrowserScreen`; one store is built per presentation from
the seam's `MobileCoreRPCClient` + capability snapshot (the file browser rooted
`.workspace(id:)`). `.github/swift-file-length-budget.tsv` row for `WorkspaceDetailView.swift`
raised by exactly the fenced growth (878 → 884). The m5-f2 Files entry changed only the
fork-owned modifier — the upstream fence lines are byte-identical to m3.

Re-apply note: if upstream rewrites `WorkspaceDetailView`, the requirement is: the modifier must
sit on a view that (a) is inside the detail's `NavigationStack` context so the toolbar item lands
in the nav bar, and (b) has `store` + `workspace` in scope, with `store.supermuxConnectionSeam`
read inside `body` so Observation re-evaluates on (re)connect/capability arrival. Any placement
satisfying that works; keep both fence lines and the budget row in sync.

### 109. `scripts/lint-ios-package-conventions.sh` — `lint-ios-conventions-fork-scopes`

Upstream's iOS conventions lint (run by the `package-conventions-lint` job in
`.github/workflows/test-ios.yml` whenever `ios/` or `Packages/` files change) builds its SCOPES
from globs that never match the fork's mobile packages (`Packages/iOS/CmuxMobile*` misses
`Packages/iOS/SupermuxMobile*`). One fenced 3-line loop after upstream's SCOPES loop appends
`Packages/Shared/SupermuxMobileCore` and `Packages/iOS/SupermuxMobile*`, so the per-line rules
(singleton/Combine/lock/timer/KVO/free-function/namespace-enum) are mechanically enforced on the
fork packages too. The repo-wide namespace-type rule already scanned them regardless of SCOPES.

The fork packages' deliberate constant/text namespace holders (`SupermuxWireErrorCode`,
`SupermuxChangesSyncDeadline`, `SupermuxFileName`, `SupermuxFileOpErrorText`,
`SupermuxProjectStyle`, `SupermuxWorkspaceTools`, `SupermuxMobileActivityPalette`,
`SupermuxEditorErrorText`, `SupermuxFolderPickerPath`) carry inline `/// lint:allow …`
justifications following the lint's own sanctioned-exception mechanism (precedent:
`CmxPairingURLScheme`, `AutoNamingAgentCatalog`).

Re-apply note: re-add the fenced loop directly after upstream's `SCOPES=()` construction — any
placement that appends the fork package directories to `SCOPES` before the first `scan` call
works. If upstream generalizes its globs to cover fork packages (or switches to scanning all of
`Packages/`), drop the fence and take upstream. After re-applying, run
`./scripts/lint-ios-package-conventions.sh` and expect exit 0; new ERROR findings in fork
packages must be fixed or carry a reviewed inline `lint:allow` justification — never grow
`scripts/lint-namespace-types-baseline.txt` (that list may only shrink).

### 110. `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` — `supermux-mobile-hide-search`

Removes the main workspace list's search bar (iOS 26 places `.searchable` in the bottom
toolbar on iPhone) per direct user feedback on the shipped app. The fence is comment-only: it
REPLACES upstream's single `.searchable(text: $searchText)` modifier line on the `List` (right
after `.mobileInlineNavigationTitle()`), leaving nothing between begin/end. All of upstream's
search plumbing (`@State searchText`, `trimmedQuery`, `matchesQuery`, the search branch of
`rendersGroupedSections`, and the #103 hide-filter's `trimmedQuery.isEmpty` gate) stays
untouched and compiles; with `searchText` permanently empty it is simply inert.

Recorded trade-off: the search field was the only free-text way to find a workspace across
groups on the phone; the Unread filter, machine filter, and group sections remain. If the user
later wants search back, delete this fence and restore the one upstream line.

Re-apply note: after an upstream merge, find the workspace `List`'s `.searchable(text:
$searchText)` (or successor search-scope API) in `WorkspaceListView.body` and replace exactly
that modifier line with this fence. If upstream ever makes other behavior depend on a non-empty
`searchText` being reachable, re-evaluate with the user before keeping the removal.
