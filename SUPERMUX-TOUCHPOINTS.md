# Supermux touchpoints — registry of modified upstream files

Every upstream (cmux) file that supermux modifies is listed here. Each modification is fenced in
the file with `SUPERMUX:begin <id>` … `SUPERMUX:end <id>` comments. If an upstream merge
clobbers one, re-apply it from the "How to re-apply" instructions below, then run
`scripts/supermux-check-touchpoints.sh` to verify the registry and the code agree.

Rules for adding a touchpoint:
- Keep it as small as possible — a call into `Packages/SupermuxKit` or `Sources/Supermux` code.
- Fence it: `// SUPERMUX:begin <id>` / `// SUPERMUX:end <id>` (use `<!-- -->` in Markdown/XML).
- Register it in the table AND add a "How to re-apply" entry.
- One row per line. Never let two rows share a line (the checker rejects it) and never put a
  `| N | … |`-shaped table anywhere else in this file — the checker parses every line starting
  `| <digit>` as a registry row. Use bullets or a non-numeric first column in prose tables.
- Numbering: the highest number in use is **414**. Number **351** is unused (the notifications
  redesign started at 352; the pane-unread family uses 386–396 to avoid the mobile-usage
  touchpoints at #340/#340b/#341). Numbers **4, 19, 52, 89, 106, 121, 142** are unused;
  all are documented as RETIRED below except **#19**, which was never assigned (the table jumps
  #18 → #20). Numbers **134** and **135** are each used
  **twice** (`RemoteTmuxMirrorCloseDetachTests` / `ClaudeHookLiveDeliveryTargetTestSupport` and
  two `lint-allow-upstream-debt` rows) — a pre-existing collision, deliberately left as-is so
  existing cross-references keep resolving. Do not reuse them, and do not renumber. Letter
  suffixes (`4b`, `33b`, `62b`) keep a new row adjacent to its family without renumbering.

## Registry

| # | File | Fence id | What it does |
|---|------|----------|--------------|
| 1 | `CLAUDE.md` | `claude-md-pointer` | Points agents at SUPERMUX.md before they work in this repo |
| 244 | `CLAUDE.md` | `ios-dogfood-release-build` | Overrides upstream's "iOS builds open on the iPhone by default" section for this fork: `reload.sh --tag` ships a tagged DEV build the user cannot sign in to, so physical-phone dogfood uses a Release build with `CMUX_DEV_TAG=` empty and `CMUX_IOS_AUTH_ENV=production`. Records the exact invocation — the FIXED dogfood bundle id `com.supermux.ios.dogfood` (one persistent identity so sign-in/pairing survive across tags; per-tag `dev.cmux.ios.<tag>` is retired, and keychain-group sharing with the main install is forbidden — Iroh stores would mutually wipe), `SUPERMUX_IOS_DISPLAY_SUFFIX=" <tag>"`, the sanctioned per-build naming knob (#238/#239) — and the two overrides never to pass on it (`PRODUCT_DISPLAY_NAME`, `ASSETCATALOG_COMPILER_APPICON_NAME`) |
| 2 | `Sources/ContentView.swift` | `sidebar-projects-section`, `sidebar-hide-project-workspaces`, `sidebar-flatrow-activity`, `sidebar-selection-faint`, `sidebar-unified-row-style`, `sidebar-projects-empty-area` | Mounts `SupermuxProjectsMount()` atop the sidebar; hides project-owned workspaces from the flat list and threads a `projectHiddenWorkspaceIds` set through `WorkspaceListRenderContext` — shift-click ranges (`selectWorkspaceRow`) and the actions-bundle Close Other/Below/Above closures exclude project-hidden workspaces (via a fenced parent-level `supermuxProjectHiddenWorkspaceIds()` helper — since upstream's 0.65 snapshot-boundary refactor moved row actions from `TabItemView` to the sidebar owner, the fenced logic lives in those parent functions; Move Up/Down stepping lives in the SHARED entrypoint, #131, so `moveWorkspaceRow` is back to the upstream one-liner), the actions bundle gets a fenced `supermuxMenuVisibility` provider (keyed by workspace id; consumed by #114, declared in #129, move enablement via the #131 stepped-plan check) so the four Move/Close menu items disable on real reachability instead of raw full-list indices, a fenced `.onChange` strips newly project-hidden ids from `selectedTabIds`, the row-input construction computes fenced `supermuxVisibleIndex`/`supermuxVisibleCount` (#132/#133) and `TabItemView.accessibilityTitle` announces "workspace N of M" against the visible list; renders the agent-activity indicator on flat-list workspace rows (indicator overlay in `TabItemView`; snapshot resolution moved to #128); gives the flat-list selection the faint accent tint used by nested project rows in `backgroundColor(for:)` (honoring `sidebarSelectionColorHex` — the user hue at 0.16 opacity — before falling back to `accentColor`); restyles the flat-list row to the nested project-workspace design (`sidebar-unified-row-style`: 11.5·scale title semibold-only-when-selected, spacing-2 line stack, vertical padding 4, corner radius 5, hover tint primary@0.06 via `isPointerHovering`); subtracts the Projects-section height from the empty-area remainder so the sidebar's empty space stays unscrollable |
| 3 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the SupermuxKit package + `Sources/Supermux/` files (incl. `SupermuxRowMenuVisibility.swift`, ids `…00F9`/`…00FA`, `SupermuxWorkspaceReorderStepping.swift`, ids `…00FB`/`…00FC`, and `SupermuxDirectPhonePush.swift`, ids `…0103`/`…0104`) into the cmux target, `cmuxTests/SupermuxSidebarBranchTests.swift` + `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` + `cmuxTests/SupermuxSidebarAgentStatusRowsTests.swift` into the cmuxTests target, and the three `AppIcon*.icon` Icon Composer files into the app Resources phase (see #17; the SupermuxMobile package/test wiring in this file is registered separately as #95) |
| 4b | `Resources/Localizable.xcstrings` | `unfenced` | Adds en+ja entries for all `supermux.*` keys (additive only; never edits non-supermux keys — sole exceptions, all for the #80 fork behavior: the en+ja values of `settings.app.workspaceInheritWorkingDirectory.subtitleOff` (#82) and of `settings.search.alias.setting.app.workspace-inherit-working-directory` (#84) are rewritten). **Additive with one supermux-only exception:** the zeron chat-pane port (#414) DELETED 26 orphaned `supermux.harness.*` keys whose only callers were the ten harness UI files the port removed — see the #4b re-apply note |
| 5 | `Sources/RightSidebarPanelView.swift` | `right-sidebar-changes-mode-*`, `right-sidebar-compact-mode-bar` | Adds the `changes` right-sidebar mode (case/label/symbol/shortcut/rootsync) and renders `SupermuxChangesMount` for it; `right-sidebar-compact-mode-bar` wraps the mode-bar controls in `ViewThatFits` so the mode buttons collapse to icon-only when the sidebar is narrow (keeps the close button visible down to the lowered min width), with a third fallback putting the icon-only row in a horizontal `ScrollView` so mode buttons scroll instead of clipping at extreme narrowness; `right-sidebar-changes-mode-focushost` mounts `SupermuxChangesFocusHostBridge`/`SupermuxChangesFocusHostView` as the changes panel's background, registering a geometry-based focus host with the window's `MainWindowFocusController` |
| 6 | `Sources/RightSidebarMode+Availability.swift` | `right-sidebar-changes-mode-*` | `changes` is always available and reachable from the CLI mode argument |
| 7 | `Sources/RightSidebarToolPanel.swift` | `right-sidebar-changes-mode-*` | `.changes` joins the `.feed, .dock` no-op groups (sync/focus/intent/anchor, ×4) |
| 8 | `Sources/MainWindowFocusController.swift` | `right-sidebar-changes-mode-*` | Focus routing for the changes mode; the `right-sidebar-changes-mode-focushost` fences add a weak `changesHost` + `registerChangesHost(_:)` and changes-ownership checks in `ownsRightSidebarFocus`/`rightSidebarModeOwning`, so commit-field focus maps to the `.changes` intent and the hide path restores terminal focus |
| 9 | `Sources/ContentView+RightSidebarCommandPalette.swift` | `right-sidebar-changes-mode-*` | Palette command id for "Show Changes"; not openable as a pane |
| 10 | `CLI/cmux.swift` | `right-sidebar-changes-mode-*` | CLI accepts `cmux right-sidebar set changes` (and the `changes` alias) |
| 11 | `Sources/KeyboardShortcutSettings.swift` | `run-toggle-shortcut-*` | `supermuxToggleRun` action (case/label/default ⌘G, shared with Find Next) |
| 12 | `Sources/AppDelegate.swift` | `run-toggle-shortcut-*` | ⌘G dispatch: Find Next while find overlay is open, run toggle otherwise; auto-repeat key events are excluded from the run toggle |
| 13 | `.github/workflows/ci.yml` | `ci-package-tests` | Adds `SupermuxKit`, `Packages/Shared/SupermuxMobileCore`, `Packages/iOS/SupermuxMobileKit`, `Packages/iOS/SupermuxMobileUI`, `Packages/Shared/SupermuxClaudeHarness`, and `Packages/Shared/SupermuxZeronUI` to the SPM package-test allowlist so their tests gate CI |
| 14 | `web/data/cmux.schema.json` | `unfenced` | Adds all five supermux ids — `supermuxToggleRun`, `supermuxWorkspaceSwitcherNext`, `supermuxWorkspaceSwitcherPrevious`, `supermuxCommit`, and `supermuxCommitAccelerator` — to the shortcut-action enum so cmux.json validation accepts rebinding them; also rewrites the `workspaceInheritWorkingDirectory` description for the #80 fork behavior (off = always home directory) and gives it a `descriptionKey` (`schemaDescriptions.app.workspaceInheritWorkingDirectory`, messages under #86/#87) so the docs page localizes it |
| 15 | `web/data/cmux-shortcuts.ts` | `run-toggle-shortcut-doc` | Documents the `supermuxToggleRun` ⌘G shortcut in the keyboard-shortcut registry |
| 16 | `Sources/WorkspaceContentView.swift` | `presets-bar` | Renders `SupermuxPresetsBarMount(workspace:)` above the splits inside a single `VStack` wrapper that keeps upstream's `WorkspaceContentMinimalModeSafeAreaModifier` — one structural identity. The minimal-mode hide moved INTO the supermux-owned mount (v0.64.19 merge): upstream's `WorkspaceContentViewVisibilityTests` asserts mode toggles re-evaluate neither `ContentView` nor `WorkspaceContentView` bodies, so the fence must not read the presentation mode |
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + byte-identical `AppIcon-Debug.icon` + `AppIcon-Nightly.icon` (no DEV/NIGHTLY bands — all three channels share one mark); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered icon. macOS wiring lives in touchpoint #3; iOS renders from the same bundles via #241, and `AppIcon-Demo.icon` (iOS demo lane only) is a fourth sibling. |
| 18 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) at the end of the Automation section, and stores the `secretStore` + `errorLog` the card needs. The card itself is a new supermux-owned file, `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). **Upstream relocated this package under `Packages/macOS/`; the new card moved with it (git rename detection placed it at the new path).** |
| 20 | `Sources/Workspace+TerminalLinkOpening.swift` | `browser-link-new-tab` | When a Command-clicked terminal link — a web URL, or a local `.html`/`.htm` file routed through `Sources/TerminalHTMLFileBrowserAction.swift` — opens in the embedded browser and there is no existing right-side browser pane to reuse, open it as a new browser tab in the current pane (and switch to it) instead of creating a horizontal split. Upstream (0.65) deleted `GhosttyTerminalView.openEmbeddedBrowserLink(...)` and replaced it with the `TerminalLinkOpenContainer` protocol; the fence moved into `Workspace.openTerminalBrowserLink(url:sourcePanelId:)`. The SECOND conformance, `Sources/DockSplitStore+TerminalLinkOpening.swift`, is deliberately NOT fenced (known deviation — dock terminals keep upstream's split fallback) |
| 21 | `Sources/App/ShortcutRoutingSupport.swift` | `run-toggle-shortcut-dispatch` | ⌘G (the supermux Run/Stop toggle, shared with Find Next) is never ceded to a focused browser's native find, so cmux always owns the chord (otherwise WebKit swallows ⌘G and it is a dead key in the browser) |
| 22 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `run-toggle-shortcut-dispatch` | Updates the browser-find routing contract for ⌘G (run-toggle chord excluded from browser-first routing) and adds the regression test |
| 23 | `Sources/KeyboardShortcutSettings.swift` | `workspace-switcher-shortcut-case`, `workspace-switcher-shortcut-label`, `workspace-switcher-shortcut-default` | Adds the two workspace-switcher shortcut actions: `supermuxWorkspaceSwitcherNext` (default ⌘\`) and `supermuxWorkspaceSwitcherPrevious` (default ⇧⌘\`) |
| 24 | `Sources/AppDelegate.swift` | `workspace-switcher-monitor` | One hook in the app-local NSEvent monitor routes every event to `SupermuxComposition.workspaceSwitcher.handleMonitorEvent(_:appDelegate:)`: idle it acts only on the open chord; while presented it owns keyDown/keyUp/flagsChanged so it can cycle and commit on ⌘ release |
| 25 | `web/data/cmux-shortcuts.ts` | `workspace-switcher-shortcut-doc` | Documents the two workspace-switcher shortcuts in the keyboard-shortcut registry (in the Workspaces section, after `prevSidebarTab`) |
| 26 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` | `right-sidebar-min-width` | Lowers the right-sidebar minimum width floor from upstream's 276 to 200 so the panel can be dragged narrower (mode bar collapses to icon-only via touchpoint #5). **Upstream relocated this package under `Packages/macOS/` (cmux package reorg).** |
| 27 | `cmuxTests/SidebarWidthPolicyTests.swift` | `right-sidebar-min-width-test` | Two right-sidebar clamp assertions read `RightSidebarWidthSettings.minimumWidth` instead of the hardcoded `276`, so they track the lowered floor |
| 28 | `Sources/KeyboardShortcutSettings.swift` | `toggle-split-zoom-rebind` | Rebinds the `toggleSplitZoom` default from ⇧⌘↩ to ⌃⌘Z (canonical table) so ⇧⌘↩ is free for the supermux Changes-panel commit accelerator |
| 29 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `toggle-split-zoom-rebind` | Mirror of the rebound ⌃⌘Z default for the settings-UI package. **Upstream relocated this package under `Packages/macOS/`** (the old `Packages/CmuxSettings/…` path in the re-apply prose was stale) |
| 30 | `web/data/cmux-shortcuts.ts` | `toggle-split-zoom-rebind` | Documents Toggle Pane Zoom as ⌃⌘Z in the keyboard-shortcut registry |
| 31 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `toggle-split-zoom-rebind` | The split-zoom shortcut test drives the configured default, so it presses ⌃⌘Z (was ⇧⌘↩). **This file is Swift Testing since 0.65** (`@Suite(.serialized) @MainActor final class`, no `: XCTestCase`, no `import XCTest`, file-private `XCTAssert*` shims forwarding to `#expect`) — the fenced test MUST carry `@Test` or it silently stops running with green CI |
| 32 | `cmuxTests/KeyboardShortcutContextTests.swift` | `toggle-split-zoom-rebind` | Comment accuracy: toggleSplitZoom is no longer the Return-based shortcut (now ⌃⌘Z); assertions unchanged |
| 33 | `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | `toggle-split-zoom-rebind` | Two browser zoom round-trip UI tests press ⌃⌘Z instead of ⇧⌘↩. The file now builds its app with upstream's `XCUIApplication.cmuxTestApplication()` helper, not bare `XCUIApplication()` |
| 33b | `cmuxTests/AppDelegateSurfaceShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Seventh `toggle-split-zoom-rebind` site in the #28–33b sequence (the id appears in nine files tree-wide once #35/#36 are counted), never registered before the 0.65 merge: `cmdControlZInCanvasModeDoesNotToggleBonsplitSplitZoom` (upstream: `cmdShiftReturnInCanvasModeDoesNotToggleBonsplitSplitZoom`) presses ⌃⌘Z (`key: "z", modifiers: [.command, .control], keyCode: 6`) because `withTemporaryShortcut(action: .toggleSplitZoom)` installs the action's CONFIGURED default, which the fork rebound. Swift Testing (`@Test`) — same silent-skip hazard as #31 |
| 34 | `Sources/GhosttyTerminalView.swift` | `ghostty-unbind-split-zoom-return` | Unbinds Ghostty's built-ins `super+shift+enter = toggle_split_zoom` **and** `super+enter = toggle_fullscreen` so the freed ⇧⌘↩ / ⌘↩ actually reach the Changes-panel commit shortcuts in a focused terminal (without them the rebind is incomplete — same class as the numbered-tab unbinds, #5189) |
| 35 | `Sources/App/ShortcutRoutingSupport.swift` | `toggle-split-zoom-rebind` | Comment accuracy: the browser-Return rule no longer cites Toggle Pane Zoom as the Command-Return app shortcut (now ⌃⌘Z); notes ⇧⌘↩ is the commit accelerator. Logic unchanged |
| 36 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Regression test `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback` asserts the loaded Ghostty config has no `super+shift+enter` binding (companion to the #5189 numbered-fallback test) |
| 37 | `Sources/KeyboardShortcutSettings.swift` | `supermux-commit-shortcut-case`, `supermux-commit-shortcut-label`, `supermux-commit-shortcut-default` | Registers the Changes-panel `supermuxCommit` (⌘↩) and `supermuxCommitAccelerator` (⇧⌘↩) actions (case/label/default) so both are editable in Settings, live in `cmux.json`, and participate in conflict detection; applied by the panel's SwiftUI buttons (read via `SupermuxChangesMount`), not the app monitor. Settings visibility/conflict detection is actually delivered by the settings-package enum registration (#62/#63) |
| 38 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `supermux-commit-shortcut` | `testSupermuxCommitDefaultsBindReturnChords` asserts the two commit actions default to ⌘↩ / ⇧⌘↩ and do not cross-match |
| 39 | `Sources/FileExplorerView.swift` | `file-explorer-operations`, `file-explorer-operations-empty`, `file-explorer-operations-reveal` | Adds file-management to the right-sidebar file tree (local provider only): context-menu items New File/New Folder/Rename/Duplicate/Move to Trash on a clicked node, New File/New Folder on the empty area (root); the `-reveal` fence scrolls a just-created/renamed item into view after the reload. Keyboard handling (`file-explorer-operations-keys`) moved to #46 when upstream extracted the outline-view subclass into its own file (cmux #6001). All logic lives in supermux-owned files (`Sources/Supermux/SupermuxFileExplorerCommands.swift`, `SupermuxFileExplorerPrompt.swift`) and `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileSystemOperations.swift`; the fences are one-line calls into a `FileExplorerPanelView.Coordinator` extension |
| 40 | `Sources/FileExplorerStore.swift` | `file-explorer-operations-reveal` | Adds `supermuxRevealPath` + `supermuxReveal(path:)` to `FileExplorerStore` so a supermux file operation can select a just-created/renamed item by path (the selection state is `private(set)`, so this must live in the store's own file). The store fence also carries `var supermuxRevealRequestedAt: Date?` (set in `supermuxReveal`, cleared in `supermuxClearSelection`) used by the coordinator to expire a reveal after 10s, and two minimal same-id fences in `select(node:)` and `select(nodes:anchor:)` clear `supermuxRevealPath` when the selection moves to a different path. Paired with the coordinator's `-reveal` hook in touchpoint #39 |
| 41 | `Sources/TabManager.swift` | `new-workspace-standalone` | Marks every workspace created through cmux's normal new-workspace flow (`+` / ⌘T / surface tab bar) as standalone (`SupermuxWorkspaceAssociationStore.markStandalone` in `addWorkspace`) so it lands at the root of the flat list, never nested under the focused project. The project opener clears it via `associate`; the central close path clears it via `forget`. `restoreClosedWorkspace` (reopen) goes through `addWorkspace` too, so it explicitly `forget`s the mark afterwards to re-nest by directory; **session**-restore builds `Workspace` objects directly (no `addWorkspace`) and is unaffected. `releaseRestoredAwayWorkspace` `forget`s each released pre-restore workspace after the session-restore swap (it never reaches the central close path; the restored replacement re-nests by directory) |
| 42 | `Sources/TabManager+DetachedWorkspace.swift` | `new-workspace-standalone` | The detached-surface path (move-tab / move-surface to a new workspace) builds a `Workspace` directly, not via `addWorkspace`, so it marks the new workspace standalone too — a moved-out surface becomes a root-level workspace, never nested under a project whose directory it inherited |
| 43 | `Sources/TabManager.swift` | `keep-window-on-last-close` | Keeps the window open as an empty home when the last workspace closes — instead of `window.performClose`, which quit the app on the last window. `closeWorkspace(allowEmptyingWindow:)` removes the final workspace (selection clears to `nil`); the two surviving last-workspace close sites (`closeWorkspaceIfRunningProcess`, `closePanelAfterChildExited` — upstream deleted the bulk-close anchor branch at 0.65) + the bulk-close short-circuit/plan route through it, failed closed-workspace restore cleanup can empty the window again, and close confirmations no longer mark last-workspace closes as window-closing. Also fenced: `detachWorkspace` leaves the source window empty (`selectedTabId = nil`) when its last workspace moves to another window instead of upstream's `addWorkspace()` refill; `restoreSessionSnapshot` restores a zero-workspace snapshot as an empty home (fallback fabrication gated on `!snapshot.workspaces.isEmpty`); and a fenced comment marks `markRemoteTmuxKillOnWindowCloseIfNeeded` as intentionally orphaned (kept verbatim for merge cleanliness). Explicit window close (red button / ⌘⇧W) is unchanged |
| 44 | `Sources/ContentView.swift` | `empty-home` | `terminalContent` renders `SupermuxEmptyHomeView` (centered "No open tabs" hint) when `tabManager.tabs` is empty, gated to the `.tabs` sidebar surface and non-interactive. New file `Sources/Supermux/SupermuxEmptyHomeView.swift` wired via touchpoint #3 (IDs `…F5`/`…F6`); `supermux.emptyHome.*` keys under #4b |
| 45 | `cmuxTests/TabManagerUnitTests.swift` | `keep-window-on-last-close` | Repurposes the child-exit window-close test to assert the window stays open (empty home), adds two tests for `closeWorkspace(allowEmptyingWindow:)` emptying the window vs. a plain close keeping the last workspace, and covers failed closed-workspace restore cleanup from empty home; plus `testDetachingLastWorkspaceLeavesEmptyHome` and `testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty` |
| 46 | `Sources/FileExplorerNSOutlineView.swift` | `file-explorer-operations-keys` | ⌘⌫ (Move to Trash) / Return (Rename) keyboard handling in the outline view's `keyDown`, placed **before** upstream's `handleOpenSelectionShortcut` so Return renames (Finder-standard) and ⌘⌫ trashes; ⌘↓ still opens via upstream's Finder alias. Return/⌘⌫ are never claimed during an active `/` quick-search (Return keeps upstream's end-search+open semantics), and `handleSupermuxFileOperationKey` yields to a user-**explicitly**-configured Open Selection binding (Settings override or cmux.json) matching the keystroke, while the built-in Return default remains shadowed. Upstream (cmux #6001) extracted `FileExplorerNSOutlineView` out of `FileExplorerView.swift` into this file, so the `-keys` fence (originally part of #39) moved here. One-line call into the `FileExplorerPanelView.Coordinator` extension |
| 47 | `CLI/CMUXCLI+ThemeSupport.swift` | `right-sidebar-changes-mode-cli-set`, `right-sidebar-changes-mode-cli-normalize` | Adds `"changes"` to `isRightSidebarCLIMode` and `normalizedRightSidebarCLIArgument` so `cmux right-sidebar set changes` / `cmux right-sidebar changes` validate and normalize. Upstream (cmux CLI refactor) moved these two helpers out of `CLI/cmux.swift` into this file, so the `-cli-set` fence (originally part of #10) moved here; `-cli-normalize` is new (the normalizer did not exist at the previous merge base) |
| 48 | `Sources/RightSidebarChromeStyle.swift` | `right-sidebar-compact-mode-bar` | Adds a `showsLabel` flag to upstream's `ModeBarButton` (icon-only when the sidebar is narrow). Upstream relocated `ModeBarButton` here from `RightSidebarPanelView.swift` and switched it to an `item:`-based API; the compact-mode-bar fence (part of #5) moved with it. `RightSidebarPanelView.modeButtonsRow` now drives the `modeBarItems`/`ModeBarButton(item:showsLabel:)` API inside `ViewThatFits` |
| 49 | `Sources/Sidebar/SidebarWorkspaceSnapshotRefreshPolicy.swift` | `sidebar-flatrow-activity` | Carries `supermuxActivity` through the frozen-snapshot `applyingContextMenuImmediateFields` rebuild — since upstream 0.65 this is the SECOND production construction site of `SidebarWorkspaceSnapshotBuilder.Snapshot`, alongside `SidebarWorkspaceSnapshotFactory.makeSnapshot` (#128); `ContentView.swift` no longer constructs Snapshots. Previously an unfenced edit; fenced and registered during the upstream merge that added `finderDirectoryPath`/`mediaActivity` to the same initializer |
| 50 | `Sources/ContentView.swift` | `sidebar-hide-scrollbar` | Hides the left workspace sidebar's scrollbar. Two layers: (a) `VerticalTabsSidebar.configureSidebarScrollView` (the shared resolver hook for both the default projects+workspaces list and the extension-provider list) no longer calls upstream's `applySidebarOverlayScrollerConfiguration()`; it instead forces `hasHorizontalScroller`/`hasVerticalScroller` to `false` (write-only-when-differs). (b) Both sidebar `ScrollView`s get `.scrollIndicators(.hidden)` so SwiftUI itself keeps the indicator hidden — the AppKit resolver alone loses to SwiftUI, which re-asserts the scroller from its default `.scrollIndicators(.automatic)` after the resolver's deferred apply. Scrolling still works via trackpad/wheel |
| 51 | `scripts/reload.sh` | `reload-prune-leftover-base-app` | After a tagged build renames the raw `cmux DEV.app` into `cmux DEV <tag>.app`, calls the supermux-owned `scripts/supermux-prune-dev-builds.sh --reload-leftover` to deregister + delete the never-launched leftover base bundle, so macOS stops accumulating one stale "cmux DEV" row per tag in System Settings > Login Items & Extensions. The prune script is supermux-owned (no touchpoint); only this one-line call into it is fenced |
| 53 | `ios/Config/cmux.entitlements` | `unfenced` | Strips `com.apple.developer.applesignin`, `aps-environment`, and `com.apple.developer.usernotifications.time-sensitive` so automatic signing can provision a personal Apple team that lacks those capabilities (comments are unsafe to fence around a plist-key removal) |
| 54 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires `LocalConfig.plist` into the iOS app's Copy Bundle Resources phase (build file `FCAB1004…`, file ref `FCAB101B…`) so the app can read it from the bundle |
| 55 | `ios/cmux/Resources/LocalConfig.plist` | `unfenced` | New supermux-owned resource; sets `AuthEnvironment=production`, read by upstream's `MobileAuthComposition.authOverrides` LocalConfig override table (which replaced the retired #52 fence at the v0.64.19 merge). Not an upstream modification — registered so the check guards its existence (the pbxproj entry in #54 references it) |
| 56 | `Sources/Workspace+AgentLifecycle.swift` | `workspace-agent-lifecycle-observation` | One fenced line at the top of `recordAgentLifecycleChange(panelId:)` — the single choke point every agent-lifecycle set/clear routes through — calls `SupermuxWorkspaceLifecycleRelay.workspaceDidChangeAgentLifecycle(self)` (relay lives in supermux-owned `Sources/Supermux/SupermuxWorkspaceActivityResolver.swift`), making lifecycle-only mutations observable: cmux's sidebar publishers carry no lifecycle field, so without it the supermux activity indicators went stale on socket `set_agent_lifecycle`, hibernation clears, and feed-attention conclusion. Placed before the `AgentHibernationController` call, whose tracking gate drops events when disabled. **Upstream (0.64.x) extracted the lifecycle code out of `Workspace.swift` into `Workspace+AgentLifecycle.swift`; the fence moved with it** |
| 57 | `Sources/Workspace.swift` | `keep-window-on-last-close` | Remote-tmux close-button fallback: the last workspace of the last window closes into the empty home (`closeWorkspace(self, recordHistory: false, allowEmptyingWindow: true)`) instead of falling through to a replacement local shell in the dead mirror; the multi-window discard branch stays upstream |
| 58 | `Sources/AppDelegate.swift` | `new-workspace-standalone` | `unregisterMainWindow` prunes the association store against the union of every remaining window's workspace ids on whole-window teardown (which skips the per-workspace close path); durable directory links live in the projects model and survive, so a revived closed window re-nests by directory |
| 59 | `Sources/TerminalController.swift` | `keep-window-on-last-close` | The socket `close_workspace` command routes through `closeWorkspace(tab, allowEmptyingWindow: true)` and replies OK only when the workspace actually left `tabs` (upstream `closeTab` silently no-ops on a window's last workspace while replying OK) |
| 60 | `Sources/RemoteTmuxController.swift` | `keep-window-on-last-close` | BOTH arms of upstream 0.65's teardown-reason switch are fenced: `.sessionEnded` (dead mirror) drops upstream's add-a-replacement-workspace workaround and closes with `allowEmptyingWindow: true`; `.explicitDetach` (deliberate detach, remote session kept alive) replaces upstream's `closeWorkspaceNonInteractively(allowPinned: true)` — which closes the whole window (and on the last window quits the app) when the mirror is the window's last workspace — with the same `closeWorkspace(allowEmptyingWindow: true)`, leaving the empty home. Pre-0.65 both cases shared one teardown path and one fence |
| 61 | `Sources/AppleScriptSupport.swift` | `keep-window-on-last-close` | AppleScript `close tab` (`ScriptTab.handleCloseTab`) and terminal `close` last-panel path (`ScriptTerminal.handleClose`) call `closeWorkspace(workspace, allowEmptyingWindow: true)` instead of the `tabs.count > 1` fork + `window.performClose(nil)`, so scripted last-workspace closes leave the empty home like ⌘W |
| 62 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift` | `run-toggle-shortcut-case`, `workspace-switcher-shortcut-case`, `supermux-commit-shortcut-case` | Adds the five supermux cases (`supermuxToggleRun`, the two workspace-switcher actions, the two commit actions) to the settings-package enum that drives the Settings UI and its conflict detection (reuses the app-target fence ids). Upstream (0.65) extracted `group` and `displayName` out of this file, so the two other fences moved to #62b/#62c |
| 62b | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Group.swift` | `supermux-shortcut-groups` | Places the five supermux actions in the Settings groups (`supermuxToggleRun`/`supermuxCommit`/`supermuxCommitAccelerator` → `.workspace`; the two workspace-switcher actions → `.navigation`). Upstream extracted `ShortcutAction.group` out of `ShortcutAction.swift` into this file; the fence moved with it |
| 62c | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+DisplayName.swift` | `supermux-shortcut-display-names` | The five `String(localized: "supermux.shortcut.*.label", …)` display names shown in the Settings shortcut list. Upstream extracted `ShortcutAction.displayName` out of `ShortcutAction.swift` into this file; the fence moved with it. The package resolves `String(localized:)` against `Bundle.main`, so the app catalog (`Resources/Localizable.xcstrings`, #4b) serves these keys in en + ja |
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
| 80 | `Sources/TabManager.swift` | `new-workspace-home-dir` | With "Inherit Workspace Working Directory" OFF, new workspaces always start in the home directory. **TWO fence sites since 0.65.** (a) `addWorkspace` — upstream rewrote it to resolve the cwd through `WorkspaceCreationWorkingDirectoryPolicy(inheritanceEnabled:).resolve(explicitWorkingDirectory:inheritedWorkingDirectory:defaultWorkingDirectory:)` and STOPPED calling `implicitWorkingDirectoryForNewWorkspace`; the fence supplies `FileManager.default.homeDirectoryForCurrentUser.path` as `defaultWorkingDirectory` in place of upstream's `defaultWorkspaceWorkingDirectoryProvider()`. The guard keys off the **SETTING alone**, never `inheritanceEnabled`, so an explicit `inheritWorkingDirectory: false` call with the setting ON still takes upstream's default (upstream's `testExplicitNoInheritanceUsesGhosttyDefaultWhenGlobalInheritanceEnabled` depends on that). (b) `implicitWorkingDirectoryForNewWorkspace` — same home pin, now serving only the detached path (#42's file). Regression test: `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` (wired via #3). See the OPEN DECISION note in the #80 re-apply section: upstream has since closed the nil-cwd leak on its own terms |
| 81 | `cmuxTests/WorkspaceUnitTests.swift` | `new-workspace-home-dir` | Upstream renamed this test to `testDisabledInheritanceUsesGhosttyDefaultForNewWorkspaceCwd` (was `…LeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback`) and it now asserts `fallbackCwd` via an injected `defaultWorkspaceWorkingDirectoryProvider` instead of a nil cwd. Either form contradicts the fork, so it stays fenced as `testDisabledInheritancePinsNewWorkspaceCwdToHomeDirectory`, keeps the injected provider, and asserts the explicit home directory (proving the fork's pin beats the provider). Only coverage of #80's `addWorkspace` fence site |
| 82 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AppSection.swift` | `new-workspace-home-dir` | The Inherit Working Directory toggle's OFF subtitle now says new workspaces always start in the home directory (upstream promised a Ghostty working-directory fallback that #80 removes); matching en/ja catalog values updated under #4b, schema description under #14 |
| 83 | `cmuxUITests/SettingsAppBehaviorUITests.swift` | `new-workspace-home-dir` | `Subtitle.inheritOff` now matches the fork's OFF subtitle; upstream's constant held the removed Ghostty-fallback wording, so `testInheritWorkingDirectoryToggleSwapsSubtitle` (which polls for that exact static text after clicking the toggle) failed deterministically against #82's reworded row |
| 84 | `Sources/SettingsSearchAliases.swift` | `new-workspace-home-dir` | The toggle's settings-search alias swaps the stale `ghostty` keyword for `home` (the OFF behavior no longer involves Ghostty's working-directory setting); en/ja catalog values under #4b |
| 85 | `Sources/SettingsNavigation.swift` | `new-workspace-home-dir` | Same `ghostty` → `home` keyword swap in the settings-navigation entry's search keywords |
| 86 | `web/messages/en.json` | `unfenced` | Adds `schemaDescriptions.app.workspaceInheritWorkingDirectory` so the localized docs configuration page renders the reworded #14 schema description through `descriptionKey` (the sibling mechanism 32 other schema properties use) instead of the English-only `description` fallback |
| 87 | `web/messages/ja.json` | `unfenced` | Japanese translation for the #86 message key |
| 88 | `skills/cmux-settings/references/all-keys.md` | `unfenced` | Regenerated the `app.workspaceInheritWorkingDirectory` description row to match the #14 schema description (the file is auto-generated from `web/data/cmux.schema.json` and had the removed Ghostty-fallback wording) |
| 90 | `cmux.xcworkspace/contents.xcworkspacedata` | `unfenced` | Adds the supermux-owned package FileRefs to the workspace groups: `Packages/Shared/SupermuxMobileCore`, `Packages/Shared/SupermuxClaudeHarness` and `Packages/Shared/SupermuxZeronUI` (Shared group), `Packages/iOS/SupermuxMobileKit` and `Packages/iOS/SupermuxMobileUI` (iOS group). Generated file — regenerate with `python3 scripts/check-workspace-package-groups.py --write` (the `Packages/` folder layout is the source of truth), never hand-edit |
| 91 | `Sources/TerminalController.swift` | `mobile-supermux-dispatch` | One case in the `mobileHostHandleRPC` switch routes the whole `mobile.supermux.*` namespace to `v2MobileSupermuxDispatch` (fork-owned `Sources/Supermux/TerminalController+SupermuxMobile.swift`), mirroring the adjacent prefix cases. Since the 0.64.21 merge it sits **after upstream's new `mobile.browser.*` case** (it used to follow `mobile.chat.*` directly); position among the prefix cases is irrelevant as long as it precedes `default:` |
| 92 | `Sources/Mobile/MobileHostService+TicketAuthorization.swift` | `mobile-supermux-authz` | In `ticketAuthorizationError(authorization:request:)` (**upstream 0.64.x extracted ticket authorization out of `MobileHostService.swift` into this file; the fence moved with it**), after the alias/conflict guards and before the upstream method switch, delegates every `mobile.supermux.*` method to the fail-closed `SupermuxMobileAuthorization.ticketError` table (fork-owned `Sources/Supermux/SupermuxMobileAuthorization.swift`); reachable in tests by calling `ticketAuthorizationError` directly (upstream removed the `debugTicketAuthorizationError` seam) |
| 93 | `Sources/Mobile/MobileHostService+Capabilities.swift` | `mobile-supermux-capabilities` | `capabilities += SupermuxMobileCapabilities.advertised` (fork-owned `Sources/Supermux/SupermuxMobileCapabilities.swift`) inside `mobileHostCapabilities(includingWorkspaceChanges:)`, placed **after** upstream's `includingWorkspaceChanges` filter and **before** the `#if DEBUG` `CMUX_DEBUG_SUPPRESS_MOBILE_CAPS` suppression, so the phone can gate supermux screens on `supermux.*.v1` and a dev Mac can still suppress fork capabilities. **Invariant:** the fork list must never contain the literal `workspace.changes.v1` — upstream's `cmuxTests/MobileHostConnectionLifecycleTests.swift` asserts `enabled.filter { $0 != workspaceChangesCapability } == disabled`, which a duplicate entry breaks |
| 94 | `Sources/AppDelegate.swift` | `mobile-supermux-observers` | One line at the top of `ensureMobileWorkspaceListObserver(for:)` calls `SupermuxMobileHostGlue.activateIfNeeded()` (fork-owned `Sources/Supermux/SupermuxMobileObservers.swift`) so fork mobile observers activate exactly where upstream constructs `MobileWorkspaceListObserver` |
| 95 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the `SupermuxMobileCore` package (local package reference + product dependency on the `cmux` and `cmuxTests` targets), the existing seventeen `50BE0002…` `Sources/Supermux/` mobile files, and `Workspace+SupermuxMobileUnread.swift` (`50BE0003…0001/0002`) into the cmux target; also wires the four Supermux mobile app-host tests into `cmuxTests` |
| 96 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-client-mount` | One computed property `supermuxConnectionSeam` (next to `remoteClientForAgentChat`) exposes the live `MobileCoreRPCClient` + `supportedHostCapabilities` snapshot to the fork's supermux phone stores; `nil` unless connected. All tracked `@Observable` reads, so the fork's section driver re-runs (and rebuilds `SupermuxMacClient` + stores) on every (re)connect and on capability arrival |
| 97 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-projects-section` | Five fences: `import SupermuxMobileUI`; a `@State` `SupermuxProjectsSectionModel` (**internal, not private** — the `+Table.swift` extension projects it into the #148 row payload); the `.supermuxProjectsSectionDriver(model:connection:workspaces:selectWorkspace:)` session driver on the **iOS** `workspaceTable` (fed by the #96 seam; `workspaces` + `selectWorkspace` feed the §6 open-workspace join and nested-row navigation); and, in the macOS-only `#else` arm, the legacy `SupermuxProjectsMobileSection(section:actions:)` mount + driver on the SwiftUI `List`. **The two arms are not interchangeable.** Since upstream 0.64.20 the iPhone renders `workspaceTable`, so the `#else` mount is macOS-only and the iOS rows come from #148 instead; a driver left only in `#else` (the state this row shipped in from 0.64.20 until #148) means the section never loads on iOS and every Projects affordance is unreachable. The driver must stay on a STABLE view — never inside a table cell — because it owns the session `.task`, the project-detail `navigationDestination`, and the nested-open error alert. Section renders nothing without `supermux.projects.v1` |
| 98 | `Packages/iOS/CmuxMobileShellUI/Package.swift` | `supermux-mobile-shellui-deps` | Two fenced 1-line additions: `.package(path: "../SupermuxMobileUI")` in `dependencies` and `"SupermuxMobileUI"` in the `CmuxMobileShellUI` target dependencies (fork-owned Projects section package) |
| 99 | `Sources/TerminalController+MobileWorkspaceList.swift` | `mobile-supermux-workspace-fields` | Builds the legacy row, merges project/activity/branch/PR metadata, adds `supermux_unread_count` when known, and always adds `supermux_unread_panel_ids` from #389. The always-present array is the exact-pane capability signal; it must remain outside the project-association-gated augmenter |
| 100 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-workspace-fields` | Lossily decodes the additive project/activity/branch/PR fields plus optional unread count and optional `[String]` pane ids; memberwise construction defaults every fork field to `nil` for upstream source compatibility. `nil` pane ids mean unsupported, while `[]` is preserved as supported-empty |
| 101 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-workspace-fields` | Stores the additive metadata, unread count, and optional `supermuxUnreadPanelIDs`, all defaulted to `nil`. The derived `supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen` is true only for unread old-host rows; aggregation copies the whole preview value, preserving both old-host absence and supported-empty pane state |
| 102 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-workspace-fields` | Copies every decoded Supermux workspace field into the preview, including unread count and exact pane ids, so legacy list ingestion feeds the same UI model as state sync v2 |
| 103 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-project-workspaces`, `supermux-mobile-row-activity` | Hide filter: a fenced `supermuxFlatWorkspaces` helper (`workspaces.supermuxFlatRows(hidingProjectIDs: supermuxShownProjectIDs)`), where `supermuxShownProjectIDs` is non-empty only while `snapshot.isVisible && snapshot.hasLoaded && trimmedQuery.isEmpty && !filter.isActive` — i.e. the hide is active only when the Projects section is visible AND loaded AND no search/filter, plus two fenced swaps where upstream read `workspaces` — one in `filteredWorkspaces` (a one-line `let workspaces = supermuxFlatWorkspaces` rebind) and one in `groupedWorkspaces` (the fence wraps only the `return`; upstream's `parsedMachines` precompute sits above it, unfenced). Row dot: one fenced `.supermuxWorkspaceActivityDot(rawActivity:)` modifier on `WorkspaceNavigationRow` in `workspaceRow` |
| 104 | `ios/cmux/AppCompositionRoot.swift` | `uitest-clear-paired-mac-state` | When `UITestConfig.mockDataEnabled` and the harness sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1`, deletes `Application Support/cmux/` (the `MobilePairedMacStore` sqlite + WAL/SHM) once at composition-root init, before `CMUXMobileRootScene` opens the store. Fixes cross-test pairing-state leakage on the shared simulator: since #89 made pairing actually complete, a persisted paired Mac from a prior test/run auto-navigated past `MobileAddDeviceForm` and its dead-host reconnect churn broke 3 cmuxUITests (cmuxUITests.swift:245/:586). No-op for real installs: the mock gate is DEBUG-only and the env var is only set by the XCUITest harness (#105) |
| 105 | `ios/cmuxUITests/cmuxUITests.swift` | `uitest-clear-paired-mac-launch` | `launchApp` sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1` on every harness launch so each test starts from an unpaired slate (consumed by #104) |
| 107 | `scripts/check-package-resolved-policy.py` | `fix-resolved-policy-path-deps` | Manifest diffs whose `.package(…)` changes are limited to path-based dependencies (`.package(path:)`, including brand-new path-referenced manifests) no longer demand a `Package.resolved` diff — SwiftPM never records path deps in any lockfile, so that demand was unsatisfiable (`swift package resolve` rewrites nothing). Pinned url dependency changes still require lockfile churn. Also silences the `fatal: path … exists on disk, but not in <merge-base>` stderr noise from `git show` on manifests new since the merge-base. **FIVE fence blocks** (previous notes said three/four): helper `lockfile_recorded_dependency_calls`, `path_dependency_remote_pin_roots`, the `current_remote_memo` declaration in `main` (upstream's refactor deleted the surrounding line the memo used to piggyback on, so it is now its own fenced block — a merge that drops it makes the script crash with `NameError: current_remote_memo`), the changed-roots skip in `main`, and `file_text_at`. **Since Focus Mode (#244–250), SEVEN**: two more skips close the same unsatisfiable-demand hole one level up, where a path dep is added onto a package whose remote pins the depender ALREADY resolved. The per-package loop and the iOS-workspace gate both then demanded a lockfile diff that SwiftPM/Xcode will not write, because the recorded remote pins and the `originHash` come back byte-identical (verified against a real `-resolvePackageDependencies`). Both new skips compare the *remote* dependency closure before and after and bail only when it is unchanged, so adding a genuine `.package(url:)` still fails the check |
| 108 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-workspace-tools` | Two fences: `import SupermuxMobileUI`, and the `.supermuxWorkspaceTools(connection:workspaceID:workspaceName:showingChanges:showingFiles:)` modifier on the detail `body`'s outer `Group`. Since the #228 toolbar consolidation the modifier mounts ONLY the two sheets (`SupermuxChangesScreen` / `SupermuxFileBrowserScreen`), driven by the `isSupermuxChangesSheetPresented` / `isSupermuxFilesSheetPresented` bindings that #228's explicit overflow menu flips via the fork-owned `SupermuxWorkspaceToolsMenuEntries`; it no longer adds `ToolbarItem`s of its own. Fed by the #96 `supermuxConnectionSeam`; each menu entry hides without its capability (`supermux.changes.v1` / `supermux.files.v1`). Note upstream now ships its OWN mobile diff viewer behind `workspace.changes.v1`; both are advertised whenever `CmuxFeatureFlags.mobileWorkspaceChangesFlag` is on — see SUPERMUX.md "Known limitations", open decision 2 |
| 109 | `scripts/lint-ios-package-conventions.sh` | `lint-ios-conventions-fork-scopes` | Adds the fork packages (`Packages/Shared/SupermuxMobileCore`, `Packages/Shared/SupermuxClaudeHarness`, `Packages/Shared/SupermuxZeronUI`, `Packages/iOS/SupermuxMobile*`) to the lint's SCOPES so the iOS conventions lint (CI job `package-conventions-lint` in `.github/workflows/test-ios.yml`) mechanically enforces its per-line rules on them; deliberate constant/text namespace holders in the fork packages carry inline `lint:allow` justifications |
| 110 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-search` | ⚠️ **INERT since the 0.64.21 merge — comment-only marker, the fork behavior is gone.** It used to replace upstream's `.searchable(text: $searchText)` on the workspace `List` so the phone had no main-list search bar. Upstream moved search into two NEW files (`…/WorkspaceListSearchHost.swift` pre-iOS 26, `…/MobilePrimaryTabScaffold.swift` for the iOS 26 search Tab) and `searchText` is now an injected property rather than `@State`, so **phone search is LIVE again** and there is nothing left in this file to remove. OPEN DECISION — re-apply at the new hosts, retire the touchpoint, or accept upstream's search (current default). See SUPERMUX.md "Known limitations" |
| 111 | `.gitignore` | `supermux-gitignore-mission` | One fenced line ignoring the fork-local `mission/` mission-kit state directory (mission-plan/mission-run progress artifacts; local tooling data, never product code). `.phone-build/` directly above is upstream/pre-existing and stays unfenced. Re-apply: if upstream rewrites `.gitignore`, re-add `mission/` inside the fence anywhere in the file |
| 112 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/SupermuxWorkspaceListFieldsDecodeTests.swift` | `unfenced` | Whole fork-owned test file in the upstream RPC test target. Proves additive-field tolerance and preview mapping, including upstream absence, exact pane-id arrays, supported-empty `[]`, and malformed mixed-type pane arrays degrading to unsupported `nil` without failing the workspace list |
| 113 | `Sources/SidebarWorkspaceSnapshotBuilder.swift` | `sidebar-flatrow-activity` | The fenced `var supermuxActivity: SupermuxWorkspaceActivity = .idle` field (defaulted so non-production construction sites can omit it) + a fenced `import SupermuxKit`. Upstream (0.64.x) extracted `SidebarWorkspaceSnapshotBuilder` out of `ContentView.swift` into this file; the Snapshot-field part of the #2 fence moved with it. The production construction sites (`SidebarWorkspaceSnapshotFactory.makeSnapshot` in #128, the frozen-snapshot rebuild in #49) pass it as the LAST parameter (the struct declares it after upstream's checklist fields) |
| 114 | `Sources/TabItemView+WorkspaceContextMenu.swift` | `sidebar-hide-project-workspaces` | Upstream (0.64.x) extracted `workspaceContextMenu` out of `ContentView.swift` into this file; the context-menu enablement part of the #2 fence moved with it: one fenced `let menuVisibility = actions.supermuxMenuVisibility(workspaceId, Set(targetIds))` resolve before Move Up (keyed by workspace id — the row's snapshot `index` is its visible ordinal since the VoiceOver fix, so the provider resolves the full-list position itself), and the five fenced `.disabled(...)` overrides: Move Up/Down disable on `canMoveUp`/`canMoveDown` (stepped-plan reachability, matching the #131 mover), Close Other/Below/Above on visible-row availability. Since upstream's 0.65 snapshot boundary the row holds no `tabManager`, so visibility resolves through the #129 actions field (bound in #2, value type in fork-owned `SupermuxRowMenuVisibility.swift`) |
| 115 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `keep-window-on-last-close` | Repurposes upstream's `testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace` (renamed `testCmdWLeavesEmptyHomeWhenClosingLastSurfaceInLastWorkspace`): with the close-workspace-on-last-surface setting on, Cmd+W on the last surface of the last workspace closes the WORKSPACE but keeps the window open as the empty home; upstream asserted the window closes, which is exactly the behavior keep-window-on-last-close removes (same class as #45/#81/#83) |
| 116 | `Sources/Workspace.swift` | `workspace-geometry-snapshot-dedup` | Early-return in `splitTabBar(_:didChangeGeometry:)` when the incoming `LayoutSnapshot` differs from `tmuxLayoutSnapshot` only by `timestamp` (Bonsplit stamps every snapshot with `Date()`, so synthesized equality never dedupes, and its container re-emits geometry from `onAppear`/`onChange` during SwiftUI remounts). Skips the `@Published` republish, the `.workspacePaneGeometryDidChange` post, and `scheduleTerminalGeometryReconcile()`; keeps the order-gated `surfaceList.registerGeometryChange()` and `scheduleFocusReconcile()` unconditional. Selection/focus changes always pass (carried by `selectedTabId`/`focusedPaneId`). Breaks the layout→publish→layout feedback loop captured in the supermux CPU investigation |
| 117 | `cmuxTests/TabManagerUnitTests.swift` | `workspace-geometry-snapshot-dedup` | Regression test `WorkspaceGeometrySnapshotDedupTests`: a timestamp-only geometry callback must not republish `tmuxLayoutSnapshot`; a real geometry change must still publish (two-commit red/green pair) |
| 118 | `README.md` | `readme-fork-rewrite` | Wholesale replaces upstream's README with the supermux one (fork identity, features, build-from-source, upstream credit). The fence wraps the whole file. The `README.<lang>.md` translations stay upstream's apart from the #120 banner |
| 119 | `CONTRIBUTING.md` | `contributing-fork-note` | One fenced blockquote after the H1: upstream's guide is kept for reference; fork issues/PRs go to rajinsyed/supermux and SUPERMUX.md is the fork contract |
| 120 | `README.ja.md` | `readme-translation-banner` | Same one-line fenced banner (localized per file) prepended to all 20 `README.<lang>.md` translations: "this is the upstream cmux README; the fork's additions are in README.md". Only the `ja` file is registered here; the fence id is identical in all 20 |
| 122 | `.github/test-determinism-allowlist.txt` | `unfenced` | Three grandfathered entries for supermux-owned tests the determinism gate flags by heuristic: `SupermuxMobileChangesStoreSyncTests.swift` (assert-on-duration — static assertion on a configured RPC timeout, not a measured duration) and `SupermuxMobileObserversTests.swift` + `SupermuxMobileRunObserverTests.swift` (sleep-then-assert — prove-silence tests must outwait the poke throttle window). Data file like #4; re-add the three lines if a merge drops them |
| 123 | `scripts/ci/run-app-host-xcodebuild.sh` | `actool-crash-retry`, `ci-exclude-icon-composer` | One fenced `elif` in the retry-reason chain (`Command CompileAssetCatalogVariant failed` retries as "asset catalog compiler crash") plus a fenced trailing `'EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon'` build setting on the xcodebuild invocation. **The `ci-exclude-icon-composer` fence now also encloses upstream's `TEST_RUNNER_CMUX_TEST_PROCESS=1 \` env prefix** — a shell line continuation cannot host a comment mid-command, so the fence had to start above the whole invocation. A re-apply that restores only the trailing build setting would silently drop that env var and break `tests/test_ci_app_host_xcodebuild_retry.sh`. ibtoold crashes rendering the fork's Icon Composer `AppIcon*.icon` files (#17) on some CI VMs — deterministically on affected machines, so the exclusion is the fix and the retry is a backstop for other asset-catalog flakes; upstream has no `.icon` files, so this crash class is fork-introduced. The app icon is cosmetic in headless CI |
| 124 | `.github/workflows/ci.yml` | `actool-crash-retry` | The `tests-build-and-lag` "Build for runtime regressions" step's single xcodebuild invocation is wrapped in a fenced 2-attempt loop that adds `'EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon'` and retries only on the `CompileAssetCatalogVariant` crash signature (same rationale as #123); other flags and the `tee /tmp/cmux-build-output.txt` log path (consumed by the warning-budget step) are unchanged |
| 125 | `.github/workflows/perf-activation.yml` | `actool-crash-retry` | The "Build tagged app" step's single `reload.sh` invocation is wrapped in the same fenced 2-attempt retry loop as #124 and sets `CMUX_EXCLUDE_ICON_COMPOSER=1` (consumed by #126) |
| 126 | `scripts/reload.sh` | `ci-exclude-icon-composer` | Fenced env hook: `CMUX_EXCLUDE_ICON_COMPOSER=1` appends `'EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon'` to `XCODEBUILD_ARGS` so headless CI reload builds skip Icon Composer rendering (see #123); local/dev reloads are unaffected |
| 127 | `.github/workflows/ci.yml` | `release-build-timeout` | `release-build`'s `timeout-minutes` raised 60 → 120 (fenced): a cold universal Release build exceeds 60 minutes on the fork's runner pool, and a job killed at the cap never seeds the DerivedData cache, so the upstream cap could never converge on the fork |
| 128 | `Sources/SidebarWorkspaceSnapshotFactory.swift` | `sidebar-flatrow-activity` | Upstream (0.65) extracted per-workspace snapshot building out of `TabItemView` into this parent-side factory; the snapshot-resolution part of the #2 fence moved with it: resolves `SupermuxWorkspaceActivityResolver.activity(for:)` + `activityByAgentKey(for:)` once per snapshot, filters duplicate agent lifecycle rows out of `metadataEntries` via `SupermuxSidebarAgentStatusRows.droppingAgentStatusRows`, and passes `supermuxActivity` as the Snapshot's LAST parameter (#113). The metadata filter is gated OFF when `isAppKitSidebarListEnabled`: the factory feeds BOTH list implementations, and #295 ports only the working spinner to the AppKit row; retaining metadata there preserves the needs-input/ready text that AppKit does not visualize |
| 129 | `Sources/SidebarWorkspaceRowActions.swift` | `sidebar-hide-project-workspaces` | One fenced defaulted `var supermuxMenuVisibility: (UUID, Set<UUID>) -> SupermuxRowMenuVisibility = { _, _ in .allVisible }` at the end of the actions struct — keyed by the row's workspace id, not an index (rows hold no store reference under upstream's 0.65 snapshot boundary, so menu enablement resolves through the actions bundle on menu open, like `currentWindowMoveTargets`). The provider is bound in the #2 actions-bundle construction; the value type lives in fork-owned `Sources/Supermux/SupermuxRowMenuVisibility.swift` (now also carrying `canMoveUp`/`canMoveDown` from the #131 stepped-plan check); consumed by the #114 menu builder. Defaulted so upstream construction sites (tests) compile unchanged |
| 130 | `Sources/FeatureFlags.swift` | `appkit-sidebar-default-off` | **FIVE fenced regions** (was two before the 0.64.21 merge) pinning upstream's `sidebar-appkit-list-experiment` OFF on the fork: (a) `appKitSidebarListDefault` flipped `true` → `false`; (b) a shared `supermuxIngestibleRemoteValue(_:for:)` gate; and one-line wraps at **all three** `remoteValuesByKey` write sites — (c) the `init` remote-cache seeding, (d) `applyRemoteFlagValues(_:)` (the production PostHog control-plane path this merge added), and (e) `applyLoadedFlags()` (now test-only). **Invariant:** a remote `true` for `sidebar-appkit-list-experiment` is never ingested at ANY site, a cached `true` is evicted, and a remote `false` still ingests as upstream's kill switch — a Debug opt-in cannot outlive an upstream emergency disable. The gate is keyed off `appKitSidebarListFlag.key`, not a string literal, so an upstream key rename cannot silently disarm it. **ANY new writer of `remoteValuesByKey` must route through the gate.** Why: a remote rollout outranks both the default and the user's local override, and `appKitWorkspaceScrollArea` then renders `SidebarWorkspaceTableView` directly, bypassing the SwiftUI list that hosts most supermux sidebar features (Projects section, project-workspace nesting/hiding, unified row style); only the working activity spinner is ported to AppKit via #295. Debug local override remains the opt-in; while it is on, fork-owned `SupermuxMainListFilter.tabsForMainList` returns the list unfiltered and #128's metadata filter is bypassed, so the AppKit list behaves like stock cmux (no hidden rows for its full-list NSMenu actions to destroy). Three upstream tests currently contradict this fence — see SUPERMUX.md "Known limitations", entry on `PostHogAnalyticsPropertiesTests`. Re-evaluate when porting the Projects section to the AppKit list |
| 131 | `Sources/TabManager+AdjacentWorkspaceReordering.swift` | `sidebar-hide-project-workspaces` | `reorderWorkspace(tabId:by:)` — the ONE adjacent-move entrypoint shared by the sidebar context menu, the menu-bar/keyboard shortcut (`moveSelectedWorkspace`), and the socket `workspace.action move_up`/`move_down` verbs — is fenced to route through fork-owned `TabManager.supermuxSteppedReorderTarget` (`Sources/Supermux/SupermuxWorkspaceReorderStepping.swift`): steps over project-hidden rows to the nearest visible neighbor and returns `false` (no mutation) when the clamped destination (pin tier / group section, via the coordinator's public `workspaceReorderPlan`) would not change the visible flat-list order. The same helper drives the #114 Move Up/Down enablement, so menu state and mutation agree. With no hidden rows (or under the AppKit list, where #130's filter gate empties the hidden set) it degrades to upstream's `currentIndex + offset` |
| 132 | `Sources/SidebarWorkspaceRowInput.swift` | `sidebar-hide-project-workspaces` | Two fenced defaulted fields `supermuxVisibleIndex`/`supermuxVisibleCount: Int?` (visible-flat-list ordinal/total for the row's VoiceOver "workspace N of M" announcement; `nil` falls back to the full-list values) plus the fenced pass-through in `rowSnapshot(list:)`. `index`/`workspaceCount` keep upstream's full-list semantics (⌘-number digits, shift-range selection, `lastSidebarSelectionIndex`). Values computed in the #2 row-input construction from `renderContext.projectHiddenWorkspaceIds`; consumed by the fenced `accessibilityTitle` in `TabItemView` (#2). Defaulted so upstream construction sites compile unchanged |
| 133 | `Sources/SidebarWorkspaceRowSnapshot.swift` | `sidebar-hide-project-workspaces` | The matching two fenced defaulted fields on the row snapshot value (`supermuxVisibleIndex`/`supermuxVisibleCount: Int?`); synthesized `Equatable` covers them, preserving the row's change-detection contract. See #132 |
| 134 | `cmuxTests/RemoteTmuxMirrorCloseDetachTests.swift` | `keep-window-on-last-close` | Repurposes two upstream tests to the fork contract (#60, same class as #115/#45/#81/#83): `explicitDetachOfDedicatedLastMirrorClosesOwningWindow` → `explicitDetachOfDedicatedLastMirrorLeavesEmptyHomeWindow` (window stays open/visible/listed with `tabs.isEmpty` instead of closing), and `remoteSessionEndOfDedicatedLastMirrorKeepsOwningWindowUsable`'s replacement-workspace assertion flips `tabs.count == 1` → `tabs.isEmpty` (the fork leaves the empty home, never a fresh local replacement shell) |
| 135 | `cmuxTests/ClaudeHookLiveDeliveryTargetTestSupport.swift` | `claude-hook-mock-server-threads` | `startMockServer`'s blocking accept loop and per-connection reader run on dedicated `Thread`s instead of upstream's `DispatchQueue.global(qos: .userInitiated).async`. A blocking `accept()`/`read()` parks its GCD worker for the queue's lifetime; the 0.64.20 app-host under test raises global-pool pressure enough that those blocks could wait indefinitely on the macOS 15 CI runners — the hook CLI's `connect()` completed into the kernel backlog with nobody accepting, all 7 ClaudeHook* tests timed out with zero recorded commands (empirically isolated: the same binary/env/protocol runs clean on the same runner outside the app host). Sibling harnesses with the same upstream pattern (`CLINotifyProcessTestSupport`, `CLICodexHookTimeoutRegressionTestSupport`, `CLIMockSocketServerSupport`) pass in their shards and are left upstream-shaped; apply this fence's pattern to them if shard composition ever surfaces the same starvation there |
| 134 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxDeviceIDCanonicalization.swift` | `lint-allow-upstream-debt` | Fenced `lint:allow free-function` for `cmxCanonicalDeviceID` — upstream conventions-lint debt at the 0.64.20 merge point (see #134–138 re-apply note) |
| 135 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShellReleaseGateSupport/MobileIrohReleaseGateResponseValidator.swift` | `lint-allow-upstream-debt` | Fenced `lint:allow namespace-enum` for `MobileIrohReleaseGateResponseValidator` — same upstream lint debt family |
| 136 | `Packages/Shared/CmuxIrohTransport/Sources/CmuxIrohTransport/CmxIrohTCPFirstActivation.swift` | `lint-allow-upstream-debt` | Fenced `lint:allow namespace-type` for `CmxIrohTCPFirstActivation` — same upstream lint debt family |
| 137 | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/CmuxPopoverMutation.swift` | `lint-allow-upstream-debt` | Fenced `lint:allow namespace-type` for `CmuxPopoverMutation` — same upstream lint debt family |
| 138 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/DiagnosticLog.swift` | `lint-allow-upstream-debt` | Fenced `lint:allow lock` for the `OSAllocatedUnfairLock(initialState:)` constructor in the nested `Ingress.init` (the enclosing type is `Ingress`, not `EventBuffer` — an earlier note named a type that does not exist in this file); upstream justified only the property decl 7 lines above, outside the rule's 3-line window — same upstream lint debt family |
| 139 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-workspace-fields` | Mirrors all additive workspace fields onto `WorkspaceSyncRecord`, including optional unread count and optional pane ids. Custom decoding is lenient; record equality distinguishes `nil`, `[]`, and changed pane arrays so capability and pane-only deltas survive the v2 mirror |
| 140 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-workspace-fields` | Builds the Mac v2 workspace record from the same augmenter as the legacy list, then adds count and always-present exact pane ids independently of project association. Both transports therefore serialize one Mac-authoritative unread projection |
| 141 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+StateSync.swift` | `supermux-mobile-workspace-fields` | Projects every record field through the shared workspace-list apply path, including `supermuxUnreadPanelIDs`; without this the ring/capability state would vanish as soon as v2 negotiates |
| 143 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` | `unfenced` | **Pre-existing registry gap, surfaced (not caused) by the 0.64.21 merge.** Whole fork-owned file living inside the upstream `CmuxSettingsUI` package — the Vercel AI Gateway key + model card mounted by #18. It sits in the upstream package only because `SettingsWindowScene.sectionStack` is a closed, hard-coded list with no app-side injection seam, and that package cannot import `SupermuxKit` (reverse dependency). #18's prose mentioned the file in passing but it had no row, so the check did not guard its existence. Registered on the #68/#69 precedent: an upstream restructure of the package that drops it would otherwise pass silently |
| 144 | `scripts/cleanup-dev-builds.sh` | `unfenced` | **Pre-existing UNFENCED fork edit, surfaced (not caused) by the 0.64.21 merge — a real fence still needs to be ADDED to the file** (see the #144 re-apply note; this row is a placeholder until then). The running-app tag regex is `cmux\ DEV\ ([A-Za-z0-9-]+)\.app` instead of upstream's `cmux\ DEV\ ([A-Za-z0-9._-]+)`, so the captured slug matches the `cmux-<slug>` DerivedData directory name. Upstream's greedy class ate the `.app` suffix and yielded `<slug>.app`, silently defeating the running-app protection (cleanup could delete DerivedData for a tag that is still running) |
| 146 | `Sources/ContentView.swift` | `sidebar-usage-button` | In `SidebarFooterButtons`, the `shows(.help)` branch mounts the fork's `SupermuxUsageMenuButton()` (`Sources/Supermux/SupermuxUsageMenuButton.swift`, pbxproj ids `50BE0001…00FD`/`…00FE` under #3) **immediately before** upstream's untouched `SidebarHelpMenuButton(onSendFeedback:)` — a purely additive one-line insert. The button is a usage-gauge ring opening the unified Claude Code + Codex usage-limits popover (SupermuxKit `Usage/` + `SupermuxUsagePopoverView`; Claude via `cswap list --json` when installed, else the OAuth usage endpoint read-only; Codex via the ChatGPT usage endpoint with `~/.codex/auth.json`, session-log fallback) |
| 147 | `.github/workflows/ci.yml` | `local-release-script-guard` | Runs the fork-owned `tests/test_supermux_release_stale_artifact.sh` in Linux preflight so the local Release scripts must refresh GhosttyKit, clear stale explicit-module caches and DerivedData products, preserve xcodebuild's status, persist diagnostics, complete the mocked iOS release **before** the self-hosted Mac app shutdown/restart boundary, and exercise the current app + notification-extension production signing/install/launch path without touching a real app or device |
| 146b | `Sources/ContentView.swift` | `sidebar-usage-analytics-button` | In `SidebarFooterButtons`, the `shows(.help)` branch mounts the fork's `SupermuxUsageAnalyticsMenuButton()` (`Sources/Supermux/SupermuxUsageAnalyticsMenuButton.swift`, pbxproj ids `50BE0001…00FF`/`…0100` under #3) **immediately after** the usage-limits button of #146 and before upstream's untouched `SidebarHelpMenuButton(onSendFeedback:)` — a purely additive one-line insert. The button opens a token-spend popover (SupermuxKit `UsageAnalytics/` + `UI/SupermuxUsageAnalyticsPopoverView.swift` + `UI/SupermuxUsageAnalyticsChart.swift`) computing per-day, per-model cost from Claude Code's `~/.claude/projects/**/*.jsonl` transcripts and Codex's `~/.codex/sessions/**/rollout-*.jsonl` logs, read-only, with a per-file scan cache in Application Support |
| 148 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableItem.swift` | `supermux-mobile-projects-table-row` | **The row that renders Projects on iPhone.** Upstream 0.64.20 rebuilt the iOS workspace list on `UITableView`; the #97 mount stayed in the now-macOS-only `#else` arm, so the whole fork Projects surface (detail, worktrees, presets, run, actions, editor) was DEAD on iOS from that merge until #148–#151 existed. Two fences: `WorkspaceListChromeKind.supermuxProjects`, and its stable `id` `"chrome.supermuxProjects"`. **Chrome is load-bearing, not cosmetic.** `chromePrefixCount` counts a LEADING `.chrome` run, and the drag-reorder handler subtracts it to map UIKit rows onto SwiftUI workspace indices — a non-chrome row above the workspaces would silently move the WRONG workspace while every range guard still passed. `.chrome` additionally already means forbidden-as-drop-target, non-movable, no workspace lookup, and no native swipe/context menu. The id must NEVER vary with project expansion, or a disclosure becomes a structural change and triggers a whole-table `reloadData()` that destroys the section's animation and hosted state. Pinned by `SupermuxProjectsTableRowTests` |
| 149 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTable.swift` | `supermux-mobile-projects-table-row` | Two fences: `import SupermuxMobileUI`, and the optional `supermuxProjects: SupermuxProjectsTableRowConfiguration?` payload (defaulted `nil`, so upstream call sites need no change). A `nil` payload means the table emits no Projects row at all — a fork phone paired with an upstream Mac renders exactly upstream's list. See #148 |
| 150 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-projects-table-row` | Six fences: `import SupermuxMobileUI`; `HeightKind.supermuxProjects(String)`; a dedicated zero-margin `configure` branch (the shared `.chrome` 8/12 banner margins would double the section's own insets — it must come BEFORE the general `case .chrome`); the `hostedView` branch mounting `SupermuxProjectsTableSection`; the `heightCacheKey` branch; and the `itemPayloadChanged` branch. Height is keyed on `SupermuxProjectsTableRowConfiguration.heightIdentity` — a LAYOUT identity, not the full snapshot — so live activity/PR/run/unread repaints never push the whole section through `systemLayoutSizeFitting`. See #148 |
| 151 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Table.swift` | `supermux-mobile-projects-table-row` | Four fences: `import SupermuxMobileUI`; the `supermuxProjectsRowConfiguration` helper; the `items.append(.chrome(.supermuxProjects))` **inside the leading chrome run** (immediately after the connection-chrome switch, before groups/workspaces — see #148 on why the position is load-bearing); and the `supermuxProjects:` argument, bound to a `let` OUTSIDE the memberwise init because that expression already overwhelms the type checker. See #148 |
| 152 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `mobile-event-liveness-observation`, `mobile-liveness-background-gate` | Keeps per-envelope liveness bookkeeping (`lastTerminalEventAt` and the consecutive-probe counter) out of Swift Observation, and makes the render-grid liveness watchdog foreground-only both before a probe starts and when an already-started probe completes. The timer deliberately stays on `.main`; only the recovery decision is gated. Regression coverage: #154 |
| 153 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellRenderGridLivenessTestSupport.swift` | `mobile-liveness-background-gate` | Adds a delayed-success probe mode to the existing scripted liveness router so #154 can deterministically prove that a probe started just before backgrounding cannot publish a late recovery. The pre-existing held-probe mode still returns no response and remains unchanged |
| 154 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellEventStreamPerformanceTests.swift` | `unfenced` | Whole fork-owned Swift package test file in the upstream `CmuxMobileShellTests` target. Proves high-frequency event liveness timestamps update without Observation notifications, backgrounded watchdog ticks start no probes, and an in-flight probe completing after background cannot publish recovery |
| 155 | `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxTailscaleRouteProof.swift` | `tailscale-packet-tunnel-proof` | Fixes two Network.framework packet-tunnel behaviors that broke physical-device Tailscale pairing. First, a ready tunnel path may report `localEndpoint == nil`; absence is now accepted, while a present endpoint must still equal a proven Tailscale self-address. Second, the generic authority generation may advance immediately after connect even when the security-relevant route is identical; generation equality is no longer required because validation re-proves the current path status, exact Tailscale interface identity and self-address set, active connection-path interface, peer address, and peer port on every path update and before each write. The first bug rejected every authorized dial before credentials; the second connected successfully and then tore down the session about 300 ms later |
| 156 | `Packages/iOS/CmuxMobileTransport/Tests/CmuxMobileTransportTests/CmxTailscaleRouteProofTests.swift` | `tailscale-packet-tunnel-proof` | Regression coverage for #155: validation succeeds when Network.framework omits the local endpoint and when only the authority generation changes on an otherwise identical route. It still fails closed for a present-but-wrong local address and for a substituted interface even when that replacement carries the same Tailscale self-addresses |
| 157 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift` | `mobile-rpc-client-work-quota` | Backpressures the phone's multiplexed RPC writer against `MobileHostRPCWorkQuota` instead of letting post-pairing bootstrap fan out enough requests for the Mac host to close the entire connection as `rpc work capacity exceeded`. `PendingWrite` carries the decoded payload byte count; the session tracks only requests already sent and still awaiting a host response, mirrors both the host's request-count and aggregate-byte policies, and keeps one request slot free because the client may receive a response just before the host actor removes that response task. A host response or teardown wakes the writer; requests cancelled or timed out before transmission are skipped when capacity becomes available |
| 158 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession+IndependentEvents.swift` | `mobile-rpc-client-work-quota` | Releases the client-side work-quota slot as soon as any response id returns, before checking whether the local caller is still pending. This is required because a timed-out or cancelled caller may still receive the host's late response; ignoring that response would leak one writer slot for the rest of the session |
| 159 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileCoreRPCSessionPipelinedTests.swift` | `mobile-rpc-client-work-quota` | Red/green regression for #157–#158. Enqueues one more request than the client's host-compatible window, proves the extra request is not written while all earlier responses are outstanding, then delivers one response and proves exactly one queued request advances. Before #157 the writer immediately sent the whole burst and the expectation failed |
| 160 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+PairedMacPersistence.swift` | `paired-mac-persistence-result` | Makes `persistPairedMacFromTicket` report success only after the authoritative store mutation actually lands. The result now starts `false` and flips to `true` after either ordinary `upsert` or an accepted conditional route upsert; losing `ifStillCurrent` authority, crossing a team-scope boundary, or a conditional rejection can no longer return `true` while writing nothing. This closes the state where pairing reports `.connected` but `hasKnownPairedMac` and the SQLite store remain empty |
| 161 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobilePairedMacPersistenceFailureTests.swift` | `paired-mac-persistence-result` | Red/green regression for #160. Supplies `ifStillCurrent: { false }`, proves persistence returns `false`, leaves the store empty, and does not set the known-Mac hint. Before #160 the serialized operation was skipped but the method returned `true` |
| 162 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileMacBuildCompatibilityPolicy.swift` | `official-ios-persistence-scope` | Adds `persistenceScope(from:)`, making compatibility policy authoritative over storage partitioning. Development policy retains the detected iOS tag; official policy discards it. This matters for personal-team Release builds signed under a `dev.cmux.ios.<suffix>` bundle id: bundle metadata looks tagged, but Release compatibility correctly allows Stable/Nightly Macs and must not wrap storage in an inner exact-development-tag filter that silently rejects those same rows |
| 163 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileMacBuildCompatibilityPolicyTests.swift` | `official-ios-persistence-scope` | Regression coverage for #162: official policy maps a detected sideload tag to no persistence scope, while development policy retains the exact same scope |
| 164 | `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift` | `official-ios-persistence-scope` | In `makeStore`, separates the raw bundle-detected scope from the effective persistence scope. Build compatibility is resolved first, then `persistenceScope(from:)` supplies the value used by `IOSBuildScopedPairedMacStore` and backup-client partitioning. Debug tagged builds remain isolated; sideloaded Release builds use official untagged persistence and can save the Stable/Nightly Mac they already passed live compatibility checks against |
| 168 | `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Config/GhosttyConfig.swift` | `ghostty-bold-is-bright-mobile-theme` | Mirrors Ghostty's `bold-is-bright` compatibility alias into the Swift config model as `boldColor = "bright"`. Ghostty itself still honors this legacy key, but the Swift parser previously ignored it, so the Mac producer rendered bold ANSI 0–7 through bright palette 8–15 while exporting a phone config with no bold-color behavior |
| 169 | `Packages/macOS/CmuxTerminalCore/Tests/CmuxTerminalCoreTests/GhosttyConfigBoldColorTests.swift` | `ghostty-bold-is-bright-mobile-theme` | Parser regression for #168: `bold-is-bright = true` resolves to the same canonical `"bright"` value as `bold-color = bright` |
| 170 | `cmuxTests/MobileHostTerminalThemeTests.swift` | `ghostty-bold-is-bright-mobile-theme` | End-to-end host-theme regression for #168: parses the legacy alias, serializes the actual mobile host theme payload, decodes it as the phone does, and proves `bold-color = bright` survives into Ghostty directives |
| 171 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridVisualSnapshot.swift` | `verified-replay-semantic-bold-color` | Verified replay compares bold default/palette foregrounds by their semantic source (and palette index) rather than config-dependent resolved RGB. Literal RGB remains exact. This prevents a stale/legacy host theme from freezing an otherwise identical terminal grid behind a blank verification layer while #168 repairs authoritative theme propagation |
| 172 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/MobileTerminalRenderGridVisualSnapshotTests.swift` | `verified-replay-semantic-bold-color` | Regression for #171 using the physical-device mismatch values: equal bold palette semantics compare equal across normal-vs-bright resolved RGB, different palette indices still fail, and bold literal-RGB differences remain exact |
| 173 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift` | `ios-terminal-native-scroll` | Feeds each authoritative render-grid frame's active screen into the mounted surface after successful verified or legacy application, selecting bounded primary-history physics versus alternate-screen wheel delivery. Ported from upstream PR #9762 head `1420c2c972` |
| 174 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttyRuntime.swift` | `ios-terminal-native-scroll` | Processes Ghostty scrollbar actions in all build configurations, updates the surface's authoritative history boundary on the main actor, and keeps the stress-harness/logging extras DEBUG-only. Ported from upstream PR #9762 |
| 175 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+LocalScrollbackScroll.swift` | `ios-terminal-native-scroll` | Delivers local mirror scrolling as precise pixel deltas (one Ghostty cell height per logical line) and re-runs bounded idle resynchronization when the serialized local-apply pump drains. Ported from upstream PR #9762 |
| 176 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplay.swift` | `ios-terminal-native-scroll` | Sizes the frozen verified-replay container through bounds/position rather than frame so its native-scroll transform does not corrupt geometry. Ported from upstream PR #9762 |
| 177 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplayFrozenPresentation.swift` | `ios-terminal-native-scroll` | Carries native-scroll translation on the frozen container only; the copied content layer deliberately does not inherit the renderer transform, preventing double translation during verified replay. Ported from upstream PR #9762 |
| 178 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-native-scroll` | Replaces the million-point unbounded primary-screen surrogate with authoritative bounded history geometry, UIKit tracking/rubber-band behavior, sub-row presentation translation, gesture-end tail flushing, and deterministic settle/resync. Every release stops at the finger-selected position—terminal scrolling intentionally has no inertial coast. The scroll view uses a zero deceleration rate, and end-drag unconditionally resets its pan recognizer plus current offset because physical iOS 26 can resume already-committed physics after a target-offset pin. Bounded history is used only when the local mirror owns presentation; Mac-authoritative verified sessions and alternate-screen TUIs retain unbounded wheel delivery. Ported and hardened from upstream PR #9762 |
| 179 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressCoordinator.swift` | `ios-terminal-native-scroll` | Declares the local-only stress harness's screen as primary so bounded production scrolling is exercised without a paired Mac frame; its defaulted native-scroll-only mode stops after seeding/bottoming, leaving an unobstructed terminal for gesture automation while preserving the original composer viewport stress by default |
| 180 | `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Mobile.swift` | `ios-terminal-native-scroll` | Converts phone logical-line scroll input to Ghostty precise pixel deltas on the authoritative Mac surface, preserving fractional accumulation and mode-correct alternate-screen reporting. Ported from upstream PR #9762 |
| 181 | `ios/cmuxUITests/cmuxUITests.swift` | `ios-terminal-native-scroll` | Adds a real UIKit gesture regression over the unobstructed native-scroll stress harness: an outward bottom drag stays within authoritative history, then both fast and slow in-history drags move only their physical distance plus a small settle tolerance, start no deceleration, and produce no post-release drift. Settle leaves zero residual translation/tracking. Adapted from upstream PR #9762; transient geometry stays covered deterministically by #184 |
| 182 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/TerminalNativeScrollGeometry.swift` | `unfenced` | Whole new pure-value geometry model from upstream PR #9762: maps Ghostty row boundaries to UIKit points, clamps authoritative range, computes precise row deltas, fail-closed zero-range behavior, rubber-band translation, and bounded sub-row compensation |
| 183 | `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/GhosttySurfaceNativeScrollTests.swift` | `unfenced` | Whole new integration coverage based on upstream PR #9762: proves bounded primary history is disabled for Mac-authoritative verified replay, and proves fractional local precise scroll accumulates below one row then moves exactly one row after the remainder arrives |
| 184 | `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/TerminalNativeScrollGeometryTests.swift` | `unfenced` | Whole new pure geometry suite based on upstream PR #9762 covering real ranges, fractional rows, top/bottom rubber-band, renderer-lag clamping, appended history, fail-closed missing bounds, and pending-scroll resync deferral. Release behavior is exercised through the real UIScrollView gesture path in #181 rather than geometry policy |
| 185 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressView.swift` | `ios-terminal-native-scroll` | Adds a defaulted `nativeScrollOnly` DEBUG-harness mode and passes it into the representable, leaving the existing viewport-shrink stress behavior unchanged by default |
| 186 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressRepresentable.swift` | `ios-terminal-native-scroll` | Threads the native-scroll-only DEBUG harness mode into `MobileBottomScrollStressCoordinator` so the gesture UI test gets an unobstructed terminal instead of the composer/keyboard stress overlay |
| 187 | `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift` | `ios-terminal-native-scroll` | Adds the DEBUG-only `CMUX_NATIVE_SCROLL_STRESS=1` route to `MobileBottomScrollStressView(nativeScrollOnly: true)` before the existing full bottom-scroll stress route. The same file's official persistence-scope change remains separately registered as #164 |
| 189 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalAlternateScrollBudget.swift` | `unfenced` | Whole new fork file: token-bucket budget over alternate-screen wheel-line magnitude (burst 4, refill 20/s — dogfood tuning points, not measured TUI service rates; excess dropped never queued). Bounds the downstream backlog (RPC → Mac PTY → TUI repaint → phone frame) that a fast drag builds, which otherwise plays out after touch-up as phantom momentum. Physical trace proved the phone's UIScrollView emits zero post-release scroll events while the user still saw coasting. Backwards-clock steps refill nothing and keep the newer stored timestamp so a recovered clock cannot double-count an interval |
| 190 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-alt-scroll-budget` | Adds `terminalAlternateScrollBudgetsBySurfaceID` storage: declared beside the scroll queue state, initialized empty, cleared on reconnect state reset, and removed per-surface on surface teardown |
| 191 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalScrollDelivery.swift` | `ios-terminal-alt-scroll-budget`, `ios-terminal-scroll-speed` | In `scrollTerminal`, when the surface's confirmed active screen is `.alternate`, admits lines through the per-surface `TerminalAlternateScrollBudget` in UNSCALED gesture units (`admit(lines:speed:at:)` with the resolved scroll-speed preference) and drops the excess before prefetch/enqueue — so the cap scales with the Settings slider instead of erasing it on fast drags. Primary and unknown screens are untouched. Also corrects the doc comment that still attributed post-lift deltas to native iOS deceleration (physically disproven) |
| 192 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalAlternateScrollBudgetTests.swift` | `unfenced` | Whole new regression suite for #189: burst pass-through with sign, fast-drag surplus dropped and never deferred, sustained refill-rate drag unthrottled, direction reversal spends magnitude, exhausted-burst reversal admits only refilled capacity, backwards clock safety including post-recovery no-double-count, zero no-op, and a replay of the traced physical fast gesture proving the limiter engages |
| 193 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalOutputDelivery.swift` | `ios-terminal-output-backlog-coalesce` | Caps the per-surface pending render-grid frame queue at `maxTerminalOutputPendingBeforeReplayCoalesce` (24). Physical traces measured 90+ nonreplaceable alt-screen deltas queued during a fast scroll, draining serially for up to 4 s after touch-up — the real "phantom momentum". Past the cap the whole backlog is replaced by one authoritative replay through the standard rebuilt-surface barrier path (queue cleared, stream token rotated, stale acks invalidated) |
| 194 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-output-backlog-coalesce` | Declares the backlog cap constant beside the replay-barrier fail-open constant (~0.5 s of 60 Hz frames: steady output never trips it; a gesture backlog cannot replay for seconds) |
| 195 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalOutputBacklogCoalesceTests.swift` | `unfenced` | Whole new regression for #193: with the in-flight chunk never acknowledged (slow verified apply), frames past the cap must collapse into a replay barrier with the pending queue cleared, instead of queuing unbounded deferred paints |
| 196 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalScrollSpeedPreference.swift` | `unfenced` | Whole new fork file: shared UserDefaults-backed terminal scroll-speed multiplier (0.25×–1.5×, default 1.0, clamped, non-finite falls back). Read by Settings and by mounted surfaces |
| 197 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-native-scroll` | (Amends #178's file) Adds `scrollSpeedMultiplier` (didSet rejects non-positive values) applied in `enqueueScrollMechanicsDelta` so wheel-line delivery — alt-screen TUIs and unbounded paths — scales with the user preference; bounded primary history remains 1:1 direct manipulation |
| 198 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileDisplaySettings.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` preference: clamped write-through beside `terminalScrollbackRows`, seeded from defaults in init |
| 199 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileSettingsView.swift` | `ios-terminal-scroll-speed` | Adds the Display-section "Terminal Scroll Speed" slider (tortoise/hare, 0.05 step, live value label, footer) bound to `displaySettings.terminalScrollSpeed`, plus the `CMUXMobileCore` import. Accessibility id `MobileSettingsTerminalScrollSpeed` |
| 200 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` input and applies it to the mounted surface's `scrollSpeedMultiplier` in `makeUIView` and every `updateUIView` pass, so slider changes take effect live without remount. The same file's screen-selection change remains registered as #173 |
| 201 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` computed accessor beside the other display-settings accessors. The same file's workspace-tools mount remains registered as #108 |
| 202 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+TerminalArtifacts.swift` | `ios-terminal-scroll-speed` | Passes `terminalScrollSpeed` into `GhosttySurfaceRepresentable` at the terminal mount site |
| 203 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalAltScrollDirectApplyPolicy.swift` | `unfenced` | Whole new fork file: pure policy deciding when an alternate-screen repaint delta may skip the verified freeze/apply/present/read-back/verify pipeline — non-full frames within 0.8 s of the surface's last alt-screen scroll input. Backwards clocks fail closed; full frames always verify |
| 204 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-alt-scroll-direct-apply` | Adds `terminalAlternateScrollLastInputAtBySurfaceID` (declared beside the scroll budgets, initialized empty, cleared on reconnect reset, removed on surface teardown) |
| 205 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalOutputDelivery.swift` | `ios-terminal-alt-scroll-direct-apply` | In `requiresVerifiedReplayApplication`, alternate-screen delta frames inside the scroll-activity window return `false`, routing them through the ordered legacy VT-patch apply (same bytes, same stateSeq floors, no per-frame Metal fence). Gesture repaints stop clumping; the first verified delta after the window re-checks pixel exactness and drift triggers the existing full-replay recovery. Registered separately from the same file's #193 backlog coalesce |
| 206 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalScrollDelivery.swift` | `ios-terminal-alt-scroll-direct-apply` | Stamps the surface's last alt-screen scroll-input uptime whenever the budget admits gesture lines, opening the direct-apply window. Registered separately from the same file's #191 budget |
| 207 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalAltScrollDirectApplyPolicyTests.swift` | `unfenced` | Whole new regression for #203: in-window deltas apply directly, out-of-window and no-input deltas stay verified, full frames always verify, backwards clocks fail closed |
| 208 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalAlternateScrollLineQuantizer.swift` | `unfenced` | Whole new fork file: signed fractional-line accumulator that emits only whole alternate-screen scroll lines toward the Mac. Root cause of the "slider does nothing" feel: fractional gesture packets (0.03–0.11 lines each) were rounded up to a full line PER RPC by host-side minimum-magnitude-1 wheel handling, so TUI scroll speed tracked packet rate, not finger travel — physical trace showed a 29 pt drag delivering 0.70 fractional lines across 101 packets yet scrolling far more |
| 209 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-alt-scroll-quantize` | Adds `terminalAlternateScrollQuantizersBySurfaceID` (declared with the other scroll state, initialized empty, cleared on reconnect reset, removed on surface teardown) |
| 210 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalScrollDelivery.swift` | `ios-terminal-alt-scroll-quantize` | After the budget admits alt-screen lines, runs them through the per-surface quantizer and forwards only the whole-line portion (fractions carry). Registered separately from the same file's #191 budget and #206 activity stamp |
| 211 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalAlternateScrollLineQuantizerTests.swift` | `unfenced` | Whole new regression for #208: fractions accumulate before any emit, whole lines pass with carry, reversal unwinds signed carry, non-finite ignored, and 1× vs 0.25× delivery now differs ~4× per identical finger travel |
| 212 | `Sources/AppDelegate+DockShortcutRouting.swift` | `run-shortcut-dock-routing` | Adds all five fork shortcut actions (`supermuxToggleRun`, `supermuxWorkspaceSwitcherNext/Previous`, `supermuxCommit`, `supermuxCommitAccelerator`) as one `.mainContainer` case to upstream's deliberately-exhaustive Dock-routing switch. Upstream added this file with no `default:` so every action must be classified; all fork actions target app/workspace/project state, never a surface tree, so none reroute into the Dock. Re-apply: add the fenced five-case `case ...: .mainContainer` before the closing brace of `dockShortcutRoutingDisposition` |
| 213 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-host-keyboard-sync` | **Fixes "keyboard covers the terminal" (upstream regression in `ba47b1dc0d`).** Upstream moved the keyboard layout guide onto `GhosttySurfaceHostView` and made it the ONLY keyboard-geometry source — but on a physical iPhone 17 Pro (iOS 26) the host's `UIKeyboardLayoutGuide.layoutFrame` **never arms**: KBDIAG traced it staying a zero-size rect (or bare safe-area) for the entire keyboard-up period, so guide-derived `keyboardHeight` stayed 0 and the grid kept full height under the keyboard; the dock rode the same dead guide. SIX fenced blocks: (1)+(2) `advanceBottomDockTransition` re-samples `synchronizeKeyboardGeometryFromLayoutGuide()` every display-link frame and ORs `keyboardGeometryChanged` into the early-out guard; (3) `handleKeyboardWillChangeFrame` records `keyboardNotificationOverlap` from the notification end frame and calls `updateDockKeyboardFallbackConstant(transition:)` (animated on the keyboard's own curve); (4) the `keyboardNotificationOverlap` property + `updateDockKeyboardFallbackConstant` — the dock-to-guide constraint constant is derived as `-(overlap − guideGap)` so it SELF-NEUTRALIZES to 0 whenever the guide actually tracks (a healthy guide keeps sole authority); (5) `keyboardOverlapFromLayoutGuide` falls back to the notification overlap when the guide frame is zero-size / unseated / safe-area-only; (6) a convergence call in `synchronizeKeyboardGeometryFromLayoutGuide`. Offer upstream — stock cmux iOS has the dead-guide failure too. Re-apply: notification overlap as fallback authority everywhere the guide yields nothing, constraint compensation that subtracts the guide's own gap |
| 214 | `ios/cmuxUITests/cmuxUITests.swift` | `ios-terminal-host-keyboard-sync` | Regression teeth for #213 on the REAL keyboard path (`assertTerminalDockPinnedToSoftwareKeyboard`): upstream's assertions only proved the dock chrome tracked the guide — `renderMaxY`/`viewportHeight` derive from the same stale `keyboardHeight`, so they agreed even when both were wrong. The fenced block additionally asserts `keyboardHeight ≈ boundsHeight − keyboardGuideTop` (renderer model tracks the host guide) and `viewportHeight < boundsHeight − 120` (keyboard-up grid actually shrinks), with no synthetic keyboard-height override involved |
| 215 | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/ArrowlessPopoverAnchor.swift` | `popover-dynamic-height-reanchor` | Defers initial show, dismissal, and hosted-root layout until after `NSViewRepresentable.updateNSView` returns, preventing AppKit child-window ordering from re-entering SwiftUI/Observation mid-update. When an already-visible arrowless popover's content changes size, updates `contentSize` and re-shows the same popover against its original synthetic anchor so the edge stays fixed. Deferred work coalesces and rapid open→close cancels the pending show. Fixes the Usage Limits and Token Usage popover crash/drift paths |
| 215a | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/CmuxPopoverMutation.swift` | `popover-dynamic-height-reanchor` | Schedules coalesced popover mutations on the next common-mode main-run-loop turn instead of a main-actor task, because macOS 27 can run that task within the same AppKit layout cycle; generation checks preserve cancellation and rescheduling semantics |
| 215b | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/ArrowlessPopoverRootViewUpdatePolicy.swift` | `popover-dynamic-height-reanchor` | Changes first presentation from synchronous hosted-root mutation to deferred presentation, and treats dismissal as no root refresh; visible content updates retain their deferred path |
| 216 | `Packages/macOS/CmuxAppKitSupportUI/Tests/CmuxAppKitSupportUITests/ArrowlessPopoverRootViewUpdatePolicyTests.swift` | `popover-dynamic-height-reanchor` | Focused coverage for next-run-loop deferral/coalescing/cancellation, deferred first presentation and cancellation, dismissal skipping hosted-root refresh, visible resize/reanchor planning, subpixel jitter, and hidden/invalid no-ops |
| 217 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceActiveSurface.swift` | `ios-pane-actions` | Adds the captured close-target model and resolves the visible terminal/chat, phone-local browser, streamed browser, or Simulator into the exact pane the shared close action must address |
| 218 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-pane-actions` | Stores the pending pane-close target and Simulator-create request, mounts the shared confirmation, passes close/create availability and actions into the surface picker, cancels stale Simulator creates when another surface wins, and exposes the existing selection/toast seams to the fork-owned action extension |
| 219 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+SupermuxPaneActions.swift` | `ios-pane-actions` | Whole-file fork extension: one capability-gated action path captures and confirms the visible pane, closes phone-local browsers locally, closes every remote panel kind through `mobile.supermux.pane.close`, creates native Simulator panes through `mobile.supermux.simulator.create`, activates the returned stream descriptor, and reports failures without optimistic state drift |
| 220 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+Surfaces.swift` | `ios-pane-actions` | Routes the phone-local browser’s existing × button through the same captured-target confirmation used by the new picker action instead of keeping a second immediate-close path |
| 221 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenu.swift` | `ios-pane-actions` | Mounts `SupermuxPaneMenuControls` into the native surface picker so New Simulator and destructive Close Pane are available without duplicating localized SwiftUI menu code in the upstream package |
| 222 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenuValue.swift` | `ios-pane-actions` | Carries snapshot-stable `canCreateSimulator` and `canClosePane` availability into the equatable native menu value |
| 223 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenuActions.swift` | `ios-pane-actions` | Carries the shared Simulator-create and pane-close closures emitted by the surface picker |
| 224 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceActiveSurfaceTests.swift` | `ios-pane-actions` | Behavior coverage that terminal and chat target the selected terminal, the phone-local browser targets local close, streamed browser/Simulator target their panel ids, and missing remote ids fail closed |
| 225 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/TerminalPickerMenuValueTests.swift` | `ios-pane-actions` | Verifies pane action availability participates in the menu’s equatable identity and defaults hidden against unsupported/upstream hosts |
| 226 | `ios/cmuxUITests/cmuxUITests.swift` | `ios-pane-actions` | End-to-end UI coverage on the local-browser fallback: the existing browser × opens the shared confirmation, cancel preserves the browser, and the new picker Close Pane action confirms and dismisses the same captured pane |
| 227 | `cmuxTests/SimulatorPanelIntegrationTests.swift` | `ios-pane-actions` | Pins the Mac-side generic close invariant for Simulator panels: `Workspace.closePanel(force:)` removes the Simulator while preserving the sibling terminal, matching the RPC handler’s type-agnostic mutation path |
| 230 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentLaunchEnvironmentPolicy.swift` | `ccx-resume-launcher` | Adds the non-secret `CMUX_CLAUDE_RESUME_LAUNCHER` capture key, accepts only the current user's standardized `~/.local/bin/ccx`, retains it only for Claude restores, and keeps arbitrary launcher paths and secrets outside the replay environment |
| 231 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift` | `ccx-resume-launcher` | When a captured Claude launch carries the validated ccx marker, builds `<ccx> --resume <session-id>` instead of replaying expanded ccx-generated Claude arguments; plain Claude keeps the upstream wrapper-routed argv |
| 232 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentRestorePlanner.swift` | `ccx-resume-launcher` | Threads captured launch environment into resume argv resolution and preserves the direct ccx executable while attaching the provider/session-bound one-shot restore authorization |
| 233 | `Sources/RestorableAgentSession.swift` | `ccx-resume-launcher` | Threads the captured launch environment through the app-side shared resume-argument builder so persisted prepared arguments and inline fallback restore both honor ccx |
| 234 | `CLI/cmux.swift` | `ccx-resume-launcher` | Threads the selected replay environment through hook-side resume argv generation so `surface.resume.set` publishes the same ccx-aware command as app-side restore planning |
| 235 | `Sources/SurfaceResumeCommandCanonicalizer+PortableAgentExecutable.swift` | `ccx-resume-launcher` | Recognizes a validated ccx executable in inline stored restore commands and attaches restore authorization without rewriting ccx to the ordinary Claude wrapper |
| 236 | `Packages/macOS/CMUXAgentLaunch/Tests/CMUXAgentLaunchTests/SupermuxCCXResumeLauncherTests.swift` | `unfenced` | Whole-file headless regression coverage for direct ccx restore, one-shot authorization, secret exclusion, Claude-only marker isolation, and invalid-marker fallback to ordinary Claude |
| 228 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-workspace-toolbar-persistent-actions` | Consolidates the workspace-detail toolbar so UIKit's native overflow ("More") can never trigger: ONE trailing `ToolbarItem` with the fixed [Agent Chat][terminal picker] cluster, and the lower-frequency actions moved into the workspace TITLE menu via `workspaceTitleToolMenuEntries` — upstream Changes (id `MobileChangesButton`, title carries live +N/−M), the fork rows via `SupermuxWorkspaceToolsMenuEntries` (#108 bindings), and the alt-screen notice row presenting the shared explanation popover (anchored on the detail body). Replaces the conditional `workspace-altscreen-notice` / `workspace-changes` items (and the fork's former separate entries) whose state-varying widths made iOS evict a varying subset into a native ••• per pane. Also fences: the widened title-menu `isEnabled` gate + `toolEntriesFingerprint` plumbing (`WorkspaceTitleMenuValue.swift`, same id — defeats `.equatable()` pinning a stale menu closure), the `isSupermuxChangesSheetPresented`/`isSupermuxFilesSheetPresented`/`isAltScreenExplanationPresented` state, `onChange` keyboard-dismiss parity for the fork sheets, the deferred-one-turn presentation in `openWorkspaceChanges` (menu-dismissal race), and the badge-headroom reserves (`backButtonReserve` 44→60, `floor` 96→80) in `MobileLeadingToolbarTitleWidth.swift` (same fence id) |
| 229 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+AgentChat.swift` | `ios-workspace-toolbar-persistent-actions` | Makes `shouldShowChatToggle` structurally true and fixes `toolbarTrailingCluster` at two 44pt controls (96pt frame): the Agent Chat button is always mounted, merely disabled (with an accessibility hint) until the visible tab has a session, so agent/pane churn never changes the bar's shape. Companion fence in `AltScreenNoticeButton.swift` (same id) extracts `AltScreenNoticeExplanationContent` + `altScreenNoticeExplanationPopover(isPresented:dismissNotice:)` so the standalone notice button and #228's title-menu row present identical content |
| 237 | `ios/cmuxUITests/cmuxUITests.swift` | `ios-workspace-toolbar-persistent-actions` | Reverses upstream's no-session expectation in the long-title workspace-toolbar preview: the Agent Chat button must remain present-but-disabled without a chat descriptor, and native toolbar overflow (`More`) must not replace the stable action cluster |
| 238 | `ios/Config/Shared.xcconfig` | `ios-supermux-brand` | `PRODUCT_DISPLAY_NAME` = `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (was `cmux`), the iOS app's home-screen name. `SUPERMUX_IOS_DISPLAY_SUFFIX` (new fork variable, empty default) lets dogfood builds append `" <tag>"` from the command line without passing `PRODUCT_DISPLAY_NAME` itself. `PRODUCT_NAME` stays `cmux` on purpose — it names the built product (`cmux.app`), which every reload/install/queue script resolves by path |
| 239 | `ios/Config/Release.xcconfig` | `ios-supermux-brand` | Local Release builds display `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (was `cmux BETA`; suffix empty → `Supermux`). The TestFlight/App Store lanes pass `PRODUCT_DISPLAY_NAME` on the xcodebuild command line (`ios/scripts/upload-testflight.sh`, `ios/scripts/resolve_testflight_distribution.py`), so upstream channel names and `tests/test_ios_testflight_pro_distribution.py` are untouched |
| 240 | `ios/scripts/reload.sh` | `ios-supermux-brand` | Tagged dev builds display `Supermux DEV <tag>` (was `cmux DEV <tag>`). The tag suffix is kept so parallel tagged installs stay tellable apart; the `cmux.app` product path this script resolves is unchanged |
| 241 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires the ROOT `AppIcon.icon` + `AppIcon-Demo.icon` Icon Composer bundles into the iOS app target's Resources phase (ids `IC1000*`, `sourceTree = SOURCE_ROOT`, `path = ../AppIcon*.icon`) and deletes the upstream `AppIcon.appiconset` / `AppIcon-Demo.appiconset` PNG sets. iOS now renders from the same single source of truth as macOS (#17); no PNG icon art exists in the fork. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` was already correct and is unchanged |
| 242 | `ios/cmux/Assets.xcassets/CmuxLogo.imageset` | `unfenced` | The in-app brand logo (sign-in header, restoring-session screen) re-sourced from the supermux mark, squircle-masked, as a base64-PNG-in-SVG at the same path/name so no Swift call site changes |
| 243 | `.github/workflows/ios-testflight.yml` | `ios-supermux-brand` | The "Use DEMO-badged app icon" step replaces the whole `AppIcon.icon` directory with `AppIcon-Demo.icon` instead of copying three PNGs into `AppIcon.appiconset`, which no longer exists |
| 245 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileTerminalFontPreference.swift` | `ios-terminal-default-zoom` | Changes the built-in mobile terminal baseline from 10 pt to 12 pt, matching the desktop default and the fork's phone dogfood preference |
| 246 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileTerminalZoomPreference.swift` | `ios-terminal-default-zoom` | Exposes the resolved default font size (explicitly saved zoom, otherwise the 12 pt built-in) so new terminal mounts consume the same preference the floating controls mutate |
| 247 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-default-zoom` | Replaces the initializer's stale literal 10 pt default with `MobileTerminalFontPreference.defaultSize`, preventing the public surface default from drifting from the canonical preference |
| 248 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+TerminalArtifacts.swift` | `ios-terminal-default-zoom` | Mounts each newly selected terminal at `MobileTerminalZoomPreference.resolvedFontSize`, making the floating "Set as default" action affect subsequent terminal mounts instead of only the floating Reset action |
| 249 | `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/MobileTerminalZoomControlTests.swift` | `unfenced` | Whole-file regression coverage for the 12 pt built-in, saved-default persistence/clearing, and all three floating zoom buttons dispatching their actions |
| 250 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Toolbar.swift` | `supermux-mobile-list-toolbar-identity` | Moves the `showsNavigationToolbar` condition INSIDE the `.toolbar` builder instead of branching around `content`. Upstream's `if showsNavigationToolbar { content.toolbar {…} } else { content }` gave `content` a different structural identity per branch, so every workspace push/pop tore down and rebuilt `WorkspaceListTable` (a `UIViewControllerRepresentable`) — resetting scroll to zero, forcing a full `structureChanged` rebuild of every cell, and re-firing every hosted `.task`. Measured: push+pop built the representable 3× and moved the offset 1200 → 0 |
| 251 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-list-reconfigure-rows` | Splits the non-structural update path: rows whose height changed go through `reconfigureRows(at:)` (same cell instance, hosted SwiftUI state preserved, height still re-queried), while only rows with a changed native-action payload keep `reloadRows` (UIKit caches swipe-derived accessibility actions on the cell and reconfiguring does not invalidate them). Previously every height change reloaded, destroying the hosted subtree — which blanked the fork's project avatars, since the whole Projects section is one hosted cell and its decoded icons live in `@State`. Distinct from #150, which fences the same file for the Projects row itself |
| 252 | `Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/ChatFocusMode+Supermux.swift` | `agent-chat-focus-mode` | **Whole-file fork addition inside an upstream package** (same pattern as the other whole-file rows here). Declares `ChatTranscriptGrouping` (a row-array → entry-array regrouper plus a configuration `identity`), its `Entry` type, the `chatTranscriptGrouping` environment value, and the `.chatTranscriptGrouping(_:)` modifier. A `nil` grouping renders upstream byte-for-byte, so demos, previews, tests, and an upstream-paired phone are unaffected. New file — cannot conflict on merge |
| 253 | `Packages/iOS/CmuxAgentChatUI/Sources/CmuxAgentChatUI/Transcript/ChatTranscriptTableView.swift` | `agent-chat-focus-mode` | Seven fences: the `@Environment(\.chatTranscriptGrouping)` read; the `grouping` + `groupedEntries` fields on `ChatTranscriptTableConfiguration` and the arguments that fill them (**entries are computed ONCE in `updateUIView`**, not per cell, or the closure re-runs for every visible row while the transcript streams); `groupingReloadIdentity` + `groupedEntriesByID`; the `.groupedEntry(String)` item case and its `id`; the `makeItems()` branch emitting entries instead of rows; the cell-factory branch; and `groupingChanged` folded into `shouldReload`. **The reload fold is load-bearing**: expanding a group or flipping the setting can leave item ids identical, and without it the table keeps stale cells |
| 254 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileDisplaySettings.swift` | `ios-agent-chat-focus-mode` | Three fences: the `agentChatFocusModeKey` constant, the `agentChatFocusMode` observed property with write-through, and its seed in `init` (absent key reads as **true** — focus mode is the intended default, so a fresh install gets the quiet transcript without visiting Settings). Key is `supermux.mobile.agentChatFocusMode` |
| 255 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileSettingsView.swift` | `ios-agent-chat-focus-mode` | One fence at the top of the existing Display section: the **Focus Mode** toggle plus its explanatory footer, bound to `displaySettings.agentChatFocusMode`. Accessibility id `MobileSettingsAgentChatFocusMode`. The same file's terminal-scroll-speed slider remains registered as #199 |
| 256 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceChatPane.swift` | `ios-agent-chat-focus-mode` | Three fences: `import SupermuxMobileUI`, the `@Environment(MobileDisplaySettings.self)` read, and the `.supermuxChatFocusMode(isEnabled:)` modifier on the `ChatScreen` group. **This is the only line that turns focus mode on**; remove it and the phone renders upstream's transcript unchanged |
| 257 | `Packages/iOS/SupermuxMobileUI/Package.swift` | `unfenced` | Fork-owned manifest: adds `../../Shared/CmuxAgentChat` and `../CmuxAgentChatUI` package + target dependencies so the fork can name `ChatTranscriptRow` / `ChatRowActions` and re-render expanded rows with upstream's own `ChatTranscriptRowView`. Acyclic — `CmuxMobileShellUI` already depends on both |
| 258 | `ios/cmux/Resources/Localizable.xcstrings` | `unfenced` | Two `supermux.settings.agentChatFocusMode*` keys (en + ja) for the Settings toggle and its footer. The shell package resolves `L10n` against the **app** bundle, so these belong here, NOT in the `SupermuxMobileUI` package catalog (which carries the four `supermux.chat.focus.*` keys) |
| 259 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceShellView.swift` | `supermux-mobile-compact-root-chrome` | Nine fences. Everything that gated the phone's ROOT chrome on `compactNavigationPath.isEmpty` now reads `showsCompactRootChrome`, which folds in an in-flight interactive pop: the import, the `@State compactRootChrome`, the `showsCompactRootChrome` predicate, the compose-button gate, the `rootToolbarContent` gate, the destination's `.toolbarVisibility`, the `SupermuxInteractivePopObserver` mount, the `navigationPathChanged()` reset in `.onChange(of: compactNavigationPath)`, and the `showsNavigationToolbar` argument. See #260 for why |
| 260 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxCompactRootChrome.swift` | `unfenced` | **Fork-owned new file.** The predicate + the UIKit pop observer behind #259. Fixes two separate late-chrome bugs on the phone: (a) the top bar's items were absent for the whole edge-swipe back, because `NavigationStack` only writes the emptied path when the gesture COMMITS while UIKit reveals the root immediately — tapping the back button was clean, which is what pinned the cause; (b) the tab bar arrived ~1s late on BOTH back paths, because the `.toolbarVisibility(.hidden, for: .tabBar)` request lives on the pushed destination and that destination stays mounted, still asking for a hidden bar, for the entire pop animation. `SupermuxInteractivePopObserver` only adds a target-action to the pop recognizer — the DELEGATE stays with upstream's `InteractiveSwipeBackEnabler`, which owns whether the gesture may begin and how it arbitrates against terminal pans. A committed pop deliberately does NOT clear the flag (that would re-hide mid-animation); the path change does. `SupermuxCompactRootChromeTests` pins all six transitions |
| 261 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxUnreadBadgeStyle.swift` | `unfenced` | **Fork-owned new file.** The single description of the unread badge's geometry, count text and paint recipe, read by all three renderers (Mac SwiftUI, Mac AppKit, phone). Lives in the wire-contract package because that is the only one BOTH apps already depend on; it deliberately imports no UI framework, so the platforms own painting and share only proportions. Everything derives from the numeral's font size rather than absolute points, and the `99+` overflow marker resolves from the package localization catalog (#298). `SupermuxUnreadBadgeStyleTests` pins the cap, countless-dot fallback, one-digit circularity, the compact 9pt→14pt Mac height, and the phone's 10pt→16pt base height |
| 262 | `Packages/SupermuxKit/Sources/SupermuxKit/UI/SupermuxUnreadBadgeView.swift` | `unfenced` | **Fork-owned new file.** A thin Mac-named wrapper over the shared badge body in #281, adding no rendering of its own, plus the `appKitStops` projection of the shared gradient so the Core Graphics renderer (#267) paints the same wash rather than a hand-matched copy |
| 263 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadBadge.swift` | `unfenced` | **Fork-owned new file.** The phone's wrapper over the same #281 body, supplying the accent/white colors, the badge's accessibility posture, and `@ScaledMetric` headline-relative sizing so the capsule follows Dynamic Type |
| 264 | `Sources/Sidebar/SidebarWorkspaceUnreadBadge.swift` | `supermux-unread-badge-capsule` | Fenced replacement of upstream's flat accent `Circle` with a thin adapter over #262. The adapter takes the already-magnified numeral point size (see #282): the shared style derives every dimension from it, and recovering that from the badge's frame instead would silently drop the user's global font magnification |
| 265 | `Sources/Sidebar/SidebarWorkspaceLeadingStatusSlot.swift` | `supermux-unread-badge-capsule` | The slot relaxes from `.frame(width:height:)` + `.clipped()` to `.frame(minWidth:minHeight:)`. The badge is a capsule now, so a two-digit count is wider than tall; upstream's square frame and clip would together have sheared the second digit off. Height stays pinned so rows keep aligning on it |
| 266 | `Sources/Sidebar/SidebarWorkspaceTrailingStatusSlot.swift` | `supermux-unread-badge-capsule` | Same relaxation as #265. `width` is the close button's reserved width, which a two-digit capsule exceeds; it becomes a minimum so the badge grows leftward into the row instead of being clipped, while the close button and spinner still reserve exactly what they always did |
| 267 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowSlotViews.swift` | `supermux-unread-badge-capsule` | `SidebarRowUnreadBadgeView` paints capsule + gradient + rim in `draw(_:)` rather than composing layers — this is a pooled cell in a hand-laid-out list, and three sublayers per row is exactly the cost that list exists to avoid. Every VALUE comes from #261, so "matched to the SwiftUI badge" is a shared table, not a hand-tuned copy |
| 268 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCellView.swift` | `supermux-unread-badge-capsule` | `layoutContent` measures and draws the badge through the shared AppKit helper instead of assuming a `16 * fontScale` square; the leading advance and the trailing reservation both use the measured width so a wide badge can neither overlap the title nor be clipped. **Only the row-height calculation is floored at the old square**: the visible capsule keeps the shared compact proportions while a non-wrapping row's height remains unchanged. **The trailing reservation is deliberately keyed on whether the row HAS a badge, not on whether it is currently visible**: hover hides the trailing badge behind the close button, and keying off visibility would widen a wrapping title on hover, unwrapping a line — while the table holds the height it cached at `isPointerHovering: false`. Reserving unconditionally keeps row height hover-independent, which is what that cache assumes |
| 269 | `Sources/SidebarWorkspaceGroupHeaderView.swift` | `supermux-unread-badge-capsule` | The SwiftUI group header's own flat accent capsule routed through #262, so a header badge and the workspace badges beneath it stop being two different badges |
| 270 | `Sources/Sidebar/AppKitList/Cells/SidebarGroupHeaderRowView.swift` | `supermux-unread-badge-capsule` | The AppKit group header measures its badge through the shared style instead of its own `unreadHorizontalPadding`/`unreadVerticalPadding` metrics. Counts past 99 now measure as `"99+"`, which is also what gets drawn |
| 271 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-workspace-fields` | Additive unread count plus pane-id capability/state on the v2 record. Count and pane ids travel for every workspace, not only project-associated rows; absent/malformed values decode to `nil`, while an empty pane array stays distinct |
| 272 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-workspace-fields` | Sets unread count and exact pane ids beside the project augmenter. Count may be absent when the store is unavailable; pane ids are always an array on this supporting host so iOS can disable the legacy broad receipt |
| 273 | `Sources/TerminalController+MobileWorkspaceList.swift` | `mobile-supermux-workspace-fields` | Sends the same unread count and exact pane ids on the legacy list payload, keeping full-list and v2 semantics aligned |
| 274 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-workspace-fields` | Lossily decodes both `supermux_unread_count` and `supermux_unread_panel_ids` from a workspace row |
| 275 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-workspace-fields` | Carries count and pane ids into the preview model |
| 276 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-workspace-fields` | Stores defaulted optional unread count and exact pane ids so upstream initializers stay untouched and `nil` versus `[]` remains observable |
| 277 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+StateSync.swift` | `supermux-mobile-workspace-fields` | Carries count and pane ids through the v2 projection so badge and ring state do not disappear when v2 negotiates |
| 278 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceUnreadDot.swift` | `supermux-unread-badge-capsule` | Fenced replacement of upstream's bare 11pt accent dot in a permanently-reserved 10pt gutter with a thin wrapper over #263. It renders nothing when the workspace is read, instead of an invisible spacer — that gutter is what left a blank column down the whole list, most visibly on global workspace rows |
| 279 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceRow.swift` | `supermux-mobile-unread-badge` | The badge moves out of the leading gutter to sit inline after the workspace title, where Mail and Messages put it; `railLeadingOffset` drops to 0 since there is no gutter left to clear. `unreadIndicatorLeftShift` is kept as an accepted-but-inert parameter — it is a DEBUG-only developer slider that nudged the dot WITHIN the gutter, and keeping it leaves upstream's settings→table→row plumbing (ten files the fork otherwise never touches) byte-identical |
| 280 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceGroupHeaderRow.swift` | `supermux-mobile-unread-badge` | Same move for group headers: the badge trails the group name (matching the Mac header) and the chevron starts the row. Countless by construction — the header rolls its members up to a boolean, never a sum |
| 281 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxUnreadBadgeContent.swift` | `unfenced` | **Fork-owned new file.** The ONE SwiftUI badge body, rendered by both platforms — #262 and #263 are colour-supplying wrappers over it. An earlier revision had a Mac copy and a phone copy whose bodies were line-for-line identical, which is exactly the drift #261 exists to prevent; SwiftUI is cross-platform, so there was never a reason for two. Also holds `SupermuxUnreadBadgeGradient`, whose stops the AppKit renderer derives from rather than restates |
| 282 | `Sources/ContentView.swift` | `supermux-unread-badge-capsule` | Three fences replace upstream's opaque `badgeFont` plumbing with `badgePointSize` (the 9pt sidebar size put through `GlobalFontMagnification`) and pass it through both status-slot call sites. The shared style needs the numeric size; deriving it from the badge's frame would silently drop the user's global font magnification. This file's other fork edits are registered separately as #2 |
| 283 | `Sources/Mobile/MobileWorkspaceListObserver.swift` | `supermux-mobile-workspace-fields` | Subscribes to focused-read changes plus `Workspace.supermuxUnreadPanelIDsPublisher` for exact manual/restored pane-set changes, then folds both unread count and ordered pane ids into the per-workspace preview signature. Count-only changes update the numbered badge; A → A+B pane changes still emit while the workspace unread boolean remains true, so the phone's blue rings cannot stay stale |
| 284 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-unread-badge` | Adds the badge's drawn text to the `workspaceWrapped` row-height cache key. The badge is inline with the title now, so its presence and width steal room from a title that is allowed to wrap; a read → unread flip or 9 → 10 can push a barely-fitting title onto a second line. Keyed on the TEXT, not the count — 100 and 4000 both draw "99+" and must share a cache entry. Distinct from #150/#251, which fence this same file for the Projects row and the reconfigure path |
| 285 | `Packages/iOS/CmuxMobileShell/Package.swift` | `supermux-mobile-selection-sync` | Adds the lower-layer `SupermuxMobileCore` dependency to the shell target so the phone uses the same typed capability and method identifiers as the Mac router. No dependency on `SupermuxMobileKit`, so the existing package DAG stays acyclic |
| 286 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-selection-sync` | Integration fences store the serialized optimistic focus and reconciliation pipelines, the effective focused-panel value, and the panel whose Mac focus is ready for stream startup; send workspace plus the selected terminal/browser/Simulator when navigation or the picker changes; clear readiness with workspace/connection changes; and route list application through the fork reconciliation policy only when `supermux.selection_sync.v1` or `.v2` is advertised. Terminal selection compares the generic effective panel as well as `selectedTerminalID`, so choosing the already-selected terminal while browser/Simulator chrome is active still reclaims Mac focus. A created terminal uses the same chrome-selection action even under version skew. Older/upstream Macs retain the prior phone-local behavior |
| 287 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SupermuxSelectionSync.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Serializes rapid phone selections, uses v1 workspace/terminal RPCs for version skew and v2 `mobile.supermux.panel.select` for every panel kind, holds an optimistic request id against stale list frames, and returns a Boolean focus acknowledgement so stream startup can proceed as soon as Mac focus succeeds. A Mac state push that outraces the mutation's own RPC reply clears the pending intent as confirmed; the late reply (or a lost reply) for that exact selection still counts as success instead of abandoning the just-focused surface (the flash-then-revert on re-entering a browser/Simulator tab). Authoritative list reconciliation runs on a separate serialized tail; focus failure clears readiness and rolls back explicitly, while Mac-originated focus records immediate readiness |
| 288 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxSelectionSyncTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Pins Mac→phone workspace, terminal, browser, and Simulator focus; stale browser-frame suppression while a phone mutation is pending; a Mac confirmation that outraces the focus reply still counting as success while a superseded selection does not; focus-readiness gating for optimistic versus authoritative selections; v1 terminal fallback; and the upstream-host fallback |
| 289 | `Sources/Mobile/MobileWorkspaceListObserver.swift` | `supermux-mobile-selection-sync` | Subscribes to the existing deferred `.ghosttyDidFocusSurface` broadcast and folds the generic focused panel id+kind into the mobile summary hash. Focus-only terminal, browser, Simulator, or future-panel changes therefore emit both legacy `workspace.updated` and state-sync-v2 deltas |
| 290 | `cmuxTests/MobileWorkspaceListFidelityTests.swift` | `supermux-mobile-selection-sync` | Behavior coverage proving a focus-only terminal→browser→terminal transition changes the observer hash and that the legacy payload's generic `focused_panel` object reports the exact panel id and kind while terminal `is_focused` compatibility remains correct |
| 291 | `cmuxTests/MobileWorkspaceListFidelityTests.swift` | `supermux-mobile-workspace-fields` | A second, independent fence in the same file for #283: verifies the legacy payload carries `supermux_unread_count` for read and unread workspaces, then uses the observer's narrow count override seam to hold the latest notification and unread boolean fixed while the count falls 2 → 1. The two signatures must differ; reverting #283 turns this red |
| 292 | `Sources/Workspace+PanelLifecycle.swift` | `panel-scoped-shared-agent-lifecycle-clear` | When a panel-scoped `clear_agent_pid` targets a shared structured-agent key currently owned by a sibling panel, preserves that sibling's PID ownership but still clears the requesting panel's lifecycle. Claude Code deliberately uses the single `claude_code` key in every terminal, so the previous ownership-mismatch early return orphaned `running`/`needsInput` entries after non-owner SessionEnd hooks |
| 293 | `cmuxTests/AgentHibernationTests.swift` | `panel-scoped-shared-agent-lifecycle-clear` | Regression coverage for #292: two panels share `claude_code`, the second owns the sole PID slot, and ending the first must clear only the first panel's lifecycle while retaining the second panel's running state, PID, and ownership |
| 294 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-row-activity` | Mounts `supermuxWorkspaceActivityDot(rawActivity:)` on the real iPhone `UITableView` workspace row. The older #103 modifier lives on the SwiftUI `List` branch, which is not the iPhone renderer after upstream's table rebuild; without this fence every flat/global phone row ignored a correctly received `supermux_activity` value |
| 295 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCellView.swift` | `sidebar-appkit-row-activity` | Ports the working-state activity spinner to the locally opt-in AppKit sidebar row using its existing GPU spinner slots: `.working` bypasses upstream's default-off agent-spinner flag, paints amber, uses the Supermux tooltip, and participates in leading-slot spacing. The default SwiftUI sidebar remains unchanged |
| 296 | `cmuxTests/SidebarAppKitRowCellTests.swift` | `sidebar-appkit-row-activity` | Behavior coverage for #295 through the real AppKit cell configuration: a snapshot with `.working`, zero upstream active count, and `showsAgentActivity=false` still mounts exactly one visible spinner |
| 297 | `Packages/Shared/SupermuxMobileCore/Package.swift` | `unfenced` | Fork-owned package manifest: processes the shared core's `Resources` directory so the unread badge's overflow marker is localized from the same bundle on macOS and iOS |
| 298 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/Resources/Localizable.xcstrings` | `unfenced` | Fork-owned package catalog for `supermux.unreadBadge.overflow`, translated for every supported locale (English and Japanese; both use the compact numeric `99+` convention) |
| 299 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileWorkspaceFocusedPanel.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Forward-compatible `{panel_id, kind}` value shared by legacy workspace lists, state-sync-v2 records, the shell model, and UI presentation policy. Unknown kinds remain decodable so newer Macs cannot gap older phone mirrors |
| 300 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-selection-sync` | Adds optional, lossy-decoded `focused_panel` to every workspace record. Record equality includes it, so focus-only browser/Simulator changes produce a v2 delta instead of disappearing as no-ops |
| 301 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-selection-sync` | Projects `Workspace.focusedPanelId` plus the workspace's existing panel-kind mapping into the typed state-sync row, independently of terminal-only `is_focused` compatibility |
| 302 | `Sources/TerminalController+MobileWorkspaceList.swift` | `supermux-mobile-selection-sync` | Adds the same `focused_panel` object to legacy `mobile.workspace.list`, keeping the full-list and v2 transports byte-semantically aligned for terminal, browser, Simulator, and future panel kinds |
| 303 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-selection-sync` | Decodes optional generic focus leniently; absent upstream fields and malformed additive objects both become `nil` rather than failing the whole workspace row |
| 304 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-selection-sync` | Carries generic focused-panel identity from either transport into the immutable workspace preview |
| 305 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-selection-sync` | Stores optional Mac-authoritative focused-panel identity on each workspace snapshot, defaulted to `nil` so every upstream initializer remains source-compatible |
| 306 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+StateSync.swift` | `supermux-mobile-selection-sync` | Preserves `focused_panel` while projecting the v2 record mirror through the shared full-list apply path; without this line generic focus would work only on the legacy transport |
| 307 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-selection-sync` | Routes phone browser/Simulator picker selections through the shared shell mutation and shared activation sequence, captures the previous stream for unconditional teardown, abandons a failed/stale optimistic surface, and observes Mac-authoritative focus plus late browser discovery to mount the matching streamed surface without echoing either an RPC or a second activation back into the pipeline. Every transition uses the exact current focused-panel predicate, including Mac-originated changes. Terminal selection closes streamed chrome as before |
| 308 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceFocusedPanelPresentationTarget.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Pure presentation policy maps a generic focused panel to terminal, browser stream, Simulator stream, or unsupported; undiscovered/unknown panels preserve the current phone surface instead of showing an unrelated terminal |
| 309 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceActiveSurfaceTests.swift` | `supermux-mobile-selection-sync` | Behavior coverage for terminal/browser/Simulator presentation mapping plus unknown and not-yet-discovered panel fallback |
| 310 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/SupermuxWorkspaceSyncRecordFieldsTests.swift` | `supermux-mobile-selection-sync` | Record-wire coverage for generic focus and exact pane unread: wire shape, round-trip/equality visibility, upstream `nil`, supported-empty `[]`, and malformed additive-field tolerance |
| 311 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/SupermuxWorkspaceListFieldsDecodeTests.swift` | `supermux-mobile-selection-sync` | Decoder/preview coverage for generic focus and exact pane unread, including upstream absence, supported-empty arrays, and malformed objects/arrays degrading without failing the list |
| 312 | `cmuxTests/SupermuxMobileAuthorizationTests.swift` | `supermux-mobile-selection-sync` | Extends the exhaustive fail-closed method table for `panel.select`; workspace tickets may focus any panel in their workspace, while terminal-pinned tickets remain exact-panel only |
| 313 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-create-focus` | Adds `focus: true` to phone terminal creation and routes the returned terminal through the existing chrome-selection action instead of assigning the terminal id directly, keeping local presentation and Mac focus on the one shared mutation path while preserving the create flow's one-shot keyboard-autofocus suppression even when the atomic Mac response already reconciled the id |
| 314 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileBrowserCreateParameters.swift` | `supermux-mobile-create-focus` | Adds the default-true additive browser-create `focus` field, preserving source compatibility while requiring a new Mac to select the created panel before replying; older Macs ignore the unknown key |
| 315 | `Sources/TerminalController.swift` | `supermux-mobile-create-focus` | Honors additive `focus: true` on `terminal.create` by focusing the newly created terminal through the shared control action before serializing the response; if focus fails, closes the new panel through the shared history-aware close path and falls back to the captured bonsplit tab id if the panel mapping changed, so the phone never receives a half-created orphan. Calls without the flag keep background-create semantics |
| 316 | `Sources/TerminalController+MobileBrowser.swift` | `supermux-mobile-create-focus` | Applies the same atomic create-then-shared-focus contract to `mobile.browser.create`, with explicit cleanup on focus failure and unchanged background creation for old/no-flag callers |
| 317 | `cmuxTests/TerminalAndGhosttyTests.swift` | `supermux-mobile-create-focus` | Behavior coverage proving `focus: true` terminal, browser, and Simulator creation selects the owning Mac workspace and exact created panel, alongside the existing no-flag terminal/browser tests that pin backward-compatible background creation |
| 318 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileBrowserRPCDTOTests.swift` | `supermux-mobile-create-focus` | Wire coverage proving phone browser creation emits the exact additive `focus: true` field with the Mac-local workspace id |
| 319 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspacePanelStreamActivationSequence.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** One shared browser/Simulator transition path awaits the Boolean Mac-focus result, always tears down the previous captured stream, rechecks exact current selection after that suspension, explicitly abandons failed/stale current state, and only then starts the current stream |
| 320 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspacePanelStreamActivationSequenceTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Four race-level behaviors prove focus→stop→start ordering, unconditional previous-stream teardown for stale transitions, rejection when selection changes during the suspending stop, and abandonment rather than startup after focus failure |
| 321 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellCompositePreviewTests.swift` | `supermux-mobile-selection-sync` | Exact missed-bug coverage: with `selectedTerminalID` unchanged but browser or Simulator recorded as the effective panel, terminal-picker selection must restore terminal focus and chrome autofocus suppression; the deep-link entrypoint restores the same focus without chrome suppression |
| 322 | `Sources/Workspace+PanelLifecycle.swift` | `panel-agent-liveness-evidence` | Four fences closing the orphaned-indicator hole for shared agent keys: `recordAgentPID` records the reporting panel's process identity; both stale sweeps retire lifecycle entries whose recorded process is dead but whose PID slot a sibling stole, with the workspace-wide pass merging that mutation into its return value so notification cleanup still runs; and `clearAllAgentPIDs` drops the workspace's registry bucket during reset/teardown. Keys with no evidence or a still-live process are never touched |
| 323 | `Sources/Supermux/SupermuxPanelAgentEvidence.swift` | `unfenced` | **Fork-owned new file** behind #322: the per-(workspace, panel, status key) last-reported process-identity registry plus the `Workspace` sweep extension (`supermuxClearDeadPanelAgentLifecycle` / `supermuxSweepDeadAgentLifecycle`). The workspace sweep reports whether it mutated lifecycle, and reset/teardown can remove the whole workspace bucket. Evidence-only — retirement clears lifecycle through the same panel-scoped `clearAgentLifecycle` every other clear path uses. Wired via pbxproj ids `50BE0001…0101`/`…0102` under #3 |
| 324 | `cmuxTests/AgentHibernationTests.swift` | `panel-agent-liveness-evidence` | Regression coverage for #322/#323: a dead non-owner Claude's `running` lifecycle is retired while the live owner survives; the workspace-wide sweep reports that mutation; a still-live non-owner is preserved; and clearing all agent PIDs removes the workspace's registry bucket |
| 325 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+BrowserStream.swift` | `supermux-mobile-selection-sync` | Requires every browser-stream start entrypoint—including viewport auto-start, recovery restart, and foreground restart—to pass the same lower-layer authority gate: the panel must still own the phone-visible browser surface and, on v2 hosts, its exact Mac focus must be acknowledged. The gate is checked both before and after the suspending `browserStreamWillStart`, so selection changes during that await cannot queue a stale start ahead of the stop |
| 326 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SimulatorStream.swift` | `supermux-mobile-selection-sync` | Applies the same phone-visible plus Mac-focus-ready authority gate inside the serialized Simulator start operation. Stale activation tasks, view-dismissed tasks, and recovery restarts cannot start a stream for a panel that no longer owns the active phone surface |
| 327 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxStreamStartGateTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Browser and Simulator behavior coverage proves stream startup is denied before phone activation, denied while optimistic Mac focus is unacknowledged, allowed only when both authorities match, and denied again after panel-scoped deactivation |
| 328 | `Sources/Panels/BrowserPanel.swift` | `mac-browser-stream-teardown-grace` | Adds the cancellable teardown-grace task and its configurable interval beside the other mobile-stream state. Rapid phone-side panel switching amplified a WebKit layer-tree commit segfault on macOS 26/27 betas (`RemoteLayerTreePropertyApplier` type confusion, no app frames); every immediate teardown reparented the live WKWebView and closed its WebKit-hosting window mid-commit |
| 329 | `Sources/Panels/BrowserPanel+MobileBrowserStreaming.swift` | `mac-browser-stream-teardown-grace` | Three fences: the last stream handler removal parks the offscreen render host behind a short cancellable grace instead of tearing it down synchronously; a restart inside the grace cancels the pending teardown and reuses the parked host with zero window/reparent churn; explicit `clearMobileStreamViewport` tears down immediately, while a web-view replacement during grace restores the captured desktop viewport before abandoning the dead web view's render host |
| 330 | `cmuxTests/MobileBrowserStreamTeardownGraceTests.swift` | `mac-browser-stream-teardown-grace` | **Whole-file fork test.** Behavior coverage: a stopped stream parks the render host and a rapid restart reuses it with the teardown cancelled; grace expiry with no restart fully tears down; web-view replacement restores the desktop viewport; panel close during the grace skips the wait |
| 331 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePushCoordinator.swift` | `ios-direct-apns-token` | Mirrors each successful APNs device token into fork-owned `SupermuxMobilePushRegistrationStore` before upstream's cloud registration runs. The store persists a stable installation id plus the current and last Mac-acknowledged tokens, drains changes made during an in-flight registration, and registers/removes the device when `supermux.phone_push.v1` is advertised. The fixed bundle guard keeps upstream/tagged identities on their original cloud-only path. The settings bridge also preserves whether Time Sensitive Notifications are unsupported versus user-disabled so the personal-team build does not advertise an impossible repair |
| 332 | `Sources/TerminalNotificationStore.swift` | `direct-phone-push` | Adds the topic-restricted personal APNs provider at the two existing notification chokepoints. Visible sends deliberately IGNORE upstream's Mac focus suppression: a phone remote-controlling this Mac keeps the app frontmost on the phone's workspace while nobody is at the Mac, so any Mac-side presence guess loses notifications. The Mac always sends while phone forwarding is enabled; the phone owns presentation (its foreground delegate suppresses the banner when it is showing the exact target terminal, so an always-send Mac cannot double-notify). Dismiss/badge synchronization runs beside the existing cold lane under the same forwarding preference; hide-content is inherited. Transport stays in fork-owned `SupermuxDirectPhonePush`/`SupermuxPhonePushService` |
| 333 | `ios/Config/supermux.entitlements` | `unfenced` | **Fork-owned build-stage signing entitlement** (`aps-environment = development`, used only by the xcodebuild pass with the Apple Development profile — workspace-wide distribution settings leak into SwiftPM targets, which cannot take profiles). `scripts/supermux-ios-release.sh` then RE-SIGNS the built app with `Apple Distribution` + the `Supermux iPhone Ad Hoc` profile, using the entitlements extracted from that profile (`aps-environment = production`), and rejects a profile or final signature that is not production. The Ad Hoc profile must also carry `com.apple.developer.usernotifications.time-sensitive` (the App ID's Time Sensitive Notifications capability — a free checkbox on a paid team, unlike Critical Alerts), because the payload sends `"interruption-level": "time-sensitive"` and iOS silently downgrades it to active when the entitlement is absent; the script verifies it in the profile and the final signature. Sign in with Apple is deliberately NOT required: nothing in the iOS sources uses it, production auth runs through the web flow, so this lane must not inherit upstream's paid-team requirement for it. Sandbox APNs accepted every send with 200 but silently dropped delivery to the backgrounded app |
| 334 | `Sources/Mobile/MobileHostIrohRuntime.swift` | `profileless-release-iroh-storage` | Extends the existing DEBUG file-backed secure-store composition to `SUPERMUX_LOCAL_RELEASE`. The local Developer ID-signed Mac app has no provisioning profile/application-identifier entitlement, so the data-protection Keychain returns `errSecMissingEntitlement` and the entire mobile host remains offline; the release script's explicit condition uses the already hardened `0600` per-bundle file stores for identity and relay credentials without changing upstream production Release builds |
| 335 | `Sources/Mobile/MobileHostIrohRuntime+Lifecycle.swift` | `profileless-release-iroh-storage` | Compiles the matching bundle-scoped `developmentStoreDirectory(service:)` helper for `SUPERMUX_LOCAL_RELEASE`, keeping every local-release identity/credential family under `Application Support/cmux/iroh-debug/com.supermux.app/`. Must use the same compilation condition as #334 or the Release build fails at compile time |
| 336 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePushReadiness.swift` | `ios-direct-apns-token` | Models Time Sensitive Notifications support separately from the user's enabled setting. Unsupported personal-team builds do not show an unfixable Time Sensitive warning, while a supported setting that the user disables remains actionable and Scheduled Summary remains a real warning whenever active-level delivery cannot bypass it |
| 337 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/MobilePushReadinessTests.swift` | `ios-direct-apns-token` | Regression coverage proving an unsupported Time Sensitive setting can reach `.ready`, while Scheduled Summary remains the sole limitation when enabled on that build; the upstream parameterized test still proves a supported-but-disabled setting reaches `.presentationLimited([.timeSensitiveDisabled])` |
| 338 | `scripts/reload.sh` | `reload-supermux-profile`, `reload-supermux-profile-parse`, `reload-supermux-profile-seed` | Adds `--supermux-profile` (implies `--prod-auth`): after the same-tag app is told to quit, calls the supermux-owned `scripts/supermux-seed-dev-profile.sh` to copy the main `com.supermux.app` release install's UserDefaults + Stack Auth `credentials.json` into the tag's isolated identity, so a user-facing Mac dogfood build launches already signed in to the production account with the user's settings. The seeder is supermux-owned (no touchpoint); the three fences are the flag var, the arg parse, and the post-quit seeding call |
| 339 | `CLAUDE.md` | `mac-dogfood-supermux-profile` | Documents #338 next to upstream's "Build and reload" section: user-facing Mac dogfood builds must pass `--supermux-profile` (plain `--tag` sign-in points at an unserved localhost origin), sign-out inside a seeded build is forbidden (shared Stack session — revoking it signs the main app out too), agent-only builds keep plain `--tag` |
| 340 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Toolbar.swift` | `supermux-mobile-usage-button` | Two fences: `import SupermuxMobileUI`, and `SupermuxUsageToolbarButton(model: supermuxUsage)` as the FIRST entry of the iOS `.topBarTrailing` `ToolbarItemGroup`, before upstream's `viewOptionsButton()` / `newWorkspaceButton`. The phone twin of the Mac sidebar footer gauge (#146): a ring filled to the tightest Claude/Codex limit, opening the read-only `SupermuxUsageScreen` sheet. Purely additive — no upstream toolbar item is replaced or wrapped. Renders nothing without `supermux.usage.v1`, so a fork phone paired with an upstream cmux Mac shows exactly upstream's toolbar. **The button must stay stateless.** This whole `ToolbarItemGroup` sits inside `if showsNavigationToolbar`, which is false for the duration of every pushed workspace, so a session owned by the button's own `@State` is destroyed on push and rebuilt on pop — emptying the ring and restarting the poll after routine navigation. The session therefore lives in `@State supermuxUsage` on `WorkspaceListView` (#340b). Note this fence also sits INSIDE the #250 `supermux-mobile-list-toolbar-identity` region, which must keep gating only the toolbar's CONTENT — never branching around `content` |
| 340b | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-usage-button` | Two iOS-only fences: the internal (not private) `@State supermuxUsage = SupermuxUsageSectionModel()` beside the #97 projects model, guarded by `#if os(iOS)`, and a `.supermuxUsageDriver(model:connection:)` on the stable iOS `workspaceTable`. The driver owns the session `.task`, keyed on the connection identity, exactly like the #97 projects driver; cancellation (a navigation push) PAUSES the poll loop but keeps the store, so the gauge holds its last reading and a pop resumes instead of reloading. The macOS `List` branch deliberately has neither state nor driver because it renders no usage entry point; attaching one there creates a consumer-less poll loop. Must stay on the stable iOS view — never inside the toolbar branch or a table cell. See #340 |
| 341 | `Sources/Supermux/SupermuxMobileHost+Usage.swift` | `unfenced` | **Whole-file fork addition** (`Sources/Supermux/`, pbxproj ids `50BE0002…00E1`/`…00E2` under #95). Serves `mobile.supermux.usage.state` by projecting `SupermuxComposition.usageModel` — the SAME model the sidebar gauge and popover render — through the package-tested `SupermuxMobileUsagePayloadBuilder`. Awaits `usageModel.refresh()` first, because that poll loop is view-driven and a Mac with no sidebar mounted would otherwise report `loading` forever; the model's own hard floor applies to every caller, so a phone polling fast cannot add provider traffic. Read-only: no cswap switch/enable path is exposed to the phone |
| 352 | `Sources/TerminalNotification.swift` | `notification-project-identity` | Adds the optional `project: SupermuxNotificationProject?` snapshot (plus the `SupermuxMobileCore` import and the defaulted init parameter) so every notification carries the project it fired from. A frozen snapshot, never a live reference: history stays readable after a project is renamed, recolored, or unregistered. Defaulted `nil`, so no upstream construction site changes |
| 353 | `Sources/NotificationFeedHistoryRecord.swift` | `notification-project-identity` | Persists the project snapshot in the durable feed so a restored history still renders avatars. Carries an explicit `CodingKeys` + `init(from:)` with `decodeIfPresent` for `project` — records written before this field must keep decoding, or the entire durable history is lost on upgrade — plus a `historyProjectNameByteLimit` clamp applied in `boundedForHistory()` beside the existing title/subtitle/body bounds |
| 354 | `Sources/TerminalNotificationStore.swift` | `notification-project-identity`, `notification-project-banner` | Two fences. `notification-project-identity` resolves the project ONCE at the single `applyNotification` construction site every notification passes through, and preserves that snapshot in duplicate-id repair plus live panel-rebind copies, so restore/move paths cannot silently blank provenance. The panel, macOS banner, phone feed and APNs push therefore all describe the same project. `notification-project-banner` resolves the tab name and project on the enclosing `@MainActor` method, then decorates the content IN PLACE inside the authorization closure via `SupermuxBannerProjectDecorator` — adding the provenance subtitle, the per-project `threadIdentifier` (Notification Center stacks a project's banners instead of interleaving every workspace) and the circular avatar attachment. **Deliberately synchronous:** an earlier async version made banner ordering depend on raster-completion order and needed `MainActor.assumeIsolated` inside a closure upstream does not guarantee is main-actor isolated — which TRAPS if that ever changes. The call site now guards on `Thread.isMainThread` instead of asserting, and a render failure yields an undecorated banner rather than a lost notification |
| 355 | `Sources/NotificationsPage.swift` | `notifications-panel-redesign` | The redesigned macOS notifications panel: a two-tier header (title + live unread pill over filter/grouping/actions), an All/Unread filter, project grouping behind a persisted `@AppStorage` toggle, the phone-forwarding block demoted to a collapsed `Delivery` disclosure with a one-line state summary, and a rebuilt row (unread rail, project avatar, provenance line, body/subtitle preview, hover-only clear, context menu with mark-read). `SupermuxNotificationSectionHeader` is a new fork-owned view in the same file. Icons resolve ABOVE the `LazyVStack` through the same `SupermuxNotificationProjectBridge.projectIcons` helper the popover uses and pass down as immutable values. Filter/unread-count changes reconcile focus through `SupermuxNotificationFocusPolicy`, preserving a still-visible row or reseating to the newest visible row so Return never targets a filtered-out notification. `NotificationRow`'s `==` includes the icon/avatar/focus snapshots — the issue #2586 / #5794 boundary rule |
| 356 | `Sources/Update/UpdateTitlebarAccessory.swift` | `notification-read-toggle-shared` | The titlebar popover row's inline read-toggle (which also had to clear a pane-scoped notification's focused-read indicator) moved into the shared `TerminalNotificationStore.toggleReadFromUserAction(_:)` so the notifications panel's identical menu item cannot drift from it. The pane-indicator clearing is precisely the part a second copy would have missed |
| 357 | `Sources/MobileNotificationFeedWireItem.swift` | `notification-feed-project-wire` | Carries the project snapshot to the phone as an additive `supermux_project` object using `SupermuxNotificationProject`'s own snake_case Codable keys, so the phone decodes it with the shared type rather than a parallel hand-rolled parser. Absent from an upstream cmux Mac, which renders upstream's project-less row |
| 358 | `Sources/TerminalController+MobileNotificationSync.swift` | `notification-feed-project-wire` | Populates the wire item's project from the persisted history record and clamps its name with the existing metadata byte bound — the feed response is trimmed to a frame budget, so one pathological project name must not push notifications out of the frame |
| 359 | `Packages/iOS/CmuxMobileRPC/Package.swift` | `notification-feed-project-wire` | Adds the `SupermuxMobileCore` dependency so the RPC layer can decode the shared notification-project type |
| 360 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileNotificationFeedListItem.swift` | `notification-feed-project-wire` | Adds the optional `project` field, its `supermux_project` coding key, the defaulted init parameter, and the tolerant `decodeIfPresent` |
| 361 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileNotificationFeedListBoundedItem.swift` | `notification-feed-project-wire` | **THE production decode path** — a field added only to #360 decodes as `nil` in production while #360's own unit tests pass, because this type carries a DUPLICATE key set and is what actually runs. Adds the key plus `mobileNotificationFeedListBoundedProject`, which bounds the name/color/etag/symbol and drops the project (never the whole row) on a malformed or over-long identifier: losing a notification over a bad avatar is the worse failure |
| 362 | `Packages/iOS/CmuxMobileShellModel/Package.swift` | `notification-feed-project-wire` | Adds the `SupermuxMobileCore` dependency to the target and its test target |
| 363 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileNotificationFeedItem.swift` | `notification-feed-project-wire` | Adds the `project` field to the domain snapshot in all THREE required places: the stored property, the memberwise init, and `updating(isRead:connectionStatus:)` — that initializer re-lists every field, so omitting it there would silently blank the avatar on the first mark-read or reconnect |
| 364 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+NotificationFeed.swift` | `notification-feed-project-wire` | Threads the decoded project through `applyNotificationFeedSnapshot`'s wire→domain projection, normalizing the name with the same metadata bound as the other labels. A project whose name normalizes away keeps its id and accent so the avatar still renders |
| 365 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/NotificationFeedRowPresentation.swift` | `notification-feed-project-row` | Derives the project and its de-duplicated display name on the projection's BACKGROUND rebuild (never in `body` — the documented scroll constraint), folds the project name into the redundant-content set so a body that merely repeats it is not shown as a preview, and speaks the project before the workspace in the row's accessibility details |
| 366 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/NotificationFeedRow.swift` | `notification-feed-project-row` | Renders `SupermuxNotificationAvatar` in the row's leading slot and the project in the provenance line — as `project · workspace` in the normal case, and alone in the leading slot when the title already restates the workspace. Both provenance shapes use the same `ViewThatFits` horizontal→vertical fallback, so long project/computer labels remain visible at narrow widths and larger Dynamic Type sizes. Every added label stays a SINGLE interpolated `Text` and the avatar does no async work, honoring the file's documented rule that cell self-sizing dominates the scroll profile |
| 367 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires three new app-target files into the cmux target: `Sources/Supermux/SupermuxNotificationProjectBridge.swift` (ids `50BE0001…0105`/`…0106`), `Sources/Supermux/SupermuxBannerProjectDecorator.swift` (ids `…0107`/`…0108`), and `Sources/TerminalNotificationStore+ReadToggle.swift` (ids `…0109`/`…010A`). Twelve `50BE0001` occurrences total (4 per file: build file, file reference, group membership, sources phase) |
| 368 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Adds the THIRD iOS target: `SupermuxNotificationService` (`com.apple.product-type.app-extension`, ids `SMX1…0001`–`SMX1…0010`), its Sources/Frameworks/Resources phases and Debug/Release configuration list, the `Embed Foundation Extensions` copy phase (`dstSubfolderSpec = 13`) on the app target, and the app→extension `PBXTargetDependency`. The extension's `PRODUCT_BUNDLE_IDENTIFIER` and `PROVISIONING_PROFILE_SPECIFIER` read `$(SUPERMUX_NSE_*)`, and the app's read `$(SUPERMUX_APP_*)` — see #369 for why that indirection is load-bearing |
| 369 | `ios/Config/Shared.xcconfig` | `ios-communication-notifications` | Declares `SUPERMUX_APP_BUNDLE_ID` (which `PRODUCT_BUNDLE_IDENTIFIER` now derives from), `SUPERMUX_NSE_BUNDLE_ID` (derived from the app's, so it follows every channel/dogfood override and stays a CHILD of it — iOS refuses to load an extension whose id is not), and the empty `SUPERMUX_APP_DEV_PROFILE_SPECIFIER` / `SUPERMUX_NSE_DEV_PROFILE_SPECIFIER` / `SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS` defaults. **The indirection is the whole point:** an xcodebuild command-line build setting applies to EVERY target in the workspace, so the release script's bundle-id/profile/entitlements overrides would otherwise be stamped onto the extension too, giving it the app's id and an APNs entitlement its own App ID does not carry |
| 370 | `ios/Config/Release.xcconfig` | `ios-communication-notifications` | Sets `SUPERMUX_APP_BUNDLE_ID` instead of assigning `PRODUCT_BUNDLE_IDENTIFIER` directly, so the extension's derived id follows the Release channel's id (see #369) |
| 371 | `ios/Config/Info.plist` | `ios-communication-notifications` | Adds `NSUserActivityTypes = [INSendMessageIntent]`, required by the Communication Notifications capability. Its absence is the ITMS-90894 rejection and, at runtime, one of several SILENT failures where the push still arrives but renders as an ordinary banner with no avatar |
| 372 | `scripts/supermux-ios-release.sh` | `unfenced` | Fork-owned. Ships the nested extension: passes `SUPERMUX_APP_BUNDLE_ID` / the per-target profile+entitlement variables instead of the workspace-wide overrides (#369); generalizes `resolve_adhoc_profile` to take a profile name and resolves the extension's second Ad Hoc profile; signs strictly INSIDE-OUT (extension frameworks → extension → app frameworks → app — signing the .app first invalidates its own signature); embeds each bundle's own `embedded.mobileprovision` and signs each with ONLY its own profile's entitlements; and asserts the extension's bundle id/child-prefix/extension point/principal class, the app's `NSUserActivityTypes`, the Communication Notifications entitlement in both profile and final signature, the extension's team + application-identifier, and a `codesign --verify --deep` pass. Every one of those failures is otherwise silent |
| 373 | `Sources/Update/NotificationPopoverRow.swift` | `notification-popover-redesign` | The popover row now renders the SHARED row body (`Sources/Supermux/SupermuxNotificationRowBody.swift`) instead of its own layout. The popover and the notifications panel list the same notifications from the same store; with two independent bodies the redesign landed only in the panel while the popover — the surface behind the bell button and ⌘I, which is what most people open — kept the old look. Takes an `NSImage` resolved above the popover's `LazyVStack` (#374) and adds identity compares for it and the avatar flag to `==` — a store reference below that boundary is the #2586 spin-loop. Keeps the `…workspaceTitle` accessibility identifier that `MultiWindowNotificationsWorkspaceHeadlineUITests` queries |
| 374 | `Sources/Update/UpdateTitlebarAccessory.swift` | `notification-read-toggle-shared`, `notification-popover-redesign` | Two fences. The read-toggle one is #356. The redesign one brings the titlebar popover to parity with the notifications panel: a two-tier header (identity line + control row with the grouping toggle, Mark All Read, and Clear All), project sections via `SupermuxNotificationGrouping`, and every project icon resolved ONCE above the `LazyVStack` via the shared `SupermuxNotificationProjectBridge.projectIcons(for:)` helper, passing immutable `NSImage` values down — the same snapshot-boundary discipline as the existing per-render title index. Grouping reads the SAME `supermux.notifications.groupByProject` key the panel writes, so one behavior has one preference. The control row stays mounted with its actions disabled when empty, because `MultiWindowNotificationsUITests` asserts Clear All exists-and-is-disabled in the empty popover |
| 375 | `Sources/AppDelegate.swift` | `notification-project-banner` | One line in `applicationDidFinishLaunching` calling `SupermuxBannerProjectDecorator.sweepOrphanedAvatars()`. Avatar PNGs are handed to `UNNotificationAttachment`, which MOVES them into its own store; a banner that failed to schedule leaves its copy in the temp directory. Background, best-effort, older-than-an-hour |
| 376 | `ios/scripts/reload.sh` | `ios-communication-notifications` | Two sites (simulator leg and device leg) pass `SUPERMUX_APP_BUNDLE_ID` instead of `PRODUCT_BUNDLE_IDENTIFIER`. A command-line build setting applies workspace-wide, so the tagged override would otherwise stamp the app's id onto the notification service extension — and iOS silently refuses to load an extension whose bundle id is not a child of its container. See #369 |
| 377 | `ios/scripts/upload-testflight.sh` | `ios-communication-notifications` | Same redirection at both archive sites (beta and App Store lanes). **Known remaining gap:** this script's manual export map and its re-sign path still assume a PlugIns-free app, so the TestFlight/App Store lanes are not yet extension-ready — the fork's dogfood lane (`scripts/supermux-ios-release.sh`, #372) is. Fix before the next TestFlight upload |
| 378 | `ios/scripts/cloud-testflight.sh` | `ios-communication-notifications` | Same redirection for the cloud beta archive |
| 379 | `CLAUDE.md` | `no-handoff-notify` | Replaces upstream's "Notify through `cmux notify` so the user can leave and return" handoff/closeout instruction with the fork's rule: **don't**. The agent harness already notifies on response completion, so a handoff `cmux notify` is a second alert for the same event, and at handoff the user is about to read the summary regardless. The handoff content moves into the final response. The adjacent mid-dogfood sentence drops its `re-notify` clause for the same reason while keeping the substantive rule (rebuild the tag; the old verdict is stale). Explicitly still allowed: user asks for a ping, a skill/script that sends one as part of its job (the iPhone install queue), or testing the notification path |
| 380 | `Sources/Supermux/SupermuxNotificationRowBody.swift` | `unfenced` | **Fork-owned new file.** The single rendered body every macOS notification row uses — unread rail, project avatar, headline, provenance, preview, relative timestamp. Exists because the panel and the titlebar popover each had their own, so they disagreed on fonts, timestamp format, and whether an avatar appeared at all, and the surface the user happened to open decided what the feature looked like. Takes immutable values only, so it is safe below a lazy-list boundary |
| 381 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationRowPresentation.swift` | `unfenced` | **Fork-owned new file.** Decides WHAT goes on each line (headline = workspace else title; provenance = project + title minus anything the headline said; preview = body else subtitle). Pure string logic in the package so it is unit-tested directly rather than only through a rendered view |
| 382 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxSharedProjectIconStore.swift` | `unfenced` | **Fork-owned new file.** Project icon PNGs on disk in the app-group container, so the notification service extension can paint the REAL project logo on a push banner. Exists because the extension's first design rendered a generated chip from payload metadata alone, which is all a payload *can* carry: APNs caps a notification at 4096 bytes and a real icon is an order of magnitude past that (a 15 KB favicon is ~20 KB base64), so the bytes must arrive out of band. The app group is the only sanctioned shared surface — keychain-group sharing with the main install is forbidden (the Iroh stores half-share and mutually wipe relay credentials). Atomic writes, pruning that removes deleted/explicitly-iconless projects while preserving optional-`nil` legacy-host state, and a graceful no-op when the entitlement is absent |
| 383 | `ios/SupermuxNotificationService/NotificationService.swift` | `unfenced` | Fork-owned. Reads the mirrored PNG through a **re-declared** reader (`SharedProjectIconStore`), for the same reason `PushProject` and the accent palette are re-declared: an app extension links its own copy of every dependency, and the mobile package graph is too heavy for a process with an execution budget. The app-group id and `project-icons/<id>.png` path shape are therefore a hand-maintained contract with #382, pinned by `SupermuxSharedProjectIconStoreTests`. Circular-masks the logo (iOS paints a communication avatar as a circle; an unmasked square would have its corners clipped), honors the payload's authoritative `hasIcon` bit before touching mirrored bytes so a removed logo cannot reappear from a stale file, and falls back to the generated chip whenever the snapshot is icon-less or no icon is stored |
| 384 | `ios/Config/supermux-notification-service.entitlements` | `unfenced` | **Fork-owned new file.** The extension's OWN entitlements, carrying the app group and nothing else. Deliberately not the app's file: that claims `aps-environment` and Communication Notifications, which the extension's App ID does not carry, and signing would fail |
| 385 | `ios/Config/supermux.entitlements` | `unfenced` | Adds the app group beside the build-stage `aps-environment`. Note the App Store/TestFlight file (`cmux-release.entitlements`) is deliberately NOT touched — that channel is a different team and does not ship this extension |
| 386 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobilePaneUnreadPresentation.swift` | `unfenced` | **Fork-owned new file.** Projects the Mac-authoritative `supermux_unread_panel_ids` field onto the exact visible phone pane. `nil` means the host lacks pane-state support; `[]` means supported with no unread pane. Visibility alone never mutates state |
| 387 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadPaneRingStyle.swift` | `unfenced` | **Fork-owned new file.** Pins the mobile ring to the existing Mac pane ring's 2pt inset, 6pt corner radius, 2.5pt stroke, 0.35 glow opacity, and 3pt glow radius without changing the Mac renderer |
| 388 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadPaneRing.swift` | `unfenced` | **Fork-owned new file.** Draws the persistent, hit-test-transparent system-blue pane ring on iOS using #387's Mac-parity geometry and glow |
| 389 | `Packages/iOS/SupermuxMobileUI/Tests/SupermuxMobileUITests/SupermuxMobilePaneUnreadPresentationTests.swift` | `unfenced` | **Fork-owned package coverage.** Proves exact pane membership, unsupported (`nil`) versus supported-empty (`[]`) capability semantics, fail-closed missing pane identity, independence from the workspace boolean, legacy open-receipt gating, and parity with the Mac ring metrics |
| 390 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+Surfaces.swift` | `ios-pane-unread-acknowledgment` | Mounts #388 as a visual-only overlay over the exact active terminal/chat/browser-stream/Simulator pane when #386 sees that pane id. The phone-local browser has no Mac pane identity and never receives the ring; the overlay adds no gesture or hit-test path |
| 391 | `Sources/Supermux/Workspace+SupermuxMobileUnread.swift` | `unfenced` | **Fork-owned new app-target file.** Serializes pane ids in spatial order with the exact macOS predicate: visible notification/focused-read indicator, panel manual/restored indicator, or the representative pane for workspace-manual unread. Missing notification storage sends supported-empty rather than inventing state |
| 392 | `Sources/TerminalController.swift` | `ios-pane-unread-acknowledgment` | Routes accepted phone terminal mouse and text input through `TabManager.dismissNotificationOnTerminalInteraction(tabId:surfaceId:)`, the same `NotificationDismissalModel` path as Mac click/key input. The model's selected-target guard keeps acknowledgment pane-scoped and clears focused-read/restored/manual terminal indicators without changing local Mac behavior |
| 393 | `Sources/TerminalController+MobileBrowser.swift` | `ios-pane-unread-acknowledgment` | After a mobile browser click replays successfully, routes that exact panel through `dismissNotificationOnDirectInteraction`; move/scroll/key traffic is untouched, and the original browser action continues unchanged |
| 394 | `Sources/TerminalController+MobileSimulator.swift` | `ios-pane-unread-acknowledgment` | Routes an accepted Simulator `.tap` through `dismissNotificationOnDirectInteraction` for the resolved workspace/panel before forwarding the tap. Touch movement and non-pointer actions remain unchanged |
| 395 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-pane-unread-acknowledgment` | Disables the legacy workspace-wide open read receipt when `supermux_unread_panel_ids` is present, so opening/visibility never clears sibling panes. Older/upstream Macs omit the field and keep the pre-existing broad fallback |
| 396 | `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/SupermuxMobileWorkspaceFields.swift` | `unfenced` | Adds the shared `supermux_unread_panel_ids` wire-key constant used by the legacy sender. The key always travels on a supporting Supermux Mac, including an empty array, so absence remains an unambiguous old-host capability signal |
| 397 | `Sources/Workspace.swift` | `supermux-mobile-workspace-fields` | Exposes one type-erased publisher merging manual and restored pane-unread collections. `MobileWorkspaceListObserver` subscribes narrowly to this instead of hot `objectWillChange`, so exact pane-id changes propagate even while the workspace-level unread boolean stays true |
| 398 | `Sources/SessionNotificationSnapshot.swift` | `notification-project-identity` | Persists the optional frozen project snapshot in workspace session JSON and restores it into `TerminalNotification`. Optional/defaulted for backward compatibility with snapshots written before project-aware notifications |
| 399 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationFocusPolicy.swift` | `unfenced` | **Fork-owned new file.** Pure focus reconciliation for filtered notification lists: preserve a still-visible row, otherwise choose the newest visible id, otherwise clear focus. Keeps SwiftUI state writes out of `body` and package-tests the Return-key target decision |
| 400 | `Packages/SupermuxKit/Tests/SupermuxKitTests/SupermuxNotificationFocusPolicyTests.swift` | `unfenced` | **Fork-owned package coverage.** Verifies preserved visible focus, reseating after filtering, and empty-list clearing |
| 401 | `Sources/Supermux/SupermuxNotificationProjectBridge.swift` | `unfenced` | Adds the single app-target project-icon snapshot resolver used by both macOS notification lists. It deduplicates project ids, skips invalid UUIDs, reads the warm icon store once above each `LazyVStack`, and returns immutable `NSImage` values; an injectable lookup seam gives app-target coverage without an observable store below the list boundary |
| 402 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationGrouping.swift` | `unfenced` | Project grouping's pure shared implementation. Project sections keep newest-first order, while the project-less sentinel is explicitly appended last even when the newest notification is unregistered; both the panel and popover inherit the fix |
| 403 | `Sources/Supermux/SupermuxBannerProjectDecorator.swift` | `unfenced` | macOS banner provenance/thread/avatar decorator. The raster cache key includes the rendered `avatarLetter`, so renaming a letter-avatar project cannot keep serving its previous initial; icon/symbol identities remain memoized |
| 404 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxProjectsSectionModel.swift` | `unfenced` | Revalidates the live store, project presence, custom-icon flag, and icon etag after the async fetch before writing the app-group mirror. A stale response cannot resurrect a removed or replaced logo |
| 405 | `Packages/iOS/SupermuxMobileKit/Sources/SupermuxMobileKit/SupermuxMobileProjectsStore.swift` | `unfenced` | Prunes the shared push-avatar mirror against live projects unless `hasCustomIcon` is explicitly `false`: deleted and confirmed-iconless projects lose stale files, while optional `nil` from older hosts remains "unknown" and preserves bytes a banner cannot re-fetch |
| 406 | `scripts/supermux-ios-release.sh` | `unfenced` | Treats `group.com.supermux.ios` as the fixed entitlement/runtime-reader contract. A conflicting `SUPERMUX_IOS_APP_GROUP` now fails before `xcodebuild` instead of producing a signature that verifies while both readers silently open another container |
| 407 | `Sources/Panels/AgentSessionPanelView.swift` | `supermux-claude-harness-panel` | Branches the visible agent-session panel on the PROVIDER, not on a renderer kind: `providerID == .claude` renders the fork's native harness (`SupermuxClaudeHarnessMount`), while codex/opencode keep the upstream `AgentSessionWebRenderer` untouched. Chosen over a new `PanelType` case (~12 upstream switch sites) or a new `AgentSessionRendererKind` case (which is persisted with a SYNTHESIZED `Codable` and would throw mid-`SessionPanelSnapshot` decode on an upstream build) |
| 408 | `Sources/Panels/AgentSessionPanel.swift` | `supermux-claude-harness-lifecycle` | One line in `close()` terminating the panel's harness session. **Required, not optional:** `AgentSessionPanelView` renders `Color.clear` whenever `isVisibleInUI` is false while the `claude` process must keep running, so teardown cannot live in `onDisappear` — and a missed teardown is a leaked child process, not a leaked view |
| 409 | `Sources/ContentView.swift` | `supermux-claude-harness-palette` | Two one-line inserts registering the "New Claude Code Session" command: the contribution beside `.newSimulatorPane`, and `registry.registerSupermuxClaudeHarness(tabManager:)` beside `registerNewSimulatorPane`. Both bodies live in the fork-owned `Sources/Supermux/SupermuxClaudeHarnessLauncher.swift`, modeled on `SimulatorCommandPaletteIntegration.swift`, so only the two call lines are fenced |
| 410 | `Sources/cmuxApp.swift` | `supermux-claude-harness-menu` | One File-menu `Button` opening a native Claude harness surface, mirroring `menu.file.newSimulatorPane`. It calls the same `SupermuxClaudeHarnessLauncher.open(tabManager:)` the palette uses — one shared action path, per the fork's shared-behavior rule |
| 414 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the `SupermuxZeronUI` package (the zeron chat-pane design system) into the `cmux` target under the reserved `50BE0003…A1/A2/A3` ids — local package reference, product dependency, and Frameworks entry. `SupermuxKit` already depends on it transitively; the DIRECT link exists because `Sources/Supermux/SupermuxClaudeHarnessMount.swift` (#407) now constructs the `SupermuxZeronTheme` it hands to `SupermuxHarnessView`, and an app-target file cannot import a transitive package product. Registered separately from #3 (`SupermuxKit`) and #95 (`SupermuxMobileCore`) because it is a third package with its own id block |
| 413 | `Sources/AppDelegate.swift` | `supermux-claude-harness-terminate` | One call in `applicationWillTerminate` (beside `CloudVMActionLauncher.shared.terminateAll()`): `SupermuxClaudeHarness.terminateAllForAppShutdown()` gives every live harness child stdin EOF + SIGTERM **synchronously** (no actor hop — a spawned task might never run before exit). Without it a child mid-turn relies on eventually noticing stdin EOF and can outlive the app |
| 411 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-claude-button` | Two iOS-only fences mirroring #340b: the internal `@State supermuxClaude = SupermuxClaudeSectionModel()` beside the usage model (guarded by `#if os(iOS)`), and a `.supermuxClaudeDriver(model:connection:)` on the stable iOS `workspaceTable` right after the usage driver. The driver owns the harness session `.task` keyed on connection identity; cancellation (a navigation push) pauses the subscription but keeps the store, so the entry holds its badge and a pop resumes instead of reloading. Must stay on the stable iOS view — never inside the toolbar branch or a table cell |
| 412 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Toolbar.swift` | `supermux-mobile-claude-button` | One fence: `SupermuxClaudeToolbarButton(model: supermuxClaude)` in the iOS `.topBarTrailing` `ToolbarItemGroup` directly after the #340 usage gauge, before upstream's `viewOptionsButton()`. Purely additive; renders nothing without `supermux.claude.v1`, so a fork phone paired with an upstream cmux Mac shows exactly upstream's toolbar. **The button must stay stateless** — the session lives in #411's list-owned `@State` because this whole toolbar branch sits inside `if showsNavigationToolbar` and is torn down on every push. The file's existing #340 `import SupermuxMobileUI` fence covers the import |
| 145 | `cmuxTests/PostHogAnalyticsPropertiesTests.swift` | `unfenced` | **KNOWN FORK DEBT — this file is NOT yet modified; the row is a placeholder so the debt is not lost.** Three upstream tests contradict touchpoint #130 and are red on the fork: `appKitSidebarFeatureFlagDefaultsOn` asserts `defaultWhenUnavailable` for `sidebar-appkit-list-experiment` against the fork's `false`; `featureFlagResolutionPrecedence` sets a remote `true` for that key and asserts it reaches `remoteValue(for:)`; `remoteControlledFlagsRejectNewLocalOverrideWrites` sets a remote `true` for that key and asserts it blocks `setOverride`. Verified byte-identical to pre-merge `HEAD`, so this is standing debt, **not** 0.64.21 merge damage. Needs either a retarget of the three tests onto a neutral flag key or fences around the three expectations — OPEN DECISION, see SUPERMUX.md "Known limitations" |
## How to re-apply

### 411–412. iOS Claude harness toolbar entry — `supermux-mobile-claude-button`

The exact twin of the #340/#340b usage-button pattern; re-apply them together.

**#411 `WorkspaceListView.swift`** — two `#if os(iOS)` fences: the
`@State supermuxClaude = SupermuxClaudeSectionModel()` property beside `supermuxUsage`, and
`.supermuxClaudeDriver(model: supermuxClaude, connection: store?.supermuxConnectionSeam)` chained
directly after `.supermuxUsageDriver(...)` on the stable `workspaceTable` (inside the #97
`baseList` chain, before `WorkspaceListBarUnderlap`).

**#412 `WorkspaceListView+Toolbar.swift`** — one fence:
`SupermuxClaudeToolbarButton(model: supermuxClaude)` immediately after
`SupermuxUsageToolbarButton(model: supermuxUsage)` in the iOS `.topBarTrailing` group. The import
is already covered by #340's `import SupermuxMobileUI` fence.

Everything else (model, driver, button, sheet, screens) is fork-owned in
`Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/Claude/` and needs no fences.

### 407–410. Native Claude Code harness — `supermux-claude-harness-*`

Four fences, all one- to four-liners. Everything they call lives in fork-owned files
(`Sources/Supermux/SupermuxClaudeHarness{Mount,Registry,Launcher}.swift`, plus
`Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/`), so re-applying is mechanical.

**#407 `Sources/Panels/AgentSessionPanelView.swift` — `supermux-claude-harness-panel`.** Inside
`body`'s `if isVisibleInUI` arm, wrap upstream's `AgentSessionWebRenderer(...)` in
`if SupermuxClaudeHarness.handles(panel) { SupermuxClaudeHarnessMount(panel:isFocused:appearance:onRequestPanelFocus:) … } else { <upstream> }`.
Note the fence appears twice (open and close of the `else`) because the upstream expression sits
between them; keep both halves or the checker flags the file.

The fence itself is unchanged by the zeron port (#414), but what the mount does with `appearance`
is: it used to project all five `PanelAppearance` fields onto a `SupermuxHarnessThemeInput` and
derive the pane's whole palette from the Ghostty theme, so a native Claude panel matched a webview
Codex panel. That premise is gone — zeron is a fixed 44-token design system in exactly two
appearances — and the mount now reads only `appearance.backgroundColor.isLightColor` and passes a
`SupermuxZeronTheme(isDark:)`. **Deliberate consequence:** a Codex webview panel beside a Claude
panel now looks different; only the light/dark axis still follows the terminal theme.

**#408 `Sources/Panels/AgentSessionPanel.swift` — `supermux-claude-harness-lifecycle`.** First line
of `close()`: `SupermuxClaudeHarness.closeSession(panelID: id)`.

**#409 `Sources/ContentView.swift` — `supermux-claude-harness-palette`.** Two inserts:
`contributions.append(.supermuxNewClaudeHarness)` after the `.newSimulatorPane` block, and
`registry.registerSupermuxClaudeHarness(tabManager: tabManager)` after
`registry.registerNewSimulatorPane(...)`.

**#410 `Sources/cmuxApp.swift` — `supermux-claude-harness-menu`.** A `Button` in the File menu after
the Simulator item, calling `SupermuxClaudeHarnessLauncher.open(tabManager: activeTabManager)` and
beeping on `false`.

**#413 `Sources/AppDelegate.swift` — `supermux-claude-harness-terminate`.** One line in
`applicationWillTerminate`, beside the other `terminateAll()` calls:
`SupermuxClaudeHarness.terminateAllForAppShutdown()`. A `surface_closed` event-bus safety net was
considered and rejected — that event also fires on surface *detach* (origin `detach`), where the
session must keep running.

**Why the provider branch and not a new panel type.** `AgentSessionRendererKind` is an HTML-path
enum (`resourceHTMLPathComponents`) whose every consumer is WebKit-typed, and it is persisted with
a synthesized `Codable`: writing a `"native"` case would throw mid-`SessionPanelSnapshot` decode on
an upstream build or after a fork revert. A new `PanelType` case would need ~12 exhaustive-switch
edits across upstream files that carry no fences today. Branching on
`panel.currentProviderID == .claude` needs neither, and loses nothing — the webview's Claude path
never rendered tools, thinking, or cost anyway.

**Persistence is deliberately fork-side.** Harness records key off `panel.stableSurfaceId` in
`SupermuxHarnessSessionStore` (JSON under the cmux state directory), NOT
`SessionAgentSessionPanelSnapshot`, so new persisted fields never touch an upstream `Codable`. The
mount reads `stableSurfaceId` lazily from `.task`, never at construction: upstream adopts the
restored id inside `applySessionPanelMetadata`, which runs *after* `newAgentSessionSurface` returns.

### 379. `CLAUDE.md` — `no-handoff-notify`

Upstream's "First pass, then dogfood" section ends with a paragraph instructing the agent to send
`cmux notify` at handoff and closeout. Replace that paragraph with the fenced fork rule: do not
notify at handoff or closeout, because this harness already notifies the user when a response
finishes — the `cmux notify` is a duplicate alert for the same event, and the user is about to read
the summary anyway. The handoff fields upstream put in the notification body (was / now / the
concrete check / the PR URL) belong in the final response.

Also drop `and re-notify` from the preceding mid-dogfood sentence, keeping the rule itself intact:
a runtime-behavior fix mid-dogfood still requires rebuilding the tag, because the user's earlier
verdict only covers the build they actually tested.

Keep the carve-outs in the fence. This is a rule about unprompted handoff pings, not a ban on the
CLI: an explicit user request, a skill or script that notifies as part of its own job
(`scripts/iphone-install-queue.sh` does), and `cmux-diagnostics`' notification-path test are all
still correct.

Note `AGENTS.md` is a symlink to `CLAUDE.md`, so it inherits this automatically — do not add a
second copy there.

### 368–372, 375, 382–385. iOS push project avatar (notification service extension) — `ios-communication-notifications`

Gives the iOS push banner the Discord-style presentation: a large circular project avatar on the
left with the app icon badged onto its corner. The extension itself is fork-owned and unfenced
(`ios/SupermuxNotificationService/`); these five touchpoints are the wiring around it.

**Why an extension exists at all.** `UNNotificationContent.updating(from: INSendMessageIntent)` is
the only API that applies that treatment, and for a REMOTE push it must run inside
`UNNotificationServiceExtension.didReceive` — the app process is not running when a banner arrives
on a locked phone. There is no APNs payload key for it. Verified against the iOS 26.2 SDK headers.

**Why the avatar is mirrored, not downloaded.** Project icons live on the paired Mac and reach the
phone only over the app's encrypted RPC session, which a short-lived out-of-process extension cannot
open. They cannot ride the push either: APNs caps a notification at 4096 bytes while a real icon is
usually an order of magnitude larger. The phone app therefore mirrors every fetched PNG into the
`group.com.supermux.ios` app-group container (#382/#385), and the extension reads that one local file
through its deliberately re-declared reader (#383/#384) — no network and no RPC. The payload still
carries the frozen project identity plus `hasIcon`; an icon-less snapshot MUST skip any stale mirrored
file and render the generated chip instead. Missing bytes, a build without the app group, or corrupt
PNG data also fall back to the chip. The extension's palette and splitmix64 slot hash are a deliberate
copy of `SupermuxProjectAccentPalette` — if either changes, both must, or that fallback differs between
the lock screen and the sidebar.

The fixed-identity release lane (`scripts/supermux-ios-release.sh`) verifies the app group in both
profiles and both final signatures. The wildcard-profile dogfood extension cannot carry App Groups,
so that lane deliberately strips the extension entitlement and shows the generated chip. Keep the
launch sweep in #375: `UNNotificationAttachment` moves successful files into its own store, while a
failed schedule can leave a disposable copy behind.

**The failure mode to design against is silence.** A missing capability, a stale profile, a missing
`NSUserActivityTypes`, or a wrongly-signed `.appex` all produce a build that installs cleanly and a
push that arrives looking completely ordinary. That is why #372 asserts every one of them, and why
the assertions matter more than the code.

One-time Apple portal setup (all of it invalidates existing profiles — regenerate AND reinstall):

1. Register `group.com.supermux.ios`, then enable **Communication Notifications** and that App Group
   on the `com.supermux.ios` App ID.
2. Create the `com.supermux.ios.notification-service` App ID and enable the same App Group (nothing else).
3. Regenerate and reinstall all four profiles: the app's Development + Ad Hoc, and the extension's
   Development + Ad Hoc (default names in the script's `NSE_*_PROFILE` variables).

**Every build entrypoint must use the indirection, not just the release script** (#376–#378). An
adversarial review found `reload.sh`, `upload-testflight.sh`, and `cloud-testflight.sh` still passing
`PRODUCT_BUNDLE_IDENTIFIER` workspace-wide, which gave the extension the app's id. Same class of bug
for entitlements: the app target reads `$(SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS)` (defaulted in the
xcconfigs to the same per-channel file upstream used, so an ordinary build is unchanged) while the
extension pins `CODE_SIGN_ENTITLEMENTS = ""` on its own target — inheriting the app's would claim an
APNs entitlement the extension's App ID does not carry, and signing fails. Verify after any change
with `xcodebuild -project ios/cmux-ios.xcodeproj -target <t> -configuration <c> -showBuildSettings`
for BOTH targets, with and without overrides.

Requirements if upstream restructures any of this:

- The extension's bundle id must stay DERIVED from the app's (#369). Hardcoding it strands the
  extension under the default id on every release and dogfood build, and iOS silently declines to
  load an extension whose id is not a child of its container.
- Never pass `PRODUCT_BUNDLE_IDENTIFIER`, `PROVISIONING_PROFILE_SPECIFIER`, or
  `CODE_SIGN_ENTITLEMENTS` on the xcodebuild command line once the extension exists — they apply
  workspace-wide. Use the `SUPERMUX_APP_*` / `SUPERMUX_NSE_*` variables.
- Signing stays inside-out, and each bundle is signed with only its OWN profile's entitlements.
- `mutable-content: 1` is set only alongside a project (`SupermuxPhonePushService`): without one the
  extension has nothing to render and would spend a launch to no effect.
- The extension must preserve `userInfo["cmux"]` — it compares the dictionary before and after
  `updating(from:)` and falls back to the undecorated content if it ever differs, because a prettier
  banner that cannot route a tap is strictly worse than a plain one.

Verification: `./scripts/supermux-ios-release.sh` (its own assertions are the gate), plus a real
push to a locked iPhone — the avatar cannot be verified in the Simulator.

### 352–367, 373–374, 397–406. Project-aware notifications — `notification-project-identity` + `notification-project-banner` + `notifications-panel-redesign` + `notification-feed-project-wire` + `notification-feed-project-row` + `notification-read-toggle-shared`

Every notification carries the Supermux project it fired from, on all three surfaces (macOS panel,
macOS system banner, iOS feed) and in the APNs push. The fork-owned core is
`Packages/Shared/SupermuxMobileCore` (`SupermuxNotificationProject`, `SupermuxProjectAccentPalette`)
and `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/` (resolver, provenance, banner
decoration, grouping, avatar renderer, avatar view) — none of which need fences.

**The load-bearing invariant: resolve ONCE.** `TerminalNotification.project` is set at the single
`applyNotification` construction site (#354). Every surface then reads that frozen snapshot. Do not
re-derive project identity per surface: four copies drift, and a snapshot is also what keeps a
renamed or deleted project from rewriting history.

**Do not resolve through `SupermuxProjectResolutionCache`.** That cache is keyed by `TabManager` and
validated inside SwiftUI bodies; notification delivery has no window. Resolution goes through
`SupermuxNotificationProjectBridge` → `SupermuxNotificationProjectResolver`, which is a pure
main-actor function over `SupermuxComposition.projectsModel` + `.workspaceAssociations` with no I/O
and no `await`. Icons come from the already-warm `SupermuxComposition.projectIconStore`; never probe
the filesystem on the delivery path (`SupermuxProjectIconResolver` stats up to 30 candidate paths).

If upstream restructures these files, the requirements are:

- **#352/#353/#398 (model + durable/session records):** `project` must stay OPTIONAL and decode
  tolerantly. A non-optional field silently discards pre-existing history/session JSON. Every
  `TerminalNotification` reconstruction path (session restore, duplicate-id repair, live panel
  rebind) must forward the snapshot rather than taking the initializer's default `nil`.
- **#354 (store):** banner decoration must stay SYNCHRONOUS and in place. Deferring the schedule
  behind an async raster reorders banners, and reaching for `MainActor.assumeIsolated` inside the
  authorization closure traps the process if that closure ever runs off the main actor. Resolve
  main-actor values before the closure; guard, never assert, inside it.
- **#355/#374/#401 (Mac lists):** both surfaces call ONE project-icon snapshot helper above their
  `LazyVStack` and pass immutable `NSImage` values down. `NotificationRow.==` compares the icon by
  identity plus the avatar flag. A view below that boundary must never hold `SupermuxComposition` or
  the icon store (issue #2586 / #5794). The panel's All/Unread filter is panel-only; #399 preserves a
  still-visible focus or reseats to the newest visible row so Return never targets a filtered-out id.
- **#402 (grouping):** project sections preserve newest-first relative order, but the project-less
  sentinel is always appended last. Do not put it back into generic first-seen ordering.
- **#403 (macOS banner cache):** the cache key must include every rendered identity field, including
  `avatarLetter`; otherwise a letter-avatar rename keeps serving the previous initial.
- **#357–#364 (wire):** a new field needs BOTH iOS decoders. `MobileNotificationFeedListBoundedItem`
  (#361) is the production path with its own duplicate `CodingKeys`; adding a field only to
  `MobileNotificationFeedListItem` decodes as `nil` in production while its unit tests pass. And
  `MobileNotificationFeedItem.updating(...)` (#363) re-lists every field — omitting one blanks it on
  the first mark-read.
- **#365/#366 (iOS row):** all string derivation stays in `NotificationFeedRowPresentation.init`
  (the projection's background rebuild), and every added label stays a single interpolated `Text`.
  `HStack{Image, Text}` pairs here are a measured scroll regression, not a style preference. Both
  provenance shapes need the horizontal→vertical `ViewThatFits` fallback for narrow/Dynamic Type rows.
- **#404/#405 (phone icon mirror):** after every async fetch, revalidate the current store, project,
  custom-icon flag, and etag before writing. Pruning removes deleted ids and explicit `false`, but
  preserves optional `nil` because older hosts use it as "unknown" and a banner cannot re-fetch. This
  pair prevents an old response from resurrecting a removed icon without evicting legacy-host bytes.
- **#406 (release app group):** `group.com.supermux.ios` is one fixed contract shared by entitlements
  and both runtime readers. Reject a conflicting environment override before building; do not let
  verification and runtime silently point at different containers.
- **#373/#374 (popover):** the popover resolves icons above its list and hands down values only;
  its row `==` must keep comparing the icon by identity, or a decoded icon never repaints.
- **#356 (read toggle):** both surfaces call `TerminalNotificationStore.toggleReadFromUserAction(_:)`.
  Marking a pane-scoped notification read must also clear that pane's focused-read indicator;
  workspace-level notifications (`surfaceId == nil`) must NOT, since the clear treats nil as
  "any pane on this tab" and would wipe an unrelated badge.

APNs (fork-owned, unfenced): `SupermuxPhonePushMessage` carries the project + tab name, clamped to
`projectNameByteLimit`/`tabNameByteLimit`; `SupermuxPhonePushService` emits `cmux.project`,
`cmux.tabName`, and `aps.thread-id` keyed on the project **id** (never the name — a rename must not
split the group). Two rules there: hide-content suppresses all of it (a project name is exactly the
thing that setting exists to hide), and the whole decoration is dropped BEFORE the body/subtitle/title
truncation ladder runs, so fixed-size chrome can never starve the terminal output the user actually
wants to read.

Verification: `swift test` in `Packages/SupermuxKit` (`SupermuxNotificationProjectTests`,
`SupermuxPhonePushProjectPayloadTests`), a macOS build, an iOS Simulator build, and
`./scripts/supermux-check-touchpoints.sh`.

### 386–396. iOS pane unread acknowledgment — `ios-pane-unread-acknowledgment`

Keep the Mac semantics unchanged: a notification delivered for the pane already under focus remains unread, keeps the persistent blue pane ring, and clears only after a direct interaction. The phone must not auto-clear merely because the pane is visible. `Workspace.supermuxMobileUnreadPanelIDs(notificationStore:)` is the Mac-authoritative projection and must continue to call the same `Workspace.shouldShowUnreadIndicator(...)` predicate as `WorkspaceContentView`: visible notification/focused-read state, manual/restored panel state, and the representative pane for workspace-manual unread. Both mobile transports send `supermux_unread_panel_ids` for every workspace; `[]` means a supporting host with no indicated pane, while absence means an older/upstream host.

The mobile ring copies the Mac renderer's current geometry and presentation values exactly: 2pt inset, 6pt corner radius, 2.5pt system-blue stroke, 0.35 glow opacity, and 3pt glow radius. It is a visual-only overlay with hit testing disabled. `SupermuxMobilePaneUnreadPresentation` only tests whether the active remote panel id is in the transported array; it never reads the notification feed and never mutates unread state.

Acknowledgment stays Mac-side and reuses the existing input RPCs. `mobile.terminal.mouse` and `mobile.terminal.input` call `dismissNotificationOnTerminalInteraction`; browser `.click` and Simulator `.tap` call `dismissNotificationOnDirectInteraction`. These are the same `NotificationDismissalModel` entrypoints used by local Mac input, so the selected-target guard, exact surface scope, focused-read cleanup, restored/manual semantics, and sibling-pane preservation remain centralized. Do not replace them with workspace-wide `mark_read`, and do not add a competing SwiftUI gesture over terminal/browser/Simulator input.

When the pane-id field is present, `openWorkspace` must skip its legacy workspace-wide read receipt: navigation or continued visibility is not acknowledgment. Preserve that broad receipt only when the host omits the field, so upstream/older Macs keep their prior iOS behavior. Keep pane ids folded into `MobileWorkspaceListObserver`'s notification signature so a pane-only indicator change cannot be suppressed as a no-op. #397 must continue merging the workspace's manual and restored pane publishers, and #283 must subscribe to it; otherwise A → A+B changes never reach the hash while the workspace boolean stays true. Preserve the field through both legacy list decoding and state-sync-v2 projection.

### 331–333. Native personal APNs delivery — `ios-direct-apns-token` + `direct-phone-push`

This path exists because the fixed privately signed `com.supermux.ios` app cannot use cmux's
single-topic cloud provider credential. Keep the APNs private key on the paired Mac only; never
commit it, paste it into documentation, or copy it to the phone. The Apple key should be restricted
to the `com.supermux.ios` topic and Sandbox environment.

In `MobilePushCoordinator.handleDeviceToken`, preserve the fenced call to
`SupermuxMobilePushRegistrationStore(defaults: defaults).record(deviceToken:)` before upstream's
cloud registration call. The fork store sends the token only for the fixed bundle and only when the
Mac advertises `supermux.phone_push.v1`; upstream and tagged app identities remain unchanged.

The fixed personal-team profile does not expose the Time Sensitive notification setting. Preserve
`timeSensitiveSupported` from `MobilePushCoordinator.systemSettings(from:)` through
`MobilePushSystemSettings`: `.notSupported` must not create `.timeSensitiveDisabled`, while a
supported `.disabled` setting must remain actionable. Keep Scheduled Summary independent of support:
when `scheduledDeliveryEnabled` is true and `timeSensitiveEnabled` is false, active-level direct
pushes can still be delayed and the readiness screen must report that real limitation. Keep #337's
behavior test together with this mapping.

In `TerminalNotificationStore`, preserve both `direct-phone-push` fences. Visible forwarding runs
OUTSIDE the `shouldAttemptPhone` branch on purpose — the direct lane must ignore Mac focus
suppression (a phone remote-controlling the Mac keeps it frontmost on the phone's workspace, so a
focus-gated lane never fires while working from the phone) and is gated only on the forwarding
preference. The phone owns presentation: its foreground delegate suppresses the banner when it is
already showing the exact target terminal. Dismiss forwarding stays beside
`PhonePushClient.forwardDismissed` under the same preference. Do not reintroduce a Mac-side
presence/away heuristic — one was tried (`SupermuxMacAwayPolicy`) and removed because any Mac-side
guess loses notifications for the remote-control workflow.

Signing is two-stage. xcodebuild signs with the `Supermux iPhone Development` profile and the
development entitlement in `ios/Config/supermux.entitlements` (workspace-wide distribution build
settings leak into SwiftPM package targets, which cannot take provisioning profiles); the script
then re-signs the built app with the `Apple Distribution` identity, the `Supermux iPhone Ad Hoc`
profile, and the entitlements extracted from that profile, and verifies
`aps-environment = production` in both the embedded profile and the final signature. Both profiles
also carry `com.apple.developer.usernotifications.time-sensitive` from the App ID's Time Sensitive
Notifications capability, and the script verifies it in the profile and the final signature too:
the payload sends `"interruption-level": "time-sensitive"`, and iOS SILENTLY downgrades that to
active when the entitlement is absent, so the push still arrives and only the Focus/Scheduled
Summary bypass is lost. Because the re-sign derives entitlements FROM the profile, enabling any App
ID capability invalidates both profiles: regenerate AND reinstall them or the next build quietly
drops the entitlement. Production is
mandatory: sandbox APNs returns 200 for every request but is best-effort and silently dropped
delivery to the backgrounded app (confirmed with a badge-only probe that never applied). The Mac
provider key is the production-environment related key; registrations carry
`environment: production` and the phone registration store reports `.production`.
The paired Mac provider reads these local files from the cmux state directory —
`~/.local/state/cmux`, the same `CmuxStateDirectory` the AI key uses (NOT
`~/Library/Application Support/cmux`; putting the files there is a silent no-op):

- `supermux-apns.json` — `{ "team_id": "…", "key_id": "…" }`
- `supermux-apns-auth-key.p8` — Apple's downloaded ES256 authentication key
- `supermux-apns-devices.json` — phone registrations written by the service

Keep the directory mode `0700` and every file mode `0600`. Provider code in
`Packages/SupermuxKit/Sources/SupermuxKit/Push/` must reject every bundle outside
`com.supermux.ios`, use the sandbox APNs host for this build, cache JWTs for less than 50 minutes,
and prune permanently invalid tokens. The RPC method remains Mac-wide authorized and capability
gated. Re-verify with the focused Supermux package tests, `tests/test_supermux_ios_release.sh`, a
macOS `cmux-unit` build-for-testing, and a real background/locked iPhone notification.

### 334–335. Profileless local Release mobile host — `profileless-release-iroh-storage`

The installed `/Applications/Supermux.app` is Developer ID-signed without an embedded provisioning
profile. That signature can use the normal login Keychain but has no application-identifier entitlement,
so Iroh's data-protection-Keychain stores fail with `errSecMissingEntitlement`; when identity creation
fails, the Mac never publishes a mobile route and the phone cannot mirror its APNs token.

Keep the existing development file-store composition unchanged and extend only its compile guards in
`MobileHostIrohRuntime.swift` and `MobileHostIrohRuntime+Lifecycle.swift` from `DEBUG` to
`DEBUG || SUPERMUX_LOCAL_RELEASE`. The fork-owned `scripts/supermux-release.sh` must pass
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SUPERMUX_LOCAL_RELEASE`. Do not define `DEBUG` for
Release and do not alter upstream production Release behavior. The reused stores already scope by bundle
identifier, write mode `0600`, and cover endpoint identity, broker credentials, host policy, revocations,
relay policy/preferences, and custom relay credentials as one coherent persistence mode.

Re-verify with `tests/test_supermux_release_stale_artifact.sh`, a real local Release build, and macOS logs:
there must be no `CmxIrohKeychainIdentityStoreError`, the phone must reconnect, and
`supermux-apns-devices.json` must appear after the APNs-enabled phone app launches.

### 261–284, 291, 297–298. Cross-platform workspace unread badge

Keep one badge design, not platform-matched copies. `SupermuxUnreadBadgeStyle` owns count formatting, proportions, rim, gradient, and shadow values; `SupermuxUnreadBadgeContent` is the single SwiftUI body used by the Mac and phone wrappers. The pure-AppKit sidebar may keep its native Core Graphics renderer for pooled-row performance, but it must measure and paint from those shared values. Keep the package `Resources` declaration and `supermux.unreadBadge.overflow` catalog entry together so the visible `99+` marker remains localized on both apps.

On macOS, preserve custom unread colors, the leading/trailing badge-position setting, global font magnification, and hover-independent wrapped-row geometry. A wide count capsule must be measured rather than clipped into the old square slot. The AppKit layer shadow needs a capsule `shadowPath`; otherwise every visible row pays for an inferred offscreen shadow.

Carry `supermux_unread_count` through BOTH mobile transports: legacy `mobile.workspace.list` and state-sync v2. Absence means an upstream cmux Mac whose count is unknown, so the phone renders the shared countless-dot form; zero is a known Supermux count. Hash the count in `MobileWorkspaceListObserver.previewSignatures`, then still assign `signatures[workspace.id] = hasher.finalize()` after the fenced combine. The narrow count override exists only so the behavior test can reproduce a 2 → 1 count-only transition while holding the latest notification and unread boolean fixed.

On iOS, render no unread view at all for a read workspace. The color rail begins at x=0, the badge trails the workspace/group title, and the wrapped-row height cache includes the exact rendered badge text (`nil`, `""`, numeral, or `99+`). Project-nested rows and project detail rows use the same phone wrapper. Keep its headline-relative `@ScaledMetric` so Dynamic Type scales the badge with the row.

Re-apply the wire, observer, cache, and renderer changes as one unit. Verify with `swift test --package-path Packages/Shared/SupermuxMobileCore`, `swift test --package-path Packages/Shared/CMUXMobileCore`, `swift test --package-path Packages/iOS/SupermuxMobileUI`, and the `MobileWorkspaceListFidelityTests` suite under the `cmux-unit` scheme.

### 245–249. iOS terminal default zoom — `ios-terminal-default-zoom`

Keep `MobileTerminalFontPreference.defaultSize` at 12 pt and make every defaulted `GhosttySurfaceView` initializer reference that constant rather than duplicating a number. `MobileTerminalZoomPreference.resolvedFontSize` must return the explicitly saved size when present and the built-in 12 pt size otherwise. The production terminal mount in `WorkspaceDetailView+TerminalArtifacts.swift` must pass that resolved value into `GhosttySurfaceRepresentable`; passing the built-in constant directly recreates the bug where tapping the floating "Set as default" button persists a value that no newly selected terminal ever reads. The floating Reset action continues to apply the resolved value, while Restore built-in clears the explicit preference and applies 12 pt. Keep `MobileTerminalZoomControlTests` in the package test target to cover persistence/clearing and dispatch from all three floating buttons.

### 252–258. Agent chat Focus Mode — `agent-chat-focus-mode` + `ios-agent-chat-focus-mode`

A coding-agent session is mostly tool calls. Rendered one row each, they bury the handful of
sentences the agent actually said — which is what the user opened the phone to read. Focus Mode
folds each consecutive run of work rows behind a single tappable "Working · N steps" summary.

**What folds:** `toolUse`, `thought`, `terminal`, `fileEdit`.
**What never folds:** prose, user prompts, `question`, `permissionRequest`, `status`, `attachment`,
date headers, the unread separator, and pending outbound prompts. Questions and permission requests
BLOCK the agent — hiding them behind a disclosure would strand the session. `SupermuxChatFocusGroupingTests`
pins both lists, plus the invariant that grouping never drops or reorders a row.

Runs shorter than `minimumGroupSize` (2) stay expanded: folding a single call costs a tap and saves
nothing.

**Where the code lives.** All of it is fork-owned under
`Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/AgentChat/`
(`SupermuxChatFocusGrouping` — the pure fold; `SupermuxChatFocusMode` — the modifier that owns
expanded state; `SupermuxChatWorkGroupRow` — the summary; `SupermuxChatShimmerText`). Upstream keeps
owning the table, keyboard tracking, paging, and every individual row view — expanded runs call
straight back into `ChatTranscriptRowView`.

**Three things are load-bearing and easy to lose on a re-apply:**

1. **Entries are computed once per update, in `updateUIView`** (#245), and shared by `makeItems()`
   and the cell factory. Computing them inside the factory instead re-runs the fold for every
   visible cell on every streamed delta, and lets the two disagree about what entry N is.
2. **`groupingReloadIdentity` must stay in `shouldReload`** (#245). It combines the grouping's
   configuration identity with the ordered entry ids, so both "the setting flipped" and "a group
   expanded, so its rows moved" force a reload. Without it the table keeps stale cells.
3. **Expanded state lives in `SupermuxChatFocusModifier`, above the transcript** — deliberately not
   in `SupermuxChatWorkGroupRow`. The transcript is a `UITableView` that decides to reload by
   comparing item identity; a tap that only flipped a child view's private `@State` would resize a
   cell the table does not know changed (self-sizing drift). Keeping it above means a tap changes
   the grouping identity, which forces a clean reload.

**To re-apply after an upstream merge:**

- If upstream reshapes `ChatTranscriptTableView`, re-add the seven fences from #245. The
  `.groupedEntry` case follows whatever item taxonomy upstream now has.
- If upstream reshapes the Display settings section, re-add the #247 toggle.
- Verify it is actually live, not just compiling: open a Claude session with Focus Mode on and
  confirm runs of tool calls appear as one "Working · N steps" row that expands on tap. If every
  tool call still renders individually, the #248 modifier or item 1 above was dropped.

### 250. Workspace-list toolbar identity — `supermux-mobile-list-toolbar-identity`

The rule is one sentence: **never branch around `content` to add or remove the toolbar.** Keep a
single `content.toolbar { … }` and put `if showsNavigationToolbar` inside the
`ToolbarContentBuilder`. Two branches of a `_ConditionalContent` are two structural identities, so
an `if/else` around `content` destroys and rebuilds everything it wraps — including the UIKit table
— on every push and pop. `WorkspaceShellView.swift` already does it the correct way for
`rootToolbarContent`; match that shape. If an upstream merge reintroduces the `if/else`, the symptom
is the workspace list losing its scroll position and visibly repainting when you navigate back, not
a compile error.

### 251. Reconfigure, don't reload, on height-only updates — `supermux-mobile-list-reconfigure-rows`

In `apply(configuration:in:)`, the non-structural branch must partition `changedToApply` on
`nativeActionReloadIDs`: reconfigure the rest, reload only those. `reconfigureRows(at:)` keeps the
same cell instance (so hosted SwiftUI `@State` and `.task` survive) while still re-querying the row
height, which is the only thing that branch actually needs. `reloadRows` is still required for a
changed native-action payload because UIKit caches swipe-derived accessibility actions on the cell.
Leave the `reloadRows` in `didEndEditingRowAt` alone — it exists for that same cache and runs at
UIKit's own boundary after the swipe controls close. Reverting to a blanket `reloadRows` here does
not fail any build; it silently reintroduces project avatars blanking whenever an unrelated row
changes height.

### 228–229, 237. Persistent iOS workspace toolbar actions — `ios-workspace-toolbar-persistent-actions`

Root cause this guards against: on iOS 26 every extra trailing `ToolbarItem` risks UIKit's
native overflow ("More" / `OverflowBarButtonItem`) evicting a state-varying subset of items the
moment leading + trailing exceed the bar's item band (~362pt on a 402pt phone) — with the
alt-screen notice, upstream Changes, and the fork entries all conditional, and the back
button's unread badge alone worth ~18pt, the bar looked different per pane/agent state,
sometimes collapsing entirely to one native •••. Two invariants:

1. EXACTLY ONE trailing `ToolbarItem` (`workspace-trailing`) with a fixed two-control cluster —
   Agent Chat (always mounted, `.disabled` until the visible tab has a session) and the
   terminal picker. No dedicated overflow button.
2. Everything lower-frequency lives in the workspace TITLE menu
   (`workspaceTitleToolMenuEntries`, appended after `WorkspaceTitleMenuContent`): upstream
   Changes (keeps id `MobileChangesButton`; title appends live `+N −M` from
   `workspaceChangesChip`), the fork's Changes/Files rows
   (`SupermuxWorkspaceToolsMenuEntries`, #108), and the alt-screen notice row (same
   `isAlternateScreen` + `showAltScreenNotice` conditions as the old standalone item; presents
   the shared `AltScreenNoticeExplanationContent` popover anchored on the detail body, since a
   menu row cannot anchor one). The title menu's `isEnabled` must OR in these entries, and
   `WorkspaceTitleMenuValue.toolEntriesFingerprint` must fingerprint their inputs or
   `.equatable()` pins a stale menu closure.

Menu actions that present something must defer their state flip one main-actor turn
(`Task { @MainActor in … }`) so the presentation does not race the menu's dismissal. The fork
sheets get keyboard-dismiss parity via `onChange` of their presentation bindings calling
`dismissTerminalKeyboardForChrome()` — one chrome policy for all three entries. In
`MobileLeadingToolbarTitleWidth`, `backButtonReserve` (60) keeps unread-badge headroom and
`floor` (80) keeps the title pill from pushing the cluster into overflow even in the badge +
long-title worst case.

In `ios/cmuxUITests`, `testWorkspaceDetailToolbarKeepsPersistentActionsVisibleWithLongTitleWithoutChatSession`
keeps the no-chat-session preview and asserts `MobileWorkspaceAgentChatButton` exists but is
disabled and no native overflow button replaces the controls. This intentionally overrides
upstream's old assertion that the chat button disappears without a descriptor.

### 217–227. iOS pane close + Simulator creation — `ios-pane-actions`

Keep the Mac mutation surface in the existing fork namespace rather than adding more upstream dispatch cases: `SupermuxMobileMethod.paneClose` / `.simulatorCreate`, `SupermuxMobileCapability.panesV1`, the matching authorization classifications, and the handlers in `Sources/Supermux/TerminalController+SupermuxMobile.swift`. Close must resolve an explicit `workspace_id` + `panel_id`, verify the panel belongs to that workspace, mark it history-eligible, and call the single generic `Workspace.closePanel(force: true)` path — never branch by terminal/browser/Simulator type. Simulator creation must reuse `Workspace.newSimulatorSurface(inPane:focus: false)`, remain gated by the upstream Simulator feature/capability, and return the normal `MobileSimulatorPanelDescriptor`. Phone requests add `focus: true`; the Mac then routes the created panel through the shared control-focus action before replying and closes it if that focus phase fails. A missing flag retains the older background-create behavior.

On iOS, keep one captured-target confirmation path. `WorkspaceActiveSurface.paneCloseTarget` maps terminal and Agent Chat to the selected terminal id, the phone-local browser to local close, and streamed browser/Simulator to their panel ids. `WorkspaceDetailView+SupermuxPaneActions.swift` owns the action: the local fallback closes through `BrowserSurfaceStore`; remote panes call the capability-gated fork client and wait for authoritative workspace/browser/Simulator events instead of mutating optimistic copies. The existing browser × and the surface-picker Close Pane item must both call `requestClosePane`. New Simulator uses a request UUID exactly like New Browser so a late response cannot override a newer user selection; install the returned descriptor into `MobileSimulatorStreamStore` before selecting it.

The native surface picker carries only two availability booleans and two closures; localized menu/confirmation UI lives in fork-owned `SupermuxMobileUI` (`supermux.panes.*`, en + ja). Against an upstream Mac or an older fork host without `supermux.panes.v1`, remote close and New Simulator stay hidden; the phone-local browser remains closable. Re-run the headless SupermuxMobileCore/Kit/UI package tests, compile the app-hosted suites, and preserve the focused coverage in #224–227.

### 230–236. ccx-specific Claude session restore — `ccx-resume-launcher`

`ccx` ends with `exec ... claude`, so process capture sees the real Claude binary and expanded ccx-generated flags but loses the launcher identity, proxy-key discovery, current model fleet, and system-prompt construction. Keep the contract explicit and narrow: `~/.local/bin/ccx` exports `CMUX_CLAUDE_RESUME_LAUNCHER` with its absolute path before `exec`; `AgentLaunchEnvironmentPolicy` retains that non-secret marker only when it standardizes to the current user's exact `~/.local/bin/ccx`, and only for kind `claude`. Never allowlist `ANTHROPIC_AUTH_TOKEN` or accept raw shell commands/arbitrary executable paths.

Thread the captured environment through all three resume-argv entrypoints: `AgentRestorePlanner`, app-side `AgentResumeCommandBuilder` in `RestorableAgentSession.swift`, and hook-side `agentSurfaceResumeCommand` in `CLI/cmux.swift`. `AgentResumeArgv` must return only `[ccxPath, "--resume", sessionID]` for a valid marker so ccx dynamically rediscovers credentials and rebuilds its generated settings/agents/prompt; do not replay the expanded captured ccx arguments into ccx because that duplicates its own flags. With no valid marker, retain upstream's bare `claude --resume ...` wrapper route unchanged.

For structured restore, `AgentRestorePlanner.routeManagedWrapper` leaves the validated ccx path direct but still adds `CMUX_AGENT_RESTORE_LAUNCH=claude:<session-id>`, which ccx passes through to the cmux Claude wrapper it invokes. For inline fallback commands, `AgentRestoreLaunch.applying(toStoredCommand:)` likewise recognizes the validated ccx executable and adds authorization without replacing it with the ordinary Claude wrapper token. Keep `SupermuxCCXResumeLauncherTests` as a whole-file package test and run `swift test --package-path Packages/macOS/CMUXAgentLaunch`; the suite must cover direct ccx argv, authorization, marker persistence without token persistence, kind isolation, and invalid-marker fallback.

### 215–216 (including 215a–b). Deferred arrowless-popover presentation and dynamic reanchoring — `popover-dynamic-height-reanchor`

`ArrowlessPopoverAnchor` manually sizes and presents an `NSPopover` from `NSViewRepresentable.updateNSView`. The initial implementation updated the hosted SwiftUI root, forced layout, and called `show(relativeTo:of:preferredEdge:)` synchronously inside that representable update. On macOS 27, opening Token Usage hit AppKit's child-window ordering while SwiftUI was still rendering, logged `Publishing changes from within view updates` plus reentrant `NSHostingView` layout, and then crashed in `ObservationTracking._AccessList` when a deferred focus notification read `WorkspacesModel.tabs`.

Keep all popover lifecycle mutations outside the representable update turn and the originating AppKit layout cycle. A main-actor `Task` is insufficient on macOS 27: dogfood showed it could close the child window in the same cycle and still emit `NSHostingView is being laid out reentrantly` for every dismissal. `CmuxPopoverVisibleUpdateScheduler` therefore coalesces on the next common-mode main-run-loop turn with generation-based cancellation. A hidden requested popover installs/layouts the latest root view and then presents it there. A dismissal cancels a pending initial show; if a popover is already present, close it through the same scheduler. Re-opening before that close runs cancels the stale dismissal. The coordinator's injectable `showPopover` seam exists so the package test can prove no presentation occurs synchronously and that open→close cancellation suppresses the show without opening a real window.

Installing a new `NSHostingController.rootView` and forcing its layout must also be separate run-loop phases: the root update invalidates intrinsic size, then a second scheduled turn measures and presents or resizes/reanchors. This prevents live scan-progress and animation updates from laying out the hosting view while SwiftUI is still rendering the newly installed root. For an already-visible popover, keep the latest `preferredEdge` and `detachedGap`; when the rounded fitting size differs from `popover.contentSize`, set the new size and call `show(relativeTo:of:preferredEdge:)` again on the SAME popover, inside the no-implicit-animation scope. AppKit documents that re-showing an already-visible popover updates its positioning view and rect. Do nothing for dismissed/hidden popovers, invalid fitting sizes, or unchanged rounded sizes. The focused package tests in #216 pin the deferral, cancellation, and mutation plan. Re-apply all four files together, then run `swift test --package-path Packages/macOS/CmuxAppKitSupportUI`.

### 208–211. Alternate-screen whole-line quantization — `ios-terminal-alt-scroll-quantize`

Physical trace at 0.25× speed: two slow drags emitted 101 fractional scroll packets of 0.03–0.11 lines (totaling 0.70 and 1.30 lines), yet the TUI scrolled dramatically — the Mac's wheel handling rounds each delivery to a minimum magnitude of one line, so speed was proportional to PACKET COUNT and both the scroll-speed preference and finger travel were irrelevant. Keep `TerminalAlternateScrollLineQuantizer` (signed carry, trunc-toward-zero emit, non-finite ignored) and run budget-admitted alt-screen lines through the per-surface quantizer in `scrollTerminal`, forwarding only whole lines. This is interpreted identically by discrete and precise-pixel hosts, makes delivered lines proportional to finger travel × speed preference, and cuts RPC volume. Primary-screen scrolling is untouched (it needs fractional precision for the 1:1 local mirror). Tests: `TerminalAlternateScrollLineQuantizerTests`.

### 203–207. Alternate-screen gesture direct apply — `ios-terminal-alt-scroll-direct-apply`

Dogfood after the momentum fixes: TUI scrolling was "fast and kinda janky and delayed, not smooth". Cause: every alt-screen repaint delta went through the verified pipeline's serial freeze/apply/present/GPU-read-back/verify fence, which cannot drain gesture-rate repaints — motion arrived in clumps. Keep `TerminalAltScrollDirectApplyPolicy` (window 0.8 s, full frames always verified, backwards clock fails closed). `scrollTerminal` stamps `terminalAlternateScrollLastInputAtBySurfaceID` when the budget admits alt-screen lines; `requiresVerifiedReplayApplication` returns `false` for alt-screen delta frames inside the window so they take the ordered legacy VT-patch path (the consumer's `terminalOutputApplicationPath` keys purely off the chunk flag — no consumer change needed; this is the same direct path screen-anchored primary deltas already use). Correctness is deferred, not lost: the first verified delta after the window performs the exact-pixel comparison, and any drift triggers the standard full-replay recovery. Tests: `TerminalAltScrollDirectApplyPolicyTests`.

### 196–202. Terminal scroll speed setting — `ios-terminal-scroll-speed`

User-tunable wheel sensitivity, added after dogfood found alt-screen scrolling "too fast" once the backlog fixes landed. Keep the shared `MobileTerminalScrollSpeedPreference` (key `cmux.mobile.terminalScrollSpeed`, range 0.25–1.5, default 1.0) in CMUXMobileCore. `GhosttySurfaceView.scrollSpeedMultiplier` multiplies the point→line conversion in `enqueueScrollMechanicsDelta` ONLY — never scale `TerminalNativeScrollGeometry` samples, which map bounded primary history 1:1 to the finger. CRITICAL: the alt-screen budget (#189/#191) must admit in unscaled gesture units via `admit(lines:speed:at:)` — dogfood proved that with an absolute cap, fast drags saturate at the same delivered count at every speed and the slider is imperceptible on TUIs. `MobileDisplaySettings.terminalScrollSpeed` persists it beside `terminalScrollbackRows`; `MobileSettingsView` renders a Display-section slider (`MobileSettingsTerminalScrollSpeed`); the detail view threads it into `GhosttySurfaceRepresentable`, which applies it in `makeUIView` and `updateUIView` for live effect. Localization keys `mobile.settings.terminalScrollSpeed` and `.footer` need en + ja. Tests: `MobileTerminalScrollSpeedPreferenceTests`, the scroll-speed cases in `MobileDisplaySettingsTests`, the multiplier-validation case in `GhosttySurfaceNativeScrollTests`, and the speed-proportional budget case in `TerminalAlternateScrollBudgetTests`.

### 193–195. Output backlog coalesce — `ios-terminal-output-backlog-coalesce`

The decisive physical trace: during a fast alt-screen scroll gesture the phone's per-surface `TerminalOutputDeliveryQueue` reached 90–101 pending frames (alt-screen dirty-row deltas are nonreplaceable), then drained one verified apply at a time for up to 4 s after touch-up. That drain IS the user-visible "momentum"; the UIScrollView and the input-side budget were already clean. In `deliverTerminalOutput`, after enqueueing, when `pendingCount >= maxTerminalOutputPendingBeforeReplayCoalesce` (24, declared in `MobileShellComposite.swift`), the delivery is a render-grid frame, and no replay barrier bypass is active: replace the queue with a fresh `TerminalOutputDeliveryQueue`, rotate the stream token, remove stale barrier-ack bookkeeping, log `terminal.output.backlog_coalesce`, and call `terminalOutputNeedsReplay(surfaceID:)` so one authoritative replay supersedes the entire backlog. Do not drop individual deltas (stateful patches) and do not coalesce raw-byte chunks. Regression: `TerminalOutputBacklogCoalesceTests.swift`.

### 189–192. Alternate-screen scroll budget — `ios-terminal-alt-scroll-budget`

Physical-iPhone SCROLLDIAG traces proved the phone's UIScrollView stops at touch-up (zero post-release didScroll), yet the user still saw coasting on an alternate-screen TUI. Root cause: each forwarded wheel line becomes a discrete TUI input on the Mac (arrow key or mouse report via `Surface.zig scrollCallback`), and a fast drag emits lines faster than the RPC → PTY → TUI-repaint → phone-frame pipeline consumes them; the surplus replays after the finger lifts. Keep the whole fork file `TerminalAlternateScrollBudget.swift` (token bucket over line magnitude; excess dropped, never queued — queuing recreates the deferred playback). In `MobileShellComposite` store per-surface budgets beside the scroll queues, reset them with the other terminal state on reconnect, and drop them on surface removal. In `scrollTerminal`, admit through the budget only when `terminalActiveScreenBySurfaceID[surfaceID] == .alternate`; never throttle primary or unknown screens (primary is local-authority bounded scrolling; unknown may be pre-first-frame TUI input).

### 187. `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift` — `ios-terminal-native-scroll`

Inside the existing DEBUG harness routing, add `CMUX_NATIVE_SCROLL_STRESS=1` before `CMUX_BOTTOM_SCROLL_STRESS` and render `MobileBottomScrollStressView(nativeScrollOnly: true)`. Keep the ordinary bottom-scroll route unchanged. This file also carries #164; preserve both independent fences.

### 186. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressRepresentable.swift` — `ios-terminal-native-scroll`

Add a `nativeScrollOnly` input and construct `MobileBottomScrollStressCoordinator(nativeScrollOnly:)`. The representable's runtime/view mounting remains unchanged.

### 185. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressView.swift` — `ios-terminal-native-scroll`

Add a defaulted public `init(nativeScrollOnly: Bool = false)`, store the mode, and pass it to the representable. Default false must preserve every existing caller and the original viewport-shrink stress scenario.

### 184. `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/TerminalNativeScrollGeometryTests.swift` — whole-file native-scroll geometry coverage

Keep the whole new Swift Testing suite based on upstream PR #9762. It must cover authoritative range/content height, fractional point-to-row deltas, both rubber-band edges without reverse scroll, sub-row presentation translation and two-row lag clamp, appended history, fail-closed missing bounds (including zero cell height), and pending-scroll synchronization deferral. Release behavior is not a geometry decision: #181 exercises it through the real UIScrollView delegate path for both fast and slow drags.

### 183. `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/GhosttySurfaceNativeScrollTests.swift` — whole-file precise-scroll integration coverage

Keep the whole new UIKit/Ghostty integration test file based on upstream PR #9762. First prove bounded primary history requires `.legacyMirror` local authority and is disabled for `.verifiedRenderGrid` or alternate-screen delivery. Then seed real local scrollback, position at the bottom using the revision-checked Ghostty API, apply 0.25 of a row and prove the viewport does not move, then apply the remaining 0.75 and prove it moves exactly one row. The fractional test must exercise `applyLocalScrollbackScroll`, not only geometry math.

### 182. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/TerminalNativeScrollGeometry.swift` — whole-file native-scroll geometry model

Keep the whole new `#if canImport(UIKit)` pure-value model from upstream PR #9762. `maximumRowOffset` derives from Ghostty total/visible rows; point range is row range × cell height; samples clamp to the real range and emit precise fractional row deltas; overdrag emits translation only; confirmed-primary-without-boundary uses `zeroRange`; interacting presentation combines rubber band with at most two rows of authoritative lag compensation.

### 181. `ios/cmuxUITests/cmuxUITests.swift` — `ios-terminal-native-scroll`

Keep `testTerminalNativeScrollUsesBoundedPrimaryHistory` beside the existing bottom-scroll stress test. Launch with `CMUX_NATIVE_SCROLL_STRESS=1` and require a primary bounded range at the Ghostty-confirmed bottom. Use coordinates inside the terminal (not the center when composer/keyboard stress is active). After a slow outward drag, prove the raw offset remains at the authoritative maximum, Ghostty history does not reverse, and translation settles to zero. Then perform short in-history drags with both `.fast` and `.slow` XCUITest velocities. Each must report no deceleration immediately after release, move more than 20 points but no farther than the physical drag plus 30 points, settle with zero translation/tracking, and survive a 0.75-second inverted observation window without more than two points of drift.

### 180. `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Mobile.swift` — `ios-terminal-native-scroll`

In `mobileScroll`, retain the existing cell-center mouse position. Convert `deltaLines` to backing-pixel distance with `size.cell_height_px` and call `ghostty_surface_mouse_scroll` with the precise flag (`0b0000_0001`). Do not revert to line-mode delivery: fractional iPhone movement must accumulate in Ghostty and alternate-screen mouse reporting must remain mode-correct.

### 179. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileBottomScrollStressCoordinator.swift` — `ios-terminal-native-scroll`

Give the coordinator a defaulted `nativeScrollOnly` initializer flag. After the local-only stress harness reaches the Ghostty-confirmed bottom, call `setNativeScrollScreen(.primary)`; no paired Mac frame exists here, so without that declaration its UI test silently exercises the legacy unbounded path. When `nativeScrollOnly` is true, set phase `done` and return before mounting the composer/keyboard viewport stress. Default false must continue through the original scenario unchanged.

### 178. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` — `ios-terminal-native-scroll`

Re-apply the production coordinator from upstream PR #9762 head `1420c2c972`, plus the fork's authority and release-behavior hardening. Track authoritative screen/boundary, raw/effective UIKit offsets, and presentation translation. Primary screen uses `TerminalNativeScrollGeometry` for bounded content size, edge rubber band, fractional row deltas, and at-most-two-row layer compensation **only when** `scrollPresentationAuthority.appliesLocally`; Mac-authoritative `.verifiedRenderGrid` sessions must keep the unbounded wheel path so gestures still reach the Mac even when the local mirror has no history. Reconfigure when authority changes. Set `decelerationRate` to `UIScrollView.DecelerationRate(rawValue: 0)`. In `scrollViewWillEndDragging`, always pin `targetContentOffset` to the current offset regardless of release velocity. In `scrollViewDidEndDragging`, unconditionally disable/re-enable the pan recognizer to clear UIKit's physics state, then set the current content offset non-animated before flushing and settling. All three layers are required: physical iOS 26 was observed resuming deceleration after target-offset and same-offset cancellation alone. A locally-owned confirmed primary screen with no boundary fails closed to zero range; alternate/unknown screen retains the recentered unbounded wheel surrogate. Store scrollbar boundaries regardless of frame/action arrival order, flush pending deltas at drag/deceleration end, settle only after interaction and local applies drain, clear all state on surface replacement, and reset translation before typed-input bottom snap. Apply translation to live renderer layers, the frozen verified container, and fallback view—never the frozen content child. Keep the DEBUG probe fields used by #181.

### 177. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplayFrozenPresentation.swift` — `ios-terminal-native-scroll`

Initialize the frozen presentation container's transform from `nativeScrollContentTranslationY`. Deliberately omit upstream's `copy.transform = renderer.transform` when copying renderer contents: the container alone owns translation, otherwise a verified freeze offsets the snapshot twice.

### 176. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplay.swift` — `ios-terminal-native-scroll`

In frozen-presentation layout, do not assign `frozenLayer.frame` while the layer may have a translation transform. Set `bounds = layer.bounds` and center `position` explicitly, then continue laying out background/content as upstream.

### 175. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+LocalScrollbackScroll.swift` — `ios-terminal-native-scroll`

On the serial output queue, compute cell-center mouse position as before, then convert logical lines to backing-pixel distance and set Ghostty's precise-scroll flag. After each batch, pump any accumulated follow-up; when the pump is drained, call `settleBoundedScrollMechanicsIfPossible()` so an idle authoritative boundary can resynchronize after the in-flight flag had deferred it.

### 174. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttyRuntime.swift` — `ios-terminal-native-scroll`

Handle `GHOSTTY_ACTION_SCROLLBAR` outside `#if DEBUG`. For surface targets, hop to the main actor and call `updateNativeScrollBoundary(total:offset:len:)` in every build. Keep stress-harness recording and anchormux logging inside DEBUG conditionals, and return true after consuming the action.

### 173. `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift` — `ios-terminal-native-scroll`

After a verified frame successfully applies, call `setNativeScrollScreen(frame.activeScreen)` before acknowledging output. In the legacy path, do the same when the chunk carries a source render-grid frame. Never switch screen mode from an unverified/rejected frame.

### 172. `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/MobileTerminalRenderGridVisualSnapshotTests.swift` — `verified-replay-semantic-bold-color`

Keep the behavioral visual-snapshot regression that builds bold spans carrying semantic palette metadata. The producer-bright (`#F07178`) and replay-normal (`#EA6C73`) versions of palette index 1 must compare equal, while a different palette index must compare unequal. A bold literal-RGB pair with those same resolved values must also remain unequal, proving the exception cannot weaken true-color verification.

### 171. `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridVisualSnapshot.swift` — `verified-replay-semantic-bold-color`

In `normalizedStyle`, canonicalize a bold foreground semantically only when its source is `.defaultColor`, or `.palette` with a valid palette index. For those styles, clear the resolved foreground and retain the semantic source/index in the normalized style. Keep resolved RGB comparison for literal `.rgb`, legacy source-less styles, non-bold styles, and invalid palette metadata. The purpose is narrow: Ghostty's `bold-color` config can change the resolved foreground without changing the VT style the phone replayed, and that config-level mismatch must not freeze an otherwise identical grid behind the verified-replay layer.

### 170. `cmuxTests/MobileHostTerminalThemeTests.swift` — `ghostty-bold-is-bright-mobile-theme`

Keep the host-theme integration regression beside the existing semantic-color payload test. Parse `bold-is-bright = true` through `GhosttyConfig`, construct `TerminalTheme(ghosttyConfig:)`, serialize `mobileHostJSONObject`, decode it back as `TerminalTheme`, and assert both `boldColor == "bright"` and a resulting `bold-color = bright` Ghostty directive. This pins the exact Mac-producer → wire → phone-config path that failed on the physical iPhone.

### 169. `Packages/macOS/CmuxTerminalCore/Tests/CmuxTerminalCoreTests/GhosttyConfigBoldColorTests.swift` — `ghostty-bold-is-bright-mobile-theme`

Keep the focused parser regression asserting that the legacy `bold-is-bright = true` compatibility alias sets `GhosttyConfig.boldColor` to `"bright"`, matching the canonical `bold-color = bright` directive.

### 168. `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Config/GhosttyConfig.swift` — `ghostty-bold-is-bright-mobile-theme`

In `GhosttyConfig.parse`, recognize `bold-is-bright` with the same true spellings Ghostty's compatibility parser accepts (`1`, `t`, `T`, `true`). Set `boldColor = "bright"` only for those values; false or invalid values remain no-ops, matching Ghostty's `compatBoldIsBright` behavior. This Swift-side parity is required because the Mac render core already honors the alias, while mobile theme serialization reads `GhosttyConfig.boldColor`.

### 164. `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift` — `official-ios-persistence-scope`

In `makeStore`, retain the raw `MobileIOSBuildScope.current()` as `detectedBuildScope`, resolve `MobileMacBuildCompatibilityPolicy.current(buildScope:)` from it, then derive the `buildScope` passed to `makeBackedUpPairedMacStore` through `buildCompatibilityPolicy.persistenceScope(from:)`. Do not pass the raw detected scope directly: a personal-team Release build often needs a `dev.cmux.ios.<suffix>` bundle id, but Release policy is official and must not create an inner development-only store that rejects the Stable/Nightly Mac the live connection already accepted.

### 163. `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileMacBuildCompatibilityPolicyTests.swift` — `official-ios-persistence-scope`

Keep a pure policy test using a non-empty `MobileIOSBuildScope`. Assert `.official.persistenceScope(from:)` returns `nil`, and `.development(expectedInstanceTag:)` returns the detected scope unchanged. This pins the Release-sideload case without depending on compile configuration or bundle globals.

### 162. `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileMacBuildCompatibilityPolicy.swift` — `official-ios-persistence-scope`

Keep the documented public `persistenceScope(from:)` method on the compatibility policy. Development returns the detected scope; official returns `nil`. Storage and backup partitioning must follow the same policy that validates authenticated Mac instance tags, rather than independently inferring development status from a sideload bundle id.

### 161. `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobilePairedMacPersistenceFailureTests.swift` — `paired-mac-persistence-result`

Keep the stale-authority regression beside the failed-database-write test. Use a real temporary `MobilePairedMacStore`, call `persistPairedMacFromTicket` with `ifStillCurrent: { false }`, and assert the call returns `false`, the store remains empty, and `hasKnownPairedMac` stays false. The test must exercise the serialized-write seam rather than only testing a boolean helper.

### 160. `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+PairedMacPersistence.swift` — `paired-mac-persistence-result`

For a real persistable ticket/store, initialize the returned `accepted` flag to `false`. In the conditional `.preserveOnlyIfUnclaimed` path, keep the store result in a local `didUpsert` and return early when it is false. Set `accepted = true` only after that accepted mutation or the ordinary `upsert` completes. The function's existing early guard may still return `true` for deliberately non-persistable manual/anonymous sentinel tickets, but a skipped serialized operation, stale scope, lost connection authority, conditional rejection, or thrown write must never claim persistence succeeded.

### 159. `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileCoreRPCSessionPipelinedTests.swift` — `mobile-rpc-client-work-quota`

Keep the quota regression beside the existing pipelined wire-order test. Create a `ControllableResponseTransport`, enqueue one more request than the client window (`MobileHostRPCWorkQuota.recommendedMaximumConcurrentRequestCount - 1`), and wait until the window is full. After yielding enough for the writer to run, the transport must still have sent only the window count. Deliver one response, then prove exactly one queued request is sent. The test must exercise the real session writer and response dispatcher; do not replace it with source-text or quota-struct-only assertions.

### 158. `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession+IndependentEvents.swift` — `mobile-rpc-client-work-quota`

In `dispatch(frame:)`, after parsing a non-event envelope's string request id but before rejecting an id with no live local continuation, call `releaseRequestWorkCapacity(requestID:)`. A caller can cancel or time out after its request was written while the host still finishes and responds; that late response must release the wire-capacity slot even though its result is no longer delivered locally. Keep event envelopes unchanged.

### 157. `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift` — `mobile-rpc-client-work-quota`

Carry each authenticated payload's decoded byte count on `PendingWrite`. In the session actor, retain a `MobileHostRPCWorkQuota` configured to one fewer than the host's recommended request count, plus a request-id-to-byte-count map for requests already written and not yet answered. The one-slot margin covers the ordering window where the phone has received a response but the Mac actor has not yet removed its completed response task.

Before `writeLoop` calls `transport.send`, wait until the quota admits the pending write against the active byte counts, then re-check that the request still awaits a response and record its count. A response id removes that count through #158 and resumes capacity waiters. Teardown must clear the counts and resume all waiters so the writer cannot remain suspended. Preserve the existing queue cancellation and timeout behavior: a request cancelled while still waiting for capacity is skipped, while a request already on the wire retains its slot until the host responds or the session tears down.

### 156. `Packages/iOS/CmuxMobileTransport/Tests/CmuxMobileTransportTests/CmxTailscaleRouteProofTests.swift` — `tailscale-packet-tunnel-proof`

Keep both packet-tunnel regressions beside the existing exact IPv4/IPv6 proof test. First, build a valid proof and validate a satisfied connection path whose available interfaces include the proven Tailscale interface, whose remote address/port exactly match the route, and whose `localAddress` is `nil`; validation must succeed. Second, validate the same proof against a newer authority generation whose security-relevant route is otherwise identical; that must also succeed. Keep the fail-closed companions: a non-nil local address outside `proof.selfAddresses` throws `localEndpointMismatch`, and replacing the proven interface identity throws `interfaceChanged` even when the replacement reports the same Tailscale self-addresses. All additions stay inside the fence.

### 155. `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxTailscaleRouteProof.swift` — `tailscale-packet-tunnel-proof`

In `CmxTailscaleRouteProofValidator.validate`, do not reject a proof merely because the generic `NWPathMonitor` authority generation advanced. Remove the `authoritySnapshot.generation == proof.generation` guard and keep the fenced rationale in its place. Network.framework can publish a distinct path revision immediately after a packet-tunnel connection becomes ready even though the route's security-relevant properties are unchanged; treating that revision counter as authority tears down a valid session immediately after pairing.

Also treat `connectionPath.localAddress` as an optional extra proof rather than a required field:

```swift
// SUPERMUX:begin tailscale-packet-tunnel-proof
if let localAddress = connectionPath.localAddress,
   !proof.selfAddresses.contains(localAddress) {
    throw CmxTailscaleRouteProofError.localEndpointMismatch
}
// SUPERMUX:end tailscale-packet-tunnel-proof
```

Do not weaken the security-relevant checks around these changes: the current authority path must be satisfied and still expose exactly one matching Tailscale interface with the prepared interface identity and self-address set; the connection path must be satisfied and contain that exact interface; and the remote address/port must exactly match the authorized peer. Network.framework can also report `localEndpoint == nil` for a ready packet-tunnel connection while all of those stronger route/interface checks succeed, so requiring a non-nil value makes every valid Tailscale dial fail locally before credentials are written.

### 154. `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellEventStreamPerformanceTests.swift` — whole-file regression coverage

Keep this whole fork-owned Swift Testing file compiled by the `CmuxMobileShellTests` SwiftPM target. It must exercise the real connected-store/liveness-router path and prove all three contracts:

- consuming a pushed event still advances `lastTerminalEventAt` without publishing an Observation change;
- a watchdog evaluation while `foregroundRefreshIsActive == false` starts no `mobile.events.probe` request;
- a delayed successful probe that was already in flight when the app backgrounded cannot mark the visible connection healthy afterward.

The tests reuse `makeConnectedStore`, `LivenessHostRouter`, `TestClock`, `TransportBox`, and the render-grid frame fixtures. Do not replace them with source-text assertions or wall-clock-only benchmarks.

### 153. `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellRenderGridLivenessTestSupport.swift` — `mobile-liveness-background-gate`

Add a delayed-success probe mode alongside the existing held-failure mode in `LivenessHostRouter`:

```swift
// SUPERMUX:begin mobile-liveness-background-gate
private var delayedProbeRequestNumbers: Set<Int> = []
// SUPERMUX:end mobile-liveness-background-gate
```

Expose `delayProbeRequest(number:)`, clear its set from `releaseAllHeld()`, and in the `mobile.events.probe` response path park matching requests before returning the ordinary healthy response. Keep each addition inside the same fence id. A `holdProbeRequest` must still resume to `nil`; only the delayed mode resumes to a valid result, which is what lets #154 test the late-success race.

### 152. `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` — mobile liveness performance and lifecycle guards

**`mobile-event-liveness-observation`:** the event timestamp and failure counter are internal watchdog bookkeeping with no SwiftUI readers, so keep them out of the Observation registrar:

```swift
// SUPERMUX:begin mobile-event-liveness-observation
@ObservationIgnored private var renderGridLivenessConsecutiveProbeFailures = 0
@ObservationIgnored var lastTerminalEventAt: Date?
// SUPERMUX:end mobile-event-liveness-observation
```

**`mobile-liveness-background-gate`:** at the start of `checkRenderGridLiveness(listenerID:)`, return unless `foregroundRefreshIsActive`. In the probe task, after clearing that probe's single-flight slot and before applying its result, re-check the same flag. Both guards must stay fenced:

```swift
// SUPERMUX:begin mobile-liveness-background-gate
guard foregroundRefreshIsActive else { return }
// SUPERMUX:end mobile-liveness-background-gate
```

The second site uses `self.foregroundRefreshIsActive`. Do not move the `DispatchSourceTimer` off `.main`, suspend/resume it, or add another timer/draw loop: upstream's comment documents the Swift 6 executor trap that the main-queue timer avoids. The intended behavior is only that background ticks and late probe completions become no-ops; foreground dead-stream recovery remains unchanged.

### 147. `.github/workflows/ci.yml` — `local-release-script-guard`

In the Linux preflight validation list, immediately after the release-build timeout guard, run the
fork-owned local Release-script regression:

```yaml
# SUPERMUX:begin local-release-script-guard
- name: Validate supermux local Release script
  run: ./tests/test_supermux_release_stale_artifact.sh
# SUPERMUX:end local-release-script-guard
```

The test copies `scripts/supermux-release.sh` into an isolated temporary repository and mocks
`security`, `ensure-ghosttykit.sh`, `xcodebuild`, signing, plist mutation, app shutdown, and launch.
Its combined-path regression executes the real parent script and proves the iOS helper finishes
before the installed Supermux app is quit or killed; this ordering is load-bearing because the
script is normally hosted by a Supermux terminal whose PTY teardown SIGHUPs its child jobs. It also
runs the fork-owned `tests/test_supermux_ios_release.sh`, which executes
`scripts/supermux-ios-release.sh` against mocked `xcodebuild`, `xcrun`, `codesign`, `security`, and
`PlistBuddy` commands. The iOS regression proves the Release, untagged, production-auth fixed-id app
and its notification service extension use the per-target signing indirection, are re-signed with
their own Ad Hoc profiles, retain production APNs, Time Sensitive, Communication Notifications,
and the shared app group, then install and launch. Neither test may sign, install, or launch a real
app. Keep them in a cheap preflight job rather than a macOS build lane.

### 146. `Sources/ContentView.swift` — `sidebar-usage-button`

In `SidebarFooterButtons.body`, the `shows(.help)` branch mounts the fork's usage button in
front of upstream's help button, which stays exactly as upstream ships it:

```swift
if shows(.help) {
    // SUPERMUX:begin sidebar-usage-button
    SupermuxUsageMenuButton()
    // SUPERMUX:end sidebar-usage-button
    SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
}
```

If upstream restructures the footer, the requirement is: mount `SupermuxUsageMenuButton()`
(no arguments) adjacent to wherever the help "?" button renders — it matches the footer's 22pt
button metrics and `SidebarFooterIconButtonStyle`, and never replaces or wraps any upstream
button. The button's pbxproj wiring is `50BE0001…00FD`/`…00FE` (see #3); everything else lives
in `Packages/SupermuxKit/Sources/SupermuxKit/Usage/` and `UI/SupermuxUsagePopoverView.swift` /
`UI/SupermuxUsageGaugeIcon.swift` (package files, no wiring).

### 146b. `Sources/ContentView.swift` — `sidebar-usage-analytics-button`

In `SidebarFooterButtons.body`, the `shows(.help)` branch mounts the fork's analytics button
directly after the usage-limits button of #146, with upstream's help button still last and
unchanged:

```swift
if shows(.help) {
    // SUPERMUX:begin sidebar-usage-button
    SupermuxUsageMenuButton()
    // SUPERMUX:end sidebar-usage-button
    // SUPERMUX:begin sidebar-usage-analytics-button
    SupermuxUsageAnalyticsMenuButton()
    // SUPERMUX:end sidebar-usage-analytics-button
    SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
}
```

If upstream restructures the footer, the requirement is: mount `SupermuxUsageAnalyticsMenuButton()`
(no arguments) next to the #146 button — it uses the same 22pt `SidebarFooterButtonMetrics` and
`SidebarFooterIconButtonStyle`, and never replaces or wraps any upstream button. Where #146
answers "how much quota is left", this answers "what have I spent": it reads Claude Code and
Codex session logs read-only and never writes to, refreshes, or deletes them. The button's
pbxproj wiring is `50BE0001…00FF`/`…0100` (see #3); everything else lives in
`Packages/SupermuxKit/Sources/SupermuxKit/UsageAnalytics/` and
`UI/SupermuxUsageAnalyticsPopoverView.swift` / `UI/SupermuxUsageAnalyticsChart.swift`
(package files, no wiring).

### 2. `Sources/ContentView.swift` — `sidebar-projects-section` + `sidebar-hide-project-workspaces`

**`sidebar-projects-section`:** in
`VerticalTabsSidebar.workspaceScrollContent(renderContext:minHeight:unreadSnapshot:)` (upstream
renamed the third parameter from `emptyAreaHeight:` to `unreadSnapshot:`), the
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
(a no-op when no projects are registered — and, since the 0.64.20 merge, whenever the AppKit
list experiment is enabled, see #130; the `tabManager:` parameter selects the calling window's
resolution cache). The filter also threads a `projectHiddenWorkspaceIds` set through
`WorkspaceListRenderContext`: shift-click ranges and the Close Other/Below/Above closures
exclude project-hidden workspaces (via the fenced parent-level
`supermuxProjectHiddenWorkspaceIds()` helper, computed only in event handlers and action
closures — never in a row `body`), Move Up/Down steps over hidden rows in the shared
`TabManager.reorderWorkspace(tabId:by:)` entrypoint (#131), the VoiceOver "workspace N of M"
announcement counts visible rows (#132/#133), and a fenced `.onChange` strips newly
project-hidden ids from `selectedTabIds`.

**`sidebar-flatrow-activity`:** small fenced edits give flat-list workspace rows the same agent
activity indicator as the nested rows, and make it the row's *only* agent-status signal. Policy:
only the amber **working** spinner ever renders — the needs-input (red) and ready (green) dots
are deliberately not shown on any Mac surface (sidebar rows, nested project rows, workspace
switcher cards), and the spinner always sits at the row's right edge:
1. `import SupermuxKit` near the top imports.
2. A `let supermuxActivity: SupermuxWorkspaceActivity` field on
   `SidebarWorkspaceSnapshotBuilder.Snapshot` (it is `Equatable`-synthesized, so the row
   re-renders when activity changes).
3. In `makeWorkspaceSnapshot()`, resolve `let supermuxActivity =
   SupermuxWorkspaceActivityResolver.activity(for: tab)` (the aggregate, for the indicator) and
   `let supermuxActivityByAgentKey = SupermuxWorkspaceActivityResolver.activityByAgentKey(for: tab)`
   (per agent key, for the filter) once each, pass the aggregate as the snapshot's
   `supermuxActivity:`, and route `metadataEntries` through
   `SupermuxSidebarAgentStatusRows.droppingAgentStatusRows(from:duplicatedBy:)`
   (`Sources/Supermux/SupermuxWorkspaceActivityResolver.swift`) so agent-published lifecycle
   rows (the blue "⚡ Running" `set_status` line) don't duplicate the indicator. The resolver
   ignores the reserved `manual`/`manual:<id>` workspace-loading keys (they drive cmux's gray
   spinner, not agent status). The filter matches each row against *its own agent's* resolved
   state, not the workspace aggregate — one agent's lifecycle never drops another agent's row —
   and only when the icon shape matches (`bolt.fill`↔working, `pause.circle.fill`↔ready,
   `bell.fill`↔needsInput) and the row carries no URL; agent error rows
   (`exclamationmark.triangle.fill`), status/lifecycle mismatches, rows with click-through
   URLs, rows for agents with no tracked lifecycle, and user-defined `set_status` rows keep
   rendering (covered by `cmuxTests/SupermuxSidebarAgentStatusRowsTests.swift`).
4. In `TabItemView`'s snapshot-shaping `let`s, suppress `showsLoadingSpinner` (cmux's gray
   braille spinner) while `supermuxActivity == .working` (manual loaders keep the gray spinner
   because the resolver ignores manual keys), and compute
   `supermuxIndicatorInTrailingSlot = workspaceSnapshot.supermuxActivity == .working
   && canCloseWorkspace && !badgeOnTrailing && !spinnerOnTrailing`.
5. In the row's title `HStack`: when `supermuxIndicatorInTrailingSlot`, render
   `SupermuxAgentActivityIndicator(activity:size:)` (size 6·scale, matching the nested rows) as
   an `.overlay` on `SidebarWorkspaceTrailingStatusSlot` (faded to opacity 0 while
   `showCloseButton` — kept mounted so hover never remounts the AppKit spinner — hit-testing
   off) so it occupies the reserved close-button slot instead of leaving an empty gutter at the
   row edge; otherwise render it inline after `Text(workspaceSnapshot.title)` as a fallback
   (sole workspace with no close slot, or unread badge occupying the slot).
The indicator is reactive via upstream's agent-runtime observation: every
`agentLifecycleStatesByPanelId` mutation routes through
`WorkspaceSidebarAgentRuntimeObservationModel.setAgentLifecycleStatesByPanelId` →
`notifyChanged()`, and the row's existing `.sidebarAgentRuntimeObservation(id:model:)` hook
rebuilds the snapshot on each change — so lifecycle-only mutations (`set_agent_lifecycle` with
no `set_status`, hibernation's lifecycle clears) re-render the row even though they touch
neither `statusEntries` nor `progress`. (`SupermuxWorkspaceLifecycleRelay` serves the projects
mount and mobile observers, not this row.) If upstream restructures the snapshot/row, the
requirements are: derive activity per workspace, render only the working spinner (no
needs-input/ready dots) once at the row's right edge without trailing dead space, and keep
cmux's own spinner and the duplicate agent-status metadata rows suppressed. The working-only
placement lives in supermux-owned files for the other surfaces: nested rows render the spinner
after the PR badge and run indicator (`SupermuxOpenWorkspaceRowView`), and the workspace
switcher badge gates on `.working` (`SupermuxWorkspaceSwitcherCard`).

**`sidebar-selection-faint`:** two computed members on **`TabItemView`** (there is no
`SidebarWorkspaceRow` type — the old name in this note was stale) are overridden so
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
   `isPointerHovering` (upstream: unconditional `.clear`), matching the nested rows' hover tint
   without touching the multi-select / custom-color tints. (`rowInteractionState` no longer
   exists — hover is snapshot-derived now.)
If upstream restructures the row, the requirement is: flat-list rows must visually match the
nested project-workspace rows — 11.5·scale title (semibold only when selected), compact line
stack, 5pt-radius chrome with the faint selection tint (`sidebar-selection-faint`) and a
primary-at-0.06 hover tint. All hover reads go through the already-rendered `isPointerHovering`
value — no new `@State` or observation, so the Equatable typing-latency contract is untouched.

**`sidebar-projects-empty-area`:** cmux sizes the sidebar scroll content to exactly fill the
viewport when everything fits — the empty drop/tap area below the last workspace row is a finite
remainder derived from `SidebarWorkspaceScrollLayout.contentMinHeight(viewportHeight:insets:)`
(`Sources/WindowChromeMetrics.swift`), not `maxHeight: .infinity`, which is what
stops the document from overflowing and showing a phantom scroller / scrollable empty space
(https://github.com/manaflow-ai/cmux/issues/3241). That fit assumes the workspace rows are the only
content. Because `sidebar-projects-section` inserts `SupermuxProjectsMount()` above the rows in the
same scroll content, its height must be subtracted from the remainder or the document overflows the
viewport by exactly the section's height and the empty space becomes scrollable. Three small edits in
`VerticalTabsSidebar`, all under this one fence id:
1. A `@State private var supermuxProjectsSectionHeight: CGFloat = 0` field.
2. In `workspaceScrollContent`, the content's
   `.frame(minHeight: max(0, minHeight - supermuxProjectsSectionHeight), alignment: .top)`
   instead of the raw `minHeight`.
3. In the workspace `ScrollView` modifier chain, an
   `.onPreferenceChange(SupermuxProjectsSectionHeightPreferenceKey.self)` writes the measured height
   into that `@State` (accepts growth immediately; dedupes only shrink jitter with a 0.5pt
   tolerance, so a stale-low height never inflates the filler into sub-point overflow).

   ⚠️ Upstream reshaped this area at the 0.65 merge: the named helpers this note used to cite
   (`SidebarWorkspaceScrollLayout.emptyAreaHeight`, `workspaceRowsMeasurement`,
   `SidebarWorkspaceRowsHeightPreferenceKey`) **no longer exist**. The requirement is unchanged —
   subtract the measured Projects-section height from whatever quantity upstream uses to size the
   scroll content to the viewport — but locate the current site by `git grep -n
   'supermuxProjectsSectionHeight' Sources/ContentView.swift` rather than by those old names.

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

The flat-row agent-status dedup filter adds one more `cmuxTests/` file under the same reserved
prefix: file reference `50BE0001…00F7` and build file `50BE0001…00F8` for
`SupermuxSidebarAgentStatusRowsTests.swift` (listed in the cmuxTests group's `children` and the
`cmuxTests` target's Sources phase, mirroring the `SupermuxSidebarBranchTests.swift` rows above).

The hidden-row-aware Move Up/Down stepping (touchpoint #131) adds one more `Sources/Supermux/`
file under the same reserved prefix: file reference `50BE0001…00FB` and build file
`50BE0001…00FC` for `SupermuxWorkspaceReorderStepping.swift` (listed in the `Supermux` group's
`children` and the `cmux` target's Sources phase, mirroring the rows above).

The usage-tracker button (touchpoint #146) adds one more `Sources/Supermux/` file under the
same reserved prefix: file reference `50BE0001…00FD` and build file `50BE0001…00FE` for
`SupermuxUsageMenuButton.swift` (listed in the `Supermux` group's `children` and the `cmux`
target's Sources phase, mirroring the rows above).

The usage-analytics button (touchpoint #148) adds one more file under the same prefix: file
reference `50BE0001…00FF` and build file `50BE0001…0100` for
`SupermuxUsageAnalyticsMenuButton.swift`, wired in the same four places. The `…00FF` suffix
exhausts the two-hex-digit range, so subsequent files continue into the wider zero-padded form
(`…0101`, `…0102`, …).

The panel-agent liveness registry (touchpoint #323) adds one more file under the same prefix:
file reference `50BE0001…0101` and build file `50BE0001…0102` for
`SupermuxPanelAgentEvidence.swift`, wired in the same four places.

The direct phone-push adapter (touchpoint #332) adds file reference `50BE0001…0103` and build file
`50BE0001…0104` for `SupermuxDirectPhonePush.swift`, wired in the same four places. Its package-owned
APNs service is discovered automatically by SwiftPM and needs no pbxproj entry.

The mobile usage handler (touchpoint #341) adds file reference `50BE0002…00E1` and build file
`50BE0002…00E2` for `Sources/Supermux/SupermuxMobileHost+Usage.swift`, wired in the same four
places as its `SupermuxMobileHost+*` siblings under #95 (`50BE0002…` prefix). Its package-owned
payload builder and the phone's stores/screens are SwiftPM files and need no pbxproj entry.

The shared notification row body (touchpoint #380) adds file reference `50BE0001…0110` and build
file `50BE0001…0111` for `SupermuxNotificationRowBody.swift`, wired in the same four places. Its
package-owned line-composition counterpart (#381) is discovered automatically by SwiftPM and needs
no pbxproj entry.


The native Claude harness (touchpoints #407–#410) adds three app-target glue files, six ids in the
same four places: `SupermuxClaudeHarnessMount.swift` (`50BE0001…0112` / `…0113`),
`SupermuxClaudeHarnessRegistry.swift` (`…0114` / `…0115`), and
`SupermuxClaudeHarnessLauncher.swift` (`…0116` / `…0117`). Everything else the harness ships lives
in `Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/` and `Packages/Shared/SupermuxClaudeHarness/`,
which SwiftPM discovers automatically — that is exactly why the UI lives there and not in the app
target.

The zeron chat-pane port (touchpoint #414) adds ONE more package to the app target — the
`SupermuxZeronUI` design system — under the reserved `50BE0003…` prefix, in the same four places a
local package needs:

| ID | Section | Entry |
|----|---------|-------|
| `50BE000300000000000000A1` | XCLocalSwiftPackageReference | `relativePath = Packages/Shared/SupermuxZeronUI` (also listed in the project's `packageReferences`) |
| `50BE000300000000000000A2` | XCSwiftPackageProductDependency | `productName = SupermuxZeronUI` (also listed in the `cmux` target's `packageProductDependencies`) |
| `50BE000300000000000000A3` | PBXBuildFile | `SupermuxZeronUI in Frameworks` (also listed in the `cmux` target's Frameworks phase) |

`SupermuxKit` already depends on the package, so this direct link exists for exactly one reason:
`Sources/Supermux/SupermuxClaudeHarnessMount.swift` constructs the `SupermuxZeronTheme` it passes
to `SupermuxHarnessView` (#414), and an app-target file cannot import a transitive package product.
No source file is added — SwiftPM discovers the package's own sources.

Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `141`, and
`grep -c 50BE0003 cmux.xcodeproj/project.pbxproj` should print `11` (5 for
`Workspace+SupermuxMobileUnread.swift` under #95, 6 for the `…A1`/`…A2`/`…A3` wiring above and its
`packageReferences` / `packageProductDependencies` / Frameworks cross-references).

### 4. `.github/swift-file-length-budget.tsv` — RETIRED (0.65 merge)

Upstream removed the entire Swift file-length budget system (`Remove Swift file length budget`,
upstream #8125): the tsv, `scripts/swift_file_length_budget.py`, and the ci.yml validation step
are all gone. The fork's budget rows and the #121 `budget-fork-caps` per-PR cap widening were
deleted with it. Nothing to re-apply.

**This retirement invalidates every "raise the budget row" / "budget bump is in the #4 table"
instruction that used to appear in the re-apply notes below** (#5, #34–36, #37, #39, #62–67, #95,
#96, #108). Those steps have all been struck; do not go looking for the tsv. The only remaining
CI length/quality gate is `scripts/swift_warning_budget.py` (Swift *warnings*, not file length),
run from `.github/workflows/ci.yml`. Verify with
`git ls-files | grep -i length.budget` — it must print nothing.

### 4b. `Resources/Localizable.xcstrings` — additive supermux keys

All `supermux.*` keys (en + ja) live here because cmux packages resolve `String(localized:)`
against the app bundle. The merge is **additive only** — `scripts/supermux-merge-loc.py`
rewrites only `supermux.*` entries and leaves every other key byte-identical. On an upstream
merge conflict here, union both sides (supermux keys never collide with cmux keys) or simply
re-run the regen pipeline (see "Localization" in SUPERMUX.md). Verify no non-supermux key
changed: `git diff <base> -- Resources/Localizable.xcstrings | grep '^[-+]' | grep -v supermux`.

**One deletion, deliberately** (zeron chat-pane port, #414). Ten harness UI files were removed
(`SupermuxHarnessTheme`, `Tokens`, `Markdown`, `ToolCard`, `TodoCard`, `DiffCard`, `HeaderBar`,
`ProseRow`, `ThinkingRow`, `ResultRow`), and 26 `supermux.harness.*` keys lost their only callers
with them — the whole `supermux.harness.state.*` family (the deleted header's status label), the
todo-ring and burst strings, the old composer button labels, the pre-port `empty.*` copy, and the
diff/cost strings the shared renderer now owns. All 26 are gone from the catalog. The port's own
new strings live in the **package** catalog
(`Packages/Shared/SupermuxZeronUI/Sources/SupermuxZeronUI/Resources/Localizable.xcstrings`, 73
keys, en + ja, resolved with an explicit `bundle: .supermuxZeronUI`), NOT here: a shared SwiftPM
package resolves `String(localized:)` against `Bundle.module`, so an app-catalog key would fall
back to its English `defaultValue` for every Japanese user. To re-apply, drop the same 26 keys; a
regen pipeline that re-adds them is over-generating from stale sources.

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

iOS now renders from these same `.icon` bundles — see #238–243 below (this note previously said
iOS was intentionally left on its own PNG appiconsets, which is no longer true). A fourth sibling,
`AppIcon-Demo.icon`, exists for the iOS TestFlight demo lane only; macOS does not use it.

### 238–243. iOS name and icon rebrand — `ios-supermux-brand` + unfenced assets

The iOS app shipped as "cmux" with upstream's blue chevron. The fork ships it as **Supermux**
with the supermux mark. Two independent halves:

**Name (`ios-supermux-brand`, three fenced xcconfig/shell sites).** `CFBundleDisplayName` is
`$(PRODUCT_DISPLAY_NAME)` in `ios/Config/Info.plist` (upstream, unfenced), so only that variable
had to move:
- `ios/Config/Shared.xcconfig` (#238) → `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (Debug and any
  build not overriding it). `SUPERMUX_IOS_DISPLAY_SUFFIX` is a fork-invented variable, empty by
  default; dogfood Release builds pass `SUPERMUX_IOS_DISPLAY_SUFFIX=" <tag>"` (leading space) on
  the xcodebuild command line so parallel phone installs read "Supermux <tag>" on the home screen.
  This is deliberately NOT `PRODUCT_DISPLAY_NAME` on the command line (see #244's never-pass rule);
  custom variables are inert in SwiftPM targets, so the override is workspace-safe.
- `ios/Config/Release.xcconfig` (#239) → `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (was `cmux BETA`).
  Release re-declares the whole template because it previously re-declared the name; keep both
  sites in sync when editing.
- `ios/scripts/reload.sh` (#240) → `DISPLAY_NAME="Supermux DEV $TAG"`.

**Do not touch `PRODUCT_NAME`.** It stays `cmux` because it names the built product; `cmux.app`
is hard-coded in `ios/scripts/reload.sh`, `scripts/iphone-install-queue.sh`,
`.github/workflows/reload-build.yml`, and the CI iOS test jobs. Renaming it breaks install and
queue paths for zero user-visible gain.

The TestFlight/App Store lanes are deliberately NOT rebranded: `ios/scripts/upload-testflight.sh`
and `ios/scripts/resolve_testflight_distribution.py` pass `PRODUCT_DISPLAY_NAME` on the xcodebuild
command line, which beats the xcconfig, and `tests/test_ios_testflight_pro_distribution.py`
asserts `cmux BETA` / `cmux DEMO` / `cmux INTERNAL`. Rebranding those means editing the helper
and its test together.

**Icon (#241, unfenced pbxproj wiring).** iOS renders from the SAME root Icon Composer bundle as
macOS. There is no PNG icon art anywhere in the fork: upstream's
`ios/cmux/Assets.xcassets/AppIcon.appiconset` and `AppIcon-Demo.appiconset` are **deleted**, and
`ios/cmux-ios.xcodeproj/project.pbxproj` gains file references to the root `AppIcon.icon` and
`AppIcon-Demo.icon` (ids `IC100001`/`IC100002`, build files `IC100011`/`IC100012`) with

```
lastKnownFileType = folder.iconcomposer.icon;
name = AppIcon.icon; path = ../AppIcon.icon; sourceTree = SOURCE_ROOT;
```

and membership in the app target's `PBXResourcesBuildPhase` — same three-part recipe as the macOS
wiring (#3/#17); without the Resources membership actool ignores the bundle.
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` was already correct and is unchanged. A same-named
`.appiconset` must NOT be re-introduced: actool errors on the duplicate, which is the other reason
the appiconsets are gone rather than merely unused.

`AppIcon.icon`'s existing `scale: 1.85` transform needs **no iOS-specific tuning** — verified by
compiling it with `xcrun actool AppIcon.icon --compile <dir> --app-icon AppIcon --platform
iphoneos`: the mark occupies 82% of the rendered canvas, matching a hand-cropped PNG, because the
source art is a pre-rendered squircle that the system mask crops cleanly at that scale.

`AppIcon-Demo.icon` is a fork-owned sibling for the TestFlight demo lane: the same
`supermux.jpg` layer with a **second, lower** layer `demo-band.png` (a transparent 1024² PNG whose
bottom 26% is `#FF7A00` with a white "DEMO" label) — reproducing upstream's badge without
flattening it into the art. Regenerate the band with:

```python
from PIL import Image, ImageDraw, ImageFont
band = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
d = ImageDraw.Draw(band)
d.rectangle([0, 758, 1023, 1023], fill=(255, 122, 0, 255))
d.text(..., "DEMO", font=ImageFont.truetype(".../Arial Bold.ttf", 165), fill="white")
```

Verify any icon change by compiling it standalone with `xcrun actool … --platform iphoneos` and
looking at the emitted `AppIcon76x76@2x~ipad.png`; do not trust the source art alone, since the
system mask crops it.

**Logo (#242).** `CmuxLogo.imageset` is the in-app brand lockup (`SignInView.brandHeader`,
`RestoringSessionView`). It keeps its upstream name and path — a base64-PNG-in-SVG at 1024×1024 —
so no Swift call site changes; only the embedded image is replaced, squircle-masked (superellipse
n=5) so it reads as an app mark at 28–30pt. The paired string `mobile.signIn.title`
(`ios/cmux/Resources/Localizable.xcstrings`, en + ja) is `Supermux`; it is the one exception to
that catalog's "never edit non-`supermux.*` keys" rule, taken because the key IS the brand word.

**Demo lane (#243).** `.github/workflows/ios-testflight.yml`'s "Use DEMO-badged app icon" step
copied three PNGs into `AppIcon.appiconset`; it now `rm -rf AppIcon.icon && cp -R
AppIcon-Demo.icon AppIcon.icon`. It still swaps files in the checkout rather than overriding
`ASSETCATALOG_COMPILER_APPICON_NAME`, for upstream's original reason: a command-line build setting
applies to every target in the workspace, and SwiftPM resource-bundle targets would fail actool
with a missing icon set.

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

### 244. `CLAUDE.md` — `ios-dogfood-release-build`

Inserted as a `###` subsection immediately **after** upstream's "## iOS builds open on the iPhone
by default" section and before "## iOS dev auth", so an agent reads the upstream rule and its fork
override together. It exists because upstream's rule is actively wrong here:

- `ios/scripts/reload.sh --tag <tag>` builds **Debug** with `CMUX_DEV_TAG=<tag>`, and a tagged DEV
  iOS build may pair only with the same-tag Mac DEV build. The user cannot sign in to those, so the
  phone gets an app that installs and is then unusable.
- `ios/scripts/reload-cloud.sh`, which the upstream section names first, does not exist in this
  checkout.

The fenced text records the Release invocation used for real phone dogfood (`CMUX_DEV_TAG=` empty,
`CMUX_IOS_AUTH_ENV=production`, personal team `NRGUG8GVV4` plus the #53 entitlements file, distinct
dogfood bundle id so it sits beside the user's main install).

The dogfood lane also passes `SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements`,
pointing the notification service extension at the capability-free file and so stripping the app
group (#384) it carries by default. It must name a FILE: a bare `SETTING=` is dropped by xcodebuild
(the xcconfig default wins), and `'SETTING=""'` resolves to the literal path `ios/""`. The dogfood extension id
(`com.supermux.ios.dogfood.notification-service`) has no registered App ID, so it signs against the
wildcard team profile, which carries no App Groups capability; leaving the entitlement in fails the
build outright. The cost is that dogfood push banners show the generated avatar chip rather than the
real project logo — the fixed-identity lane (#372), which owns registered App IDs and profiles, is
where that path is verified.

Since #374 the identity and entitlements overrides go through the app-scoped variables
`SUPERMUX_APP_BUNDLE_ID` and `SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS`, **not** `PRODUCT_BUNDLE_IDENTIFIER`
/ `CODE_SIGN_ENTITLEMENTS` directly. A command-line build setting applies to every target in the
workspace, so passing the raw settings stamps the app's id onto the embedded notification service
extension — and iOS silently refuses to load an extension whose bundle id is not a child of its
container, which would kill the push avatar with no error anywhere. The app-scoped variables leave
the extension deriving `<app id>.notification-service` and carrying no entitlements file.

Two hard "never pass this" rules are part of the fence, both learned from real failures:

- **`PRODUCT_DISPLAY_NAME`** — a command-line build setting beats the xcconfig, so an agent that
  passes one ships the app under an invented name. A build actually went to the user's phone named
  "cmux Mobile Fix" and was reported as a bug against the repo; the name belongs to
  `ios/Config/*.xcconfig` (#238/#239), which already says Supermux.
- **`ASSETCATALOG_COMPILER_APPICON_NAME`** — command-line build settings apply to every target in
  the workspace, so SwiftPM resource-bundle targets fail actool with a missing icon set. This is
  the same reason `.github/workflows/ios-testflight.yml` swaps icon files instead (#243).

Also records that the simulator leg must target a concrete simulator: `generic/platform=iOS
Simulator` fails to link because GhosttyKit ships no x86_64 simulator slice.

If an upstream merge rewrites the iOS build section, re-apply this fence beneath it rather than
merging the two — the upstream instructions stay accurate for upstream and should not be edited.

### 18. `Packages/macOS/CmuxSettingsUI/.../Sections/AutomationSection.swift` — `ai-settings`

The settings section stack (`SettingsWindowScene.sectionStack`) is a closed,
hard-coded list inside the upstream `CmuxSettingsUI` package with no app-side
injection seam, and that package cannot import `SupermuxKit` (a reverse
dependency). So the AI settings UI is a **new, self-contained file** in the same
package —
`Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift`
(registered in its own right as #143)
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

### 20. `Sources/Workspace+TerminalLinkOpening.swift` — `browser-link-new-tab`

**Moved at the 0.65 merge.** Upstream deleted
`GhosttyTerminalView.openEmbeddedBrowserLink(url:sourceWorkspaceId:sourcePanelId:host:)`
and replaced it with the `TerminalLinkOpenContainer` protocol
(`Sources/TerminalLinkOpenContainer.swift`, driven by `Sources/TerminalLinkOpenCoordinator.swift`).
`Workspace`'s conformance lives in this file and its
`openTerminalBrowserLink(url:sourcePanelId:)` is the fork's new home for the fence. Because the
code is now inside `extension Workspace`, the calls are **unqualified** (no `workspace.` prefix),
the panel id comes from `target.containerPanelID` (resolved once via `surfaceOwnershipTarget`),
and upstream uses early `return`s instead of the old `openedInBrowser = …` assignment form.

Upstream reuses an existing right-side browser pane when one exists, and otherwise creates a new
horizontal **split** (`newBrowserSplit`). The fence replaces only that split fallback so the link
instead opens as a **new browser tab in the current pane and switches to it**
(`newBrowserSurface(inPane:url:focus:true)`), keeping the split only when the source pane can't be
resolved. The reuse-an-existing-browser-pane branch is left untouched.

Current implementation (working tree):

```swift
func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
    guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
    if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
        return newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
    }
    // SUPERMUX:begin browser-link-new-tab
    // Open the link as a new browser tab in the current pane and switch to it,
    // instead of creating a split (upstream's fallback was newBrowserSplit). Only
    // fall back to a split if the source pane can't be resolved.
    if let sourcePane = paneId(forPanelId: target.containerPanelID) {
        return newBrowserSurface(inPane: sourcePane, url: url, focus: true) != nil
    }
    // SUPERMUX:end browser-link-new-tab
    return newBrowserSplit(
        from: target.containerPanelID,
        orientation: .horizontal,
        url: url
    ) != nil
}
```

**Scope widened by the protocol extraction.** `openTerminalBrowserLink` is now also the sink for
`Sources/TerminalHTMLFileBrowserAction.swift`, which routes Command-clicked local `.html`/`.htm`
files into the embedded browser. So the fork's new-tab placement now governs **local HTML opens
too**, not only web links — a behavior widening the fork inherited for free, and one to keep in
mind if the placement is ever revisited.

If upstream restructures `TerminalLinkOpenContainer.openTerminalBrowserLink`, the requirement is:
in `Workspace`'s conformance, when no existing right-side browser pane is reused, open the link
via `newBrowserSurface(inPane:url:focus:true)` on the source link's pane
(`paneId(forPanelId:)` against whatever panel id the conformance resolves) rather than
`newBrowserSplit(...)`.

**Known deviation — dock terminals.** Upstream added a SECOND conformance,
`Sources/DockSplitStore+TerminalLinkOpening.swift`, for terminals hosted in the Dock. It is
**deliberately NOT fenced**: it keeps upstream's `newSplit(kind: .browser, …)` fallback, so a
Command-clicked link from a dock terminal still opens as a split, not a new tab. A future merge
must not read the missing fence there as a clobbered touchpoint. Revisit only if the fork decides
dock terminals should share the workspace placement (see SUPERMUX.md "Known limitations").

Fence size in the working tree: **8 lines** in
`Sources/Workspace+TerminalLinkOpening.swift` (a 60-line file). `Sources/GhosttyTerminalView.swift`
now carries only touchpoint #34 (`ghostty-unbind-split-zoom-return`, **21 lines**). The
`.github/swift-file-length-budget.tsv` rows these numbers used to feed are gone — upstream removed
the whole budget system (see #4, RETIRED) — so the counts are recorded for merge review only.

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

**26. `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` —
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
handle as the ZStack background. (The former budget-row bump for this file is retired — see #4.)

**27. `cmuxTests/SidebarWidthPolicyTests.swift` — `right-sidebar-min-width-test`.** Two clamp
assertions that previously hardcoded `276` now read `CGFloat(RightSidebarWidthSettings.minimumWidth)`
so they track the floor regardless of its value.

### 28–33 (+33b). Toggle Pane Zoom rebind (`toggle-split-zoom-rebind`)

supermux's Changes panel binds **⇧⌘↩** to its Commit accelerator (typed-message commit or AI
"Generate & Commit", whichever applies — see `SupermuxChangesPanelView.commitArea` /
`commitShiftReturnAccelerator`, a supermux-owned file with no fence). But ⇧⌘↩ was the cmux default
for **Toggle Pane Zoom** (`toggleSplitZoom`), and the app-local NSEvent monitor in `AppDelegate`
consumes that chord before any SwiftUI button shortcut can fire. So the commit accelerator only
works once Toggle Pane Zoom is moved off ⇧⌘↩. All seven edits share the fence id
`toggle-split-zoom-rebind`; the new default is **⌃⌘Z** ("Z" for Zoom, a free letter in the ⌃⌘
range, and deliberately *not* ⌃⌘↩ which some screen recorders use — see the rationale comment in
#32).

> **⌃⌘Z re-verified collision-free at the 0.65 merge.** The old justification here ("pairs with
> ⌃⌘= equalize") is stale: upstream moved `equalizeSplits` to **⌃⇧⌘=** and gave **⌃⌘=** to a new
> `increaseWorkspaceTerminalFontSize` (with ⌃⌘- / ⌃⌘0 siblings). The mnemonic pairing is gone, but
> the binding itself still holds — `key: "z"` with `command + control` appears exactly once in each
> default table (`toggleSplitZoom`) across upstream's expanded action set. Re-check with
> `grep -n 'key: "z"' Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift
> Sources/KeyboardShortcutSettings.swift` after every merge; two hits means upstream landed on the
> fork's chord and one of the two must move.

- **28. `Sources/KeyboardShortcutSettings.swift`** (canonical `defaultStroke` table) and
  **29. `Packages/macOS/CmuxSettings/.../ShortcutAction+Defaults.swift`** (the settings-UI package
  mirror; upstream relocated this package under `Packages/macOS/`):
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

  ⚠️ **Framework change at the 0.65 merge — read before re-applying.** This file is no longer
  XCTest. It is now Swift Testing: `@Suite(.serialized) @MainActor final class
  AppDelegateEqualizeSplitsShortcutTests` with **no `: XCTestCase`** and **no `import XCTest`**,
  and the familiar `XCTAssertEqual` / `XCTAssertTrue` / … calls inside it are *file-private shims*
  declared at the top of the file that forward to `#expect`. Consequences: (a) both fenced tests
  here (`testCmdControlZFocusedBrowserTogglesSplitZoom` in #31 and
  `testSupermuxCommitDefaultsBindReturnChords` in #38) **MUST carry the `@Test` attribute**; a
  merge that drops it leaves a compiling, never-executed method — the fork's coverage silently
  disappears and **CI stays green**, exactly the failure class as the missing-pbxproj-test-wiring
  pitfall in `CLAUDE.md`. (b) The `test` name prefix no longer registers anything by itself. After
  any merge touching this file, verify with
  `grep -c '@Test' cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` and confirm an `@Test`
  line sits immediately above each fenced `func`.
- **32. `cmuxTests/KeyboardShortcutContextTests.swift`:** comment-only — the rationale for
  `toggleBrowserFocusMode`'s ⌥⌘↩ default no longer calls Toggle Pane Zoom "the other Return-based
  shortcut". Assertions are unchanged (⌥⌘↩ still differs from and does not conflict with ⌃⌘Z).
- **33. `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift`:** the two browser zoom round-trip
  tests (`testCmdControlZKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused`,
  `testCmdControlZHidesBrowserPortalWhenTerminalPaneZooms`) press `app.typeKey("z", [.command, .control])`
  instead of ⇧⌘↩, with matching renamed methods and assertion messages. Note the file now builds
  its app with upstream's `XCUIApplication.cmuxTestApplication()` helper rather than bare
  `XCUIApplication()`; re-apply the keystroke change only, and keep whatever launcher upstream
  ships.
- **33b. `cmuxTests/AppDelegateSurfaceShortcutRoutingTests.swift`:** a site the registry never
  listed before the 0.65 merge (the seventh in this numbered sequence; `git grep -l
  'toggle-split-zoom-rebind'` reports nine files once #35/#36 are counted). Upstream's canvas-mode test
  `cmdShiftReturnInCanvasModeDoesNotToggleBonsplitSplitZoom` asserts that in canvas mode the
  split-zoom shortcut drives canvas overview instead of Bonsplit zoom. It wraps the body in
  `withTemporaryShortcut(action: .toggleSplitZoom)`, which installs the action's **configured
  default** — the fork's ⌃⌘Z — so the synthesized event must match or the test fails. The whole
  method is fenced and renamed `cmdControlZInCanvasModeDoesNotToggleBonsplitSplitZoom`, building
  `key: "z", modifiers: [.command, .control], keyCode: 6`. Swift Testing (`@Test`), same
  silent-skip hazard as #31.

If upstream changes the `toggleSplitZoom` default or these tests, keep our ⌃⌘Z value inside the
fence. If upstream adds a different action on ⌃⌘Z, pick another free, non-`⌃⌘↩` chord for zoom and
update all seven sites. Find every site with:
`git grep -ln 'toggle-split-zoom-rebind'`.

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

(The former budget-row bumps for #34/#35/#36 are retired — see #4.)

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
  ⌘↩ / ⇧⌘↩ and do not cross-match. Since the 0.65 merge this file is **Swift Testing**, so the
  fenced method must carry `@Test` — see the framework-change warning under #31; without the
  attribute the test compiles, never runs, and CI stays green.

The wiring lives in supermux-owned files (no fence): `SupermuxChangesMount`
(`Sources/Supermux/SupermuxAppGlue.swift`) resolves each configured shortcut to a SwiftUI
`KeyboardShortcut` and passes it (plus the primary's display string for the button help)
into `SupermuxChangesPanelView`, which applies them to the visible Commit button and the
invisible accelerator. If upstream adds an action on ⌘↩ or ⇧⌘↩, rebind these or accept the
conflict warning. The Settings UI's action list and conflict detection are driven by the
settings-package enum, so the actions are also registered there (#62/#62b/#62c/#63) — without
that registration the "editable in Settings" claim does not hold. (The former budget-row bump for
#37 is retired — see #4.)

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
local-provider only. The pbxproj additions for the two new app files are in the #3 note. (The
former budget-row bump for this file is retired — see #4.)

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
2. The last-workspace close sites that called `window.performClose(nil)` now call
   `closeWorkspace(workspace, allowEmptyingWindow: true)`. **This was three sites; since the 0.65
   merge it is TWO** — `closeWorkspaceIfRunningProcess` and `closePanelAfterChildExited`. (Tree-wide
   there are FOUR `allowEmptyingWindow: true` call sites in `Sources/TabManager.swift`; the other
   two are the fork-added `restoreClosedWorkspace` failure-cleanup calls covered by item 4 below,
   not replacements of an upstream `performClose`.) Upstream
   deleted the bulk-close **anchor branch** entirely: closing a group's anchor is no longer
   destructive (the group's next member is promoted via
   `WorkspacesModel.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId:)`), so there is no
   anchor prompt and no anchor-specific close path left. Verify with
   `git grep -c confirmAnchorWorkspaceClose` — it must be **0** tree-wide. The fork contract still
   holds for bulk closes because the surviving loop (`anchorLastCloseOrder(plan.workspaces)` →
   `closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)`) routes through the
   fenced site, i.e. through `closeWorkspace(allowEmptyingWindow: true)`.
3. The bulk-close top short-circuit (`plan.workspaces.count == tabs.count` → close window) is
   omitted so the loop empties the window instead; **`closeWorkspacesPlan`'s** `willCloseWindow`
   is forced `false` so the confirmation copy reads "Close workspaces?" not "Close window?", and
   the plan passes `acceptCmdD: false` because closing the final workspace is no longer a
   window-closing action.

   ⚠️ **Scope note — do not "fix" the other one.** There is a *separate*
   `let willCloseWindow = tabs.count <= 1` inside `closeWorkspaceIfRunningProcess` (feeding that
   function's own `acceptCmdD:`). It is **byte-identical in base, ours, and theirs** — the fork has
   never touched it and it is deliberately left upstream-shaped. A future merger scanning for
   "`willCloseWindow` must be false on the fork" must not extend the rule there. Confirm with
   `for s in 1 2 3; do git show :$s:Sources/TabManager.swift | grep -n 'let willCloseWindow = tabs.count <= 1'; done`
   during a merge.
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

**52. RETIRED (v0.64.19 merge).** The `force-production-auth` fence is gone from
`MobileAuthComposition.swift` — upstream 0.64.x added a first-class LocalConfig override
(`MobileAuthComposition.authEnvironmentOverrideKey = "AuthEnvironment"`, values
`production`/`development`, resolved by `resolvedAuthEnvironment(isDevelopmentBuild:overrides:)`)
that does exactly what the fence did, so the file is back to byte-identical upstream. The fork
behavior now rides entirely on #55: `LocalConfig.plist` sets `AuthEnvironment=production`. If
upstream ever removes that override mechanism, re-introduce a fence with the old requirement:
when the bundled `LocalConfig.plist` opts into production, resolve the auth config for
`.production` even in a DEBUG build.

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
`AuthEnvironment=production` (upstream's `authEnvironmentOverrideKey`; was `STACK_ENVIRONMENT`
before the v0.64.19 merge retired #52), read by upstream's LocalConfig override table and bundled
via #54. Contains no secret (the
production Stack project id + publishable key are already in
`Packages/Shared/CMUXAuthCore/.../CMUXAuthConfig.swift` / `CmuxAuthRuntime/.../AuthConfig.swift`).
Because a Copy-Bundle-Resources entry points at it, a fresh clone/CI must have the file present or
the iOS build fails with "Build input file cannot be found" — which is why it is committed rather
than gitignored.

**Rebuilding the phone app** (personal team cert lasts ~1 year; rerun to renew):

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /opt/homebrew/bin/bash \
  ios/scripts/reload.sh --tag <your-tag> --device-only --team <TEAM_ID> \
  --allow-device-registration --no-setup
```

Needs Homebrew bash 5 (`ios/scripts/reload.sh` trips a bash 3.2 empty-array bug under `set -u`) and
the Xcode 27 beta toolchain (stable Xcode couldn't see the device). iPhone connected via USB +
trusted. The Mac side must have `mobile.iOSPairingHost.enabled` on; the phone reaches it over
the local network or a VPN such as Tailscale.

### 56. `Sources/Workspace+AgentLifecycle.swift` — `workspace-agent-lifecycle-observation`

In `Sources/Workspace+AgentLifecycle.swift` (upstream 0.64.x extracted the agent-lifecycle code
out of `Workspace.swift` into this extension file; the fence moved with it), inside
`private func recordAgentLifecycleChange(panelId: UUID)`, insert as the first statement:

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
- **60. `Sources/RemoteTmuxController.swift`** — upstream 0.65 split the teardown into a
  `reason` switch; both arms are fenced. `.sessionEnded` (dead mirror): resolve the owning
  manager and call `closeWorkspace(workspace, allowEmptyingWindow: true)`; upstream's
  add-a-replacement-workspace-first workaround is deleted inside the fence. `.explicitDetach`
  (deliberate detach): replace upstream's
  `closeWorkspaceNonInteractively(workspace, allowPinned: true)` with the same
  `closeWorkspace(workspace, allowEmptyingWindow: true)` — the non-interactive variant closes
  the whole window when the mirror is the window's last workspace, which quits the app on the
  last window; `closeWorkspace` has no pin veto, so the pinned-final-mirror case still closes.
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

### 62 / 62b / 62c–67. Settings-package shortcut registration + secret 0600 write

Registering the supermux actions in the settings-package enum is what surfaces them in the
Settings UI and its conflict detection — the app-target registration in #11/#23/#37 alone does
not. Upstream (0.65) split that enum's computed properties into per-property files, so what used
to be five fences in one file is now **three files**:

- **62. `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift`** — three
  fences add the five cases, reusing the app-target ids: `run-toggle-shortcut-case`
  (`supermuxToggleRun`), `workspace-switcher-shortcut-case`
  (`supermuxWorkspaceSwitcherNext`/`Previous`), `supermux-commit-shortcut-case`
  (`supermuxCommit`/`supermuxCommitAccelerator`). Re-apply: add each case inside its own fence,
  anywhere in the enum's case list — Codable/raw-value stability comes from the case names, not
  their order.
- **62b. `…/Values/ShortcutAction+Group.swift`** — `supermux-shortcut-groups`: two `case` arms in
  the `group` switch, `supermuxToggleRun, supermuxCommit, supermuxCommitAccelerator → .workspace`
  and `supermuxWorkspaceSwitcherNext, supermuxWorkspaceSwitcherPrevious → .navigation`. Re-apply:
  the `group` switch is exhaustive, so the compiler names every missing case — add the two fenced
  arms anywhere before the `default`/final arm. Without this file's fence the package does not
  compile, so a merge cannot silently lose it.
- **62c. `…/Values/ShortcutAction+DisplayName.swift`** — `supermux-shortcut-display-names`: five
  `String(localized: "supermux.shortcut.<name>.label", defaultValue: …)` arms in the `displayName`
  switch, using the SAME keys as the app-target labels (#11/#23/#37). The package resolves
  `String(localized:)` against `Bundle.main`, so the app catalog (#4b, en + ja) serves both.
  Re-apply: same exhaustive-switch mechanics as 62b; never invent new keys here — a duplicate key
  set would drift from the app-target labels.
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
guards their existence. (The former budget-row bookkeeping for these package files is retired —
see #4.)

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

**Two fence sites since the 0.65 merge.** Upstream rewrote `addWorkspace` to resolve the cwd
through a policy value type and stopped routing it through
`implicitWorkingDirectoryForNewWorkspace`, so the fork needed a second pin.

**(a) `addWorkspace` — the live path.** Upstream now computes:

```swift
let workingDirectory = WorkspaceCreationWorkingDirectoryPolicy(
    inheritanceEnabled: inheritanceEnabled
).resolve(
    explicitWorkingDirectory: explicitWorkingDirectory,
    inheritedWorkingDirectory: snapshot.preferredWorkingDirectory,
    // SUPERMUX:begin new-workspace-home-dir
    // Fork contract: with `app.workspaceInheritWorkingDirectory` OFF, a new
    // workspace always starts in the home directory. Upstream's policy falls
    // back to the Ghostty working-directory default here instead
    // (upstream: `defaultWorkingDirectory: defaultWorkspaceWorkingDirectoryProvider()`),
    // which is exactly what the fork overrides. Keyed on the SETTING alone, not
    // on `inheritanceEnabled`: an explicit `inheritWorkingDirectory: false` call
    // with the setting ON still takes upstream's default (upstream's
    // `testExplicitNoInheritanceUsesGhosttyDefaultWhenGlobalInheritanceEnabled`).
    // Mirrors `implicitWorkingDirectoryForNewWorkspace`, which upstream's
    // addWorkspace rewrite stopped calling (it now serves the detached path only).
    defaultWorkingDirectory: settings.value(
        for: settingsCatalog.app.workspaceInheritWorkingDirectory
    ) ? defaultWorkspaceWorkingDirectoryProvider()
      : FileManager.default.homeDirectoryForCurrentUser.path
    // SUPERMUX:end new-workspace-home-dir
)
```

**Critical invariant:** the ternary reads
`settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory)` directly. It must
**never** be rewritten to test `inheritanceEnabled`, which is
`inheritWorkingDirectory && settings.value(…)`. A caller passing
`inheritWorkingDirectory: false` while the global setting is ON is asking for upstream's Ghostty
default, not the home pin — upstream's
`testExplicitNoInheritanceUsesGhosttyDefaultWhenGlobalInheritanceEnabled` asserts exactly that and
goes red if the condition is collapsed.

**(b) `implicitWorkingDirectoryForNewWorkspace(from:)` — the detached path.** The `guard` on the
setting used to `return nil`; the fence returns the home directory explicitly:

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

Its **only** remaining caller is `addWorkspace(fromDetachedSurface:)`
(`Sources/TabManager+DetachedWorkspace.swift`), as the fallback behind `detached.directory`. With
the setting off, a detach-drop without a transfer directory gets the explicit home pin instead of
nil. That is observationally identical today — `Workspace.init` already displayed home as
`currentDirectory` when `workingDirectory` was nil — which is why upstream's unfenced tests
`testDisabledInheritanceLeavesDetachedWorkspaceFallbackCwdUnset…` and
`testDetachedWorkspaceTransferDirectoryWinsWhenInheritanceIsDisabled`
(`cmuxTests/WorkspaceUnitTests.swift`) keep passing unmodified; if an upstream merge changes those
tests or the nil-cwd display fallback, re-check this path.

Why the fork does this at all: every plain new-workspace entrypoint (sidebar empty-area
double-click, sidebar `+`, ⌘N, palette) funnels into `addWorkspace`, which passes the resolved
value down to the initial `TerminalPanel` → `ghostty_surface_new`. Historically a nil cwd let
`apprt.surface.newConfig` in the ghostty submodule copy the previously focused surface's pwd into
the new surface's config (`tab-inherit-working-directory` defaults to true), so the cmux-level
setting appeared to do nothing. Regression coverage:
`cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` (pbxproj IDs `50BE0001…00D1`/`…00D2`,
see #3) — note it exercises `implicitWorkingDirectoryForNewWorkspace` (site b), so **it does not
cover site (a)**; site (a) is covered by the fenced #81 test.

The behavior change ripples into these sibling surfaces (fenced ones share the
`new-workspace-home-dir` id):

- **`cmuxTests/WorkspaceUnitTests.swift` (#81):** at the 0.65 merge upstream **renamed** this test
  to `testDisabledInheritanceUsesGhosttyDefaultForNewWorkspaceCwd` (it was
  `testDisabledInheritanceLeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback`) and changed what it
  asserts: instead of `requestedWorkingDirectory == nil`, it now injects a
  `defaultWorkspaceWorkingDirectoryProvider: { fallbackCwd }` into `TabManager` and asserts both
  `requestedWorkingDirectory` and `currentDirectory` equal `fallbackCwd`. Either form contradicts
  the fork's "off = always home" contract, so the test stays fenced, renamed
  `testDisabledInheritancePinsNewWorkspaceCwdToHomeDirectory`: it keeps upstream's injected
  `fallbackCwd` provider (so the assertion proves the fork's pin BEATS the provider, not merely
  that the provider is absent) and asserts
  `requestedWorkingDirectory == FileManager.default.homeDirectoryForCurrentUser.path` plus
  `currentDirectory != sourceCwd`. This is the ONLY coverage of fence site (a) in `addWorkspace`.
  The plain-path sibling tests (inherit-on, explicit per-call `inheritWorkingDirectory: false`,
  explicit-override) are untouched — in particular
  `testExplicitNoInheritanceUsesGhosttyDefaultWhenGlobalInheritanceEnabled` must keep passing,
  which is what pins the "key off the SETTING alone" invariant above. The two detached-path
  disabled-inheritance tests are also untouched but their mechanism changed (see the site-(b) note
  above).
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

#### OPEN DECISION for the fork owner — upstream has closed the leak on its own terms

The old standing note here said: *"if upstream ever fixes the inheritance leak itself, drop all
`new-workspace-home-dir` fences and take upstream's fix."* **Upstream has now done so** — but not
in a way that matches the fork's stated contract, so this is a decision, not an automatic
retirement. It is recorded here unresolved; the fork currently **keeps its own semantics**.

What upstream shipped (0.65): `WorkspaceCreationWorkingDirectoryPolicy.resolve(…)`
(`Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Values/`) returns a **non-optional
`String`** — the last line is `normalized(defaultWorkingDirectory()) ?? "/"`. There is therefore no
longer any nil-cwd path into `ghostty_surface_new`, and Ghostty's `tab-inherit-working-directory`
can no longer silently re-inherit the focused surface's pwd. The original bug is gone from
upstream.

Where the two contracts differ: upstream's default is
`defaultWorkspaceWorkingDirectoryProvider()`, i.e. the user's **Ghostty `working-directory`
config** value. The fork's product contract is **"off = always home"** (that exact wording is now
shipped in the Settings subtitle, the localized catalog, the JSON schema description, and the
generated settings docs). A user who sets `working-directory = /Users/x/code` in their Ghostty
config would get `/Users/x/code` under upstream and `~` under the fork.

If the fork owner decides to retire #80 and take upstream's behavior, **all of these change
together** — do not retire them piecemeal, or the shipped copy will contradict the code:

- **#80 `Sources/TabManager.swift`** — both `new-workspace-home-dir` fence sites (the
  `addWorkspace` policy default and `implicitWorkingDirectoryForNewWorkspace`).
- **#81 `cmuxTests/WorkspaceUnitTests.swift`** — un-fence and restore upstream's
  `testDisabledInheritanceUsesGhosttyDefaultForNewWorkspaceCwd`.
- **`cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift`** (fork-owned) — delete the file,
  plus its four `50BE0001…00D1`/`…00D2` pbxproj entries (#3).
- **`Sources/TabManager+DetachedWorkspace.swift`** — no edit, but its behavior changes (the
  detached fallback stops being home-pinned); re-check the two upstream detached-inheritance
  tests.
- **#82 `Packages/macOS/CmuxSettingsUI/.../Sections/AppSection.swift`** — the OFF subtitle reverts
  to upstream's Ghostty-fallback wording.
- **#83 `cmuxUITests/SettingsAppBehaviorUITests.swift`** — `Subtitle.inheritOff` reverts to match
  #82.
- **#84 `Sources/SettingsSearchAliases.swift`** and **#85 `Sources/SettingsNavigation.swift`** —
  the `home` search keyword reverts to `ghostty`.
- **#4b `Resources/Localizable.xcstrings`** — the en+ja values of
  `settings.app.workspaceInheritWorkingDirectory.subtitleOff` and of
  `settings.search.alias.setting.app.workspace-inherit-working-directory` revert. These are the
  ONLY non-`supermux.*` keys the fork touches, so retiring #80 would make #4b purely additive
  again.
- **#14 `web/data/cmux.schema.json`** — the reworded `workspaceInheritWorkingDirectory`
  description AND its `descriptionKey` revert.
- **#86 `web/messages/en.json`** and **#87 `web/messages/ja.json`** —
  `schemaDescriptions.app.workspaceInheritWorkingDirectory` is deleted from both.
- **#88 `skills/cmux-settings/references/all-keys.md`** — regenerate from the reverted schema.

Middle options worth considering before deciding: (i) keep the fork pin but honor a **non-empty**
Ghostty `working-directory` first, falling back to home only when the user configured none —
smaller behavioral surprise, keeps most of the fork's intent, but makes the shipped "always"
wording false and needs all the copy above reworded anyway; (ii) retire #80 and instead ship a
supermux-owned Settings row that sets the user's Ghostty `working-directory` to home — zero
upstream touchpoints, at the cost of mutating the user's Ghostty config.

Do not resolve this from a merge; it is a product call. Until it is resolved, keep every fence and
every piece of copy in the table above in sync with each other.

## iOS / mobile sync

### 89. `ios/cmuxUITests/cmuxUITests.swift` — `uitest-ticket-compat-version` — RETIRED (0.65 merge)

Upstream adopted the fix: the mock-host attach-ticket fixture in `attachURL(port:)` now carries
`macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion` in upstream code,
so the fork's fence was dropped in favor of the identical upstream line. Nothing to re-apply.

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
`SupermuxMobileHost+PhonePush.swift`, `SupermuxMobileAuthorization.swift`, `SupermuxMobileCapabilities.swift`,
`SupermuxMobileObservers.swift`, and `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/`); four
1–3-line fences hook it into upstream:

- **`Sources/TerminalController.swift` (#91, `mobile-supermux-dispatch`):** one
  `case let method where method.hasPrefix("mobile.supermux."):` in the `mobileHostHandleRPC`
  switch. It now sits right after upstream's `mobile.browser.` prefix case (upstream inserted that
  case between `mobile.chat.` and the fork's, which is why the old "right after `mobile.chat.`"
  wording is stale). Re-apply: keep it anywhere in that switch before `default:` — the prefixes are
  disjoint, so ordering among them does not matter; the router body is fork-owned.
- **`Sources/Mobile/MobileHostService+TicketAuthorization.swift` (#92, `mobile-supermux-authz`):**
  (upstream 0.64.x extracted ticket authorization out of `MobileHostService.swift` into this file;
  the table row has said so for a while but this bullet had not caught up) a 3-line guard in
  `ticketAuthorizationError(authorization:request:)` — AFTER the workspace/terminal alias and
  conflict guards (they must keep applying to supermux methods) and BEFORE upstream's method
  switch — returning `SupermuxMobileAuthorization.ticketError(method:params:ticket:)` for the
  whole prefix. The fork table fails closed (`default:` = scoped-ticket `forbidden`), so a merge
  that drops this fence makes every supermux method hit upstream's own fail-closed `default:` —
  safe, but the phone loses scoped-ticket access; `cmuxTests/SupermuxMobileAuthorizationTests`
  goes red either way. (Upstream removed the `debugTicketAuthorizationError` test seam this note
  used to cite — zero occurrences tree-wide; the tests now call `ticketAuthorizationError`
  directly.)
- **`Sources/Mobile/MobileHostService+Capabilities.swift` (#93, `mobile-supermux-capabilities`):**
  `capabilities += SupermuxMobileCapabilities.advertised` inside
  `mobileHostCapabilities(includingWorkspaceChanges:)` — AFTER upstream's
  `if !includingWorkspaceChanges { capabilities.removeAll { … } }` filter and BEFORE the
  `#if DEBUG` suppression block, so the fork list is not caught by the flag filter but IS
  suppressible via `CMUX_DEBUG_SUPPRESS_MOBILE_CAPS`. Re-apply: any composition that folds the
  fork list into the returned array in that window works; never inline `supermux.*` strings into
  upstream's literal. **The fork list must never contain the literal `workspace.changes.v1`** —
  upstream's `testWorkspaceChangesCapabilityFollowsFeatureFlag` in
  `cmuxTests/MobileHostConnectionLifecycleTests.swift` asserts
  `enabled.filter { $0 != workspaceChangesCapability } == disabled`, so a duplicate entry makes
  that equality fail. (Upstream's own mobile diff viewer now ships behind that capability and
  overlaps the fork's `supermux.changes.v1`; both are advertised at once whenever
  `CmuxFeatureFlags.mobileWorkspaceChangesFlag` is on — see SUPERMUX.md "Known limitations".)
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
- **Budget rows (#4): RETIRED.** The former `.github/swift-file-length-budget.tsv` bumps for
  `TerminalController.swift` (+4), `MobileHostService.swift` (+5), and `AppDelegate.swift` (+3)
  no longer exist — upstream deleted the whole budget system. Nothing to re-apply.

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
  (all observation-tracked) and return `nil` unless `.connected`. (The former
  `.github/swift-file-length-budget.tsv` row bump is retired — see #4.)
- **`WorkspaceListView.swift` (#97, `supermux-mobile-projects-section`, five fences):**
  the import; `@State var supermuxProjects = SupermuxProjectsSectionModel()` — **internal, not
  private**, because `WorkspaceListView+Table.swift` projects it into the #151 payload (since the
  0.64.21 merge it follows upstream's new `@State var workspacePendingCustomizationID`, which is
  where the `@State` block now ends).
  **The `#if os(iOS)` and `#else` arms are NOT interchangeable — read this before re-applying:**
  - `#if os(iOS)` (what the iPhone actually renders): `.supermuxProjectsSectionDriver(...)` goes
    on `workspaceTable`, before `.modifier(WorkspaceListBarUnderlap())`. The ROWS come from the
    #148–#151 chrome row, not from a `SupermuxProjectsMobileSection` mount.
  - `#else` (macOS only): the legacy `SupermuxProjectsMobileSection(...)` mount above the
    workspaces `Section`, plus the driver on the `List`.

  Re-apply: put the driver on whatever view the platform actually renders, and NEVER inside the
  table/list — its `.task(id:)` must live on a stable view, and it also owns the project-detail
  `navigationDestination` and the nested-open error alert. **If an upstream merge ever moves the
  iOS branch again, the driver moves with it.** A driver stranded in an arm the platform does not
  render is exactly the 0.64.20 regression: the section silently never loads, the snapshot stays
  `.hidden`, and every Projects affordance (detail, worktrees, presets, run, actions, editor)
  becomes unreachable while still compiling. `Packages/iOS/CmuxMobileShellUI/Tests/…/SupermuxProjectsTableRowTests.swift`
  guards the row's placement, but nothing compiles-checks the driver's arm — verify on device.
- **#148–#151 (`supermux-mobile-projects-table-row`), the iOS Projects row:** re-apply all four
  files together; they are one feature. Order matters in two places: the
  `case .chrome(.supermuxProjects)` margin branch must precede the general `case .chrome` in
  `configure`, and the `items.append(.chrome(.supermuxProjects))` must land inside the LEADING
  chrome run in `workspaceTableItems`. Both are explained in #148.
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

### 13 (cont.) + 90 (cont.) + 109 (cont.). `Packages/Shared/SupermuxClaudeHarness` registration

`Packages/Shared/SupermuxClaudeHarness` is the supermux-owned zero-dependency Claude Code
stream-json protocol package for the native Claude harness (typed line/event model, lossless
`ClaudeJSONValue`, line classifier, control multiplexer, stream accumulator/reconciler, session
state machine, input queue, launcher/spawn arguments, tool humanizer). The macOS process host
lives in `Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/` (fork-owned, zero pbxproj
cost); `Packages/SupermuxKit/Package.swift` (fork-owned, no fence) gains the
`../Shared/SupermuxClaudeHarness` path dependency. Three upstream files register the package:

- **`.github/workflows/ci.yml` (#13, inside the existing `ci-package-tests` fence):**
  `swift test --package-path Packages/Shared/SupermuxClaudeHarness` appended after the
  SupermuxMobileUI entry (same pattern; restore the fenced block, keep every fork package listed).
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the Shared group. Re-apply with
  `python3 scripts/check-workspace-package-groups.py --write`; never hand-edit.
- **`scripts/lint-ios-package-conventions.sh` (#109, `lint-ios-conventions-fork-scopes`):** the
  package joins the fork SCOPES list; its two deliberate namespace enums
  (`ClaudeLineClassifier`, `ClaudeToolHumanizer`) carry inline `lint:allow` justifications.

The package itself is fork-owned (no fences inside it) and dependency-free, so no
`Package.resolved` is generated. Protocol fixtures under
`Tests/SupermuxClaudeHarnessTests/Fixtures/` are verbatim captures from Claude Code 2.1.227
(claude and ccx), scrubbed of paths/UUIDs/signatures only — never hand-written JSON.

### 13 (cont.) + 90 (cont.) + 109 (cont.). `Packages/Shared/SupermuxZeronUI` registration

`Packages/Shared/SupermuxZeronUI` is the supermux-owned SwiftUI design system for the native
Claude harness chat pane — the 1:1 port of zeron/comet's transcript, tool chips, markdown
pipeline, diff body, composer and pickers. It is shared deliberately: `SupermuxKit` (macOS) and
`SupermuxMobileUI` (iOS) each own only their platform shell, so the palette, geometry and motion
cannot drift between the two apps. Its only dependency is the `../SupermuxClaudeHarness` path
dependency (the frozen row/tool-call data layer); it must never take an app or platform-shell
dependency. Three upstream files register the package, exactly as for SupermuxClaudeHarness:

- **`.github/workflows/ci.yml` (#13, inside the existing `ci-package-tests` fence):**
  `swift test --package-path Packages/Shared/SupermuxZeronUI` appended after the
  SupermuxClaudeHarness entry (same pattern; restore the fenced block, keep every fork package
  listed).
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the Shared group. Re-apply with
  `python3 scripts/check-workspace-package-groups.py --write`; never hand-edit.
- **`scripts/lint-ios-package-conventions.sh` (#109, `lint-ios-conventions-fork-scopes`):** the
  package joins the fork SCOPES list.

The package is fork-owned (no fences inside it) and takes only a path dependency, so no
`Package.resolved` is generated. It vendors third-party assets under
`Sources/SupermuxZeronUI/Resources/`, each with attribution that the repository `NOTICE` and the
in-app Acknowledgements view must both carry: `Fonts/{Geist,GeistMono}.ttf` + `Fonts/OFL.txt`
(SIL OFL 1.1, fetched from `vercel/geist-font` — zeron ships the binaries with no license file,
which is an upstream gap, not a fact to copy), and `Icons.xcassets` + its `ATTRIBUTION.txt`
(Solar Icons by 480 Design, CC BY 4.0). The icons are `.imageset` entries holding the raw SVG
with `preserves-vector-representation` + `template-rendering-intent: template`; each SVG's
`width`/`height` was rewritten from zeron's gpui-idiom `1em` to its own viewBox extent, because
`actool` derives the intrinsic point size from those attributes and would otherwise compile every
glyph to 1x1 pt. Rationale and the `assetutil` verification are documented in
`Sources/SupermuxZeronUI/Icons/SupermuxZeronIconBundle.swift`.

### 99–103. Workspace-list augmentation (§6: `supermux_project_id` / `supermux_activity`)

The Mac merges four ADDITIVE, optional fields into every `workspace.list` workspace payload and the
phone folds project-owned rows under the Projects section, shows agent-activity dots, and lists a
project's open workspaces inside `SupermuxProjectDetailScreen`. Field computation is fork-owned and
package-tested (`SupermuxMobileWorkspaceFields` in `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/`,
RPC-WSL-01 suite `SupermuxMobileWorkspaceFieldsTests`); the app-target adapter
`Sources/Supermux/SupermuxMobileWorkspaceListAugmenter.swift` feeds it the ONE shared activity
resolution (`SupermuxWorkspaceActivityResolver`) and the sidebar's association resolution
(`SupermuxWorkspaceAssociationStore.projectId(forWorkspace:directory:in:)`), so the phone and the
Mac sidebar can never disagree. Activity travels for every workspace; project id, branch, and pull
request remain association-gated. An idle associated workspace carries the project id alone, while
an active global workspace carries activity without a project id. `Sources/Supermux/SupermuxMobileActivityObserver.swift`
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
  decode → preview plumbing for the four additive fields (`supermux_project_id` / `supermux_activity`
  / `supermux_branch` / `supermux_pull_request {number, state, url, is_stale}`). All additions are
  optional/defaulted so upstream inits, tests, and old payloads are untouched; the nested PR object
  decodes lossily (malformed → nil fields, never a list-wide failure); `PROTO-03` regression suite
  `SupermuxWorkspaceListFieldsDecodeTests` (CmuxMobileRPCTests) locks the wire shape both ways.
  Freshness note: unopened-worktree PR badges are poked by `SupermuxMobileWorktreesObserver`
  (fork-owned, hashes `pullRequestsByWorktreePath`), but there is no fork observer for branch/PR-only
  changes on an OPEN `Workspace`, so those values refresh only when some other tracked field trips
  upstream's `Sources/Mobile/MobileWorkspaceListObserver.swift` (activity/title/preview churn) or on
  a list refetch. Pre-existing, but **more visible under state sync v2** (#139–141), where the phone
  no longer refetches at all — see SUPERMUX.md "Known limitations", open decision 6.
  The aggregated multi-Mac path needs no fence: `derivedWorkspaces` mutates copies
  (`var stamped = workspace`), which carries the new fields automatically.
- **`WorkspaceListView.swift` (#103, `supermux-mobile-hide-project-workspaces` +
  `supermux-mobile-row-activity`):** the hide filter must stay gated on
  `supermuxProjects.snapshot.isVisible && trimmedQuery.isEmpty && !filter.isActive` so rows never
  become unreachable while disconnected/upstream-paired and never unsearchable; only LOOSE
  (ungrouped) project-owned rows hide, mirroring the Mac's `SupermuxProjectResolutionCache.filter`.
  The dot modifier attaches to `WorkspaceNavigationRow` before the row insets on the SwiftUI branch;
  the real iPhone UIKit table needs the independent #294 modifier on its hosted `WorkspaceRow`.
  The #97 driver fence gained `workspaces:` + `selectWorkspace:` arguments (pass the shell's closure as a literal —
  `{ selectWorkspace($0) }` — because `@MainActor` function types are implicitly `@Sendable` and a
  stored plain closure won't convert). Two consumer swaps: in `filteredWorkspaces` the fence is a
  one-line `let workspaces = supermuxFlatWorkspaces` rebind; in **`groupedWorkspaces`** the fence
  wraps only the `return` statement, because upstream's `parsedMachines` precompute now sits above
  it and must stay outside the fence. (Earlier revisions of this note called that second site
  `groupedListItems`; the property is `groupedWorkspaces`.)

`Packages/iOS/SupermuxMobileUI` additions are fork-owned (no fences): the `supermuxFlatRows` array extension (SupermuxWorkspaceListPartition.swift),
`SupermuxProjectWorkspaceRowSnapshot`, `SupermuxWorkspaceActivityDot` (palette mirrors the Mac's
`SupermuxActivityPalette`), the section model's open-workspace join, and the detail screen's real
Workspaces section. Its `Package.swift` gained a path dep on `../CmuxMobileShellModel` (target +
test target) so the partition/mapping can name `MobileWorkspacePreview`. New localization keys
`supermux.activity.working/needsInput/ready` exist in BOTH en and ja in the package catalog.

### 139–141 (+100 cont.). Mobile state sync v2 — §6 field parity (`supermux-mobile-workspace-fields`)

Upstream's **state sync v2** (`docs/mobile-state-sync-v2.md`) gives the phone a versioned record
mirror fed by `mobile.sync.delta` events and stops it re-fetching `mobile.workspace.list`. That
**bypasses the entire legacy payload path** the fork augments in #99, so without these fences a v2
phone silently loses project nesting, activity dots, branch subtitles, and PR badges the moment v2
negotiates — with no error and no test failure. The four fields therefore travel a second time,
through the v2 record type, and both transports are fed by the SAME augmenter so they cannot
diverge.

Chain, Mac → phone:

- **139. `Packages/Shared/CMUXMobileCore/…/MobileStateSyncRecords.swift`** — `WorkspaceSyncRecord`
  gains the four optional fields plus a nested `SupermuxPullRequest` (`Codable`, `Equatable`,
  `Sendable`; `{number?, state?, url?, is_stale?}`) whose `init(from:)` is **lossy on purpose** —
  a malformed additive field degrades to nil rather than failing the record, which would gap the
  client's mirror. Memberwise-init params are defaulted nil so upstream call sites compile
  unchanged and an upstream cmux Mac's records stay field-free; the `init(from:)` decodes use
  `try?`; `CodingKeys` reuse the legacy snake_case wire names
  (`supermux_project_id` / `supermux_activity` / `supermux_branch` / `supermux_pull_request`).
  Re-apply: five fence blocks (stored lets + nested struct, init params, init assignments,
  decode block, CodingKeys). Keep every field optional and every param defaulted.
- **140. `Sources/Mobile/MobileStateSync.swift`** — in `MobileStateSyncHost.workspaceRow(...)`,
  call `SupermuxMobileWorkspaceListAugmenter.augment([:], workspace: workspace)` (fork-owned,
  `Sources/Supermux/SupermuxMobileWorkspaceListAugmenter.swift`) and read the four values back out
  with the `SupermuxMobileWorkspaceFields.*Key` constants, mapping the PR dictionary into
  `WorkspaceSyncRecord.SupermuxPullRequest`. A fenced `import SupermuxKit` supplies the key
  constants. Re-apply requirement: **use the same augmenter as #99** — never recompute the fields
  here, or the two transports drift.
- **100 (cont.). `Packages/iOS/CmuxMobileRPC/…/MobileSyncWorkspaceListResponse.swift`** — the
  existing decode fence now also carries defaulted-nil supermux params + assignments on upstream's
  new memberwise `Workspace.init(...)` (added for locally-projected rows), and a **public**
  memberwise `init(number:state:url:isStale:)` on the nested `SupermuxPullRequest`. That init is
  load-bearing: declaring `init(from:)` suppresses the synthesized memberwise init, and a
  synthesized one would be `internal`, so `CmuxMobileShell` could not construct the type
  cross-module and #141 would not compile.
- **141. `Packages/iOS/CmuxMobileShell/…/MobileShellComposite+StateSync.swift`** — in
  `applyStateSyncProjection()`, pass `record.supermuxProjectID` / `…Activity` / `…Branch` and the
  mapped `SupermuxPullRequest` into `MobileSyncWorkspaceListResponse.Workspace(...)`. The
  projection then feeds `applyRemoteWorkspaceList`, the same apply path the wire response uses, so
  everything downstream (#101/#102 preview mapping, #103 hide filter and activity dot) works
  unchanged.

Verification after a merge: `git grep -n 'supermuxProjectID' Packages/Shared/CMUXMobileCore
Packages/iOS/CmuxMobileShell Sources/Mobile` must show all four links in the chain. A break in the
middle (record populated, projection not) is invisible on an upstream-paired phone and shows up
only as "my fork fields disappeared on the phone" after v2 negotiates. See the freshness caveat in
SUPERMUX.md "Known limitations" — under v2 the phone no longer refetches, so fork-field freshness
depends on the fork's own observer poke.

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

### 106. RETIRED (v0.64.19 merge) — `uitest-new-workspace-menu-item`

Followed this section's own re-apply note: upstream 0.64.19 restored the nav-bar
`MobileTerminalNewWorkspaceButton` on iOS (`WorkspaceDetailView`) and rewrote
`testWorkspaceToolbarCreatesWorkspaceAndTerminal` around
`MobileWorkspaceBackButton`/`MobileWorkspaceTitleMenu` toolbar assertions, so the fence was
dropped and the test is back to pure upstream. The registry row was removed with it.

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

The iOS Changes AND Files screens' mount point (architecture §7: workspace-detail entries). All
logic is fork-owned in `Packages/iOS/SupermuxMobileUI` (`SupermuxWorkspaceTools.swift` — the
`supermuxWorkspaceTools` view modifier, the capability gates, and
`SupermuxWorkspaceToolsMenuEntries` — plus `SupermuxChangesScreen` / `SupermuxDiffScreen` /
`SupermuxFileBrowserScreen` and their `SupermuxMobileKit` stores `SupermuxMobileChangesStore` /
`SupermuxMobileFileBrowserStore`). Two fences, same fence id:

- the `import SupermuxMobileUI` in the import block;
- `.supermuxWorkspaceTools(connection: store.supermuxConnectionSeam, workspaceID:
  workspace.rpcWorkspaceID.rawValue, workspaceName: workspace.name, showingChanges:
  $isSupermuxChangesSheetPresented, showingFiles: $isSupermuxFilesSheetPresented)` on the outer
  `Group` in `body`, BEFORE `.mobileConnectionRecoveryOverlay` — the outer Group so the sheets
  ride every detail branch (terminal / browser / chat) and survive upstream reshuffles of the
  inner `.toolbar` blocks. IMPORTANT: pass `workspace.rpcWorkspaceID.rawValue`, NOT
  `workspace.id.rawValue`. With two+ Macs paired, aggregation scopes `workspace.id` to
  `<macID>\u{1F}<uuid>`, but the Mac's `changes.*`/`files.*` RPCs parse `workspace_id` as a bare
  UUID, so the scoped id fails every request with `invalid_params`. `rpcWorkspaceID` is the
  Mac-local (unscoped) id the host expects.

Since the #228 toolbar consolidation the modifier mounts ONLY the two `.sheet`s presenting
`SupermuxChangesScreen` / `SupermuxFileBrowserScreen`; it adds no `ToolbarItem`s. The visible
entries are `SupermuxWorkspaceToolsMenuEntries` rows inside #228's explicit trailing overflow
menu, which flip the two `@State` bindings (fenced under #228) that this modifier receives.
Each row hides unless the #96 seam is connected AND the host advertises its capability —
`supermux.changes.v1` for Changes, `supermux.files.v1` for Files; an upstream Mac renders
exactly today's UI. One store is built per presentation from the seam's `MobileCoreRPCClient`
+ capability snapshot (the file browser rooted `.workspace(id:)`). (The former
`.github/swift-file-length-budget.tsv` row bump for `WorkspaceDetailView.swift` is retired —
see #4.)

Re-apply note: if upstream rewrites `WorkspaceDetailView`, the requirement is: the modifier must
sit on a view that (a) is inside the detail's `NavigationStack` context, and (b) has `store` +
`workspace` in scope, with `store.supermuxConnectionSeam` read inside `body` so Observation
re-evaluates on (re)connect/capability arrival. Any placement satisfying that works; keep both
fence lines together, and keep the two presentation bindings owned by the view that hosts the
overflow menu (#228).

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

⚠️ **INERT since the 0.64.21 merge — the fork behavior is GONE and phone search is LIVE again.**
This is an OPEN DECISION for the fork owner, not a working touchpoint. See SUPERMUX.md
"Known limitations".

Original intent: remove the main workspace list's search bar (iOS 26 places `.searchable` in the
bottom toolbar on iPhone) per direct user feedback on the shipped app. The fence was comment-only:
it REPLACED upstream's single `.searchable(text: $searchText)` modifier line on the `List` (right
after `.mobileInlineNavigationTitle()`), leaving nothing between begin/end, and with `@State
searchText` permanently `""` all of upstream's search plumbing (`trimmedQuery`, `matchesQuery`,
the search branch of `rendersGroupedSections`, the #103 hide-filter's `trimmedQuery.isEmpty` gate)
compiled but was inert.

What upstream changed: search moved out of this view into **two new files** —
`Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListSearchHost.swift` (pre-iOS
26: `.searchable(text:placement:)` on the wrapped content; macOS: plain `.searchable(text:)`) and
`…/MobilePrimaryTabScaffold.swift` (iOS 26+: a `Tab(value: .search, role: .search)` carrying
`.searchable(text:isPresented:prompt:)`). `WorkspaceListView.searchText` is now an **injected
property** (`var searchText = ""`, set by the caller), not `@State`, so the query is live and the
list filters on it again. `git grep -n '\.searchable(' -- Packages/iOS/CmuxMobileShellUI` shows no
hit in `WorkspaceListView.swift` — there is nothing left in this file to remove, and the fence
survives only as a comment-only marker pointing at the new hosts.

Decision needed: either (a) re-apply the removal at the new host(s) — note that would now suppress
search in the iOS 26 **search Tab** as well, which is a more visible amputation than the old
bottom-bar field; (b) accept upstream's search and RETIRE this touchpoint (delete the fence and
the row); or (c) keep the marker as-is, documenting that the fork intentionally no longer removes
search. The fork currently ships (c) by default. Do not resolve this from a merge.

### 116–117. `Sources/Workspace.swift` + `cmuxTests/TabManagerUnitTests.swift` — `workspace-geometry-snapshot-dedup`

At the top of `Workspace.splitTabBar(_:didChangeGeometry:)`, one fenced guard early-returns when
the incoming `LayoutSnapshot` is identical to the cached `tmuxLayoutSnapshot` except for its
`timestamp`:

```swift
// SUPERMUX:begin workspace-geometry-snapshot-dedup
if let previous = tmuxLayoutSnapshot,
   previous.containerFrame == snapshot.containerFrame,
   previous.focusedPaneId == snapshot.focusedPaneId,
   previous.panes == snapshot.panes {
    surfaceList.registerGeometryChange()
    if !isDetachingCloseTransaction {
        scheduleFocusReconcile()
    }
    return
}
// SUPERMUX:end workspace-geometry-snapshot-dedup
```

Why: Bonsplit stamps every snapshot with `Date()` (`BonsplitController.currentLayoutSnapshot`),
so the type's synthesized `Equatable` never dedupes, and `SplitViewContainer` re-emits geometry
callbacks from `onAppear`/`onChange` during SwiftUI remounts. Without the guard each redundant
emission republishes the `@Published tmuxLayoutSnapshot` (invalidating `WorkspaceContentView`),
posts `.workspacePaneGeometryDidChange` into `ContentView`'s `onReceive`, and re-kicks
window-wide terminal geometry reconciliation (`layoutSubtreeIfNeeded` on every visible window)
from inside a layout pass — the layout→publish→layout feedback loop captured in the supermux
CPU investigation (see PR #13's profile evidence). Selection/focus-only events still pass the
guard because `selectedTabId`/`focusedPaneId` are snapshot fields; the order-gated
`surfaceList.registerGeometryChange()` and the debounced `scheduleFocusReconcile()` run
unconditionally, matching pre-guard behavior for the cheap bookkeeping.

Re-apply note: after an upstream merge, re-insert the fence as the first statement of
`splitTabBar(_:didChangeGeometry:)` before the `tmuxLayoutSnapshot = snapshot` assignment. If
upstream adds fields to `LayoutSnapshot`, extend the field-by-field comparison (everything
except `timestamp`) or the guard silently stops deduping. If upstream ever drops the timestamp
from equality or dedupes in Bonsplit itself, delete the fence. The regression pair lives in
`cmuxTests/TabManagerUnitTests.swift` (`WorkspaceGeometrySnapshotDedupTests`, same fence id):
timestamp-only callbacks must not republish; real geometry changes must.

### 118. `README.md` — `readme-fork-rewrite`

The public repo's front page. Upstream's README describes cmux and points at cmux downloads,
docs, community, and Founders Edition; showing it verbatim on the fork would misrepresent the
repo, so the fork owns this file wholesale. The entire file is wrapped in one
`<!-- SUPERMUX:begin readme-fork-rewrite -->` … `<!-- SUPERMUX:end readme-fork-rewrite -->`
fence (HTML comments, invisible when rendered).

Contents are fork-authored: identity ("fork of cmux"), the feature list (projects, worktrees,
Changes panel, run actions, presets, `.supermux/config.json`, AI, iOS), build-from-source
instructions, the mergeability story, upstream credit, and license. The header image is the
app icon already shipped at `AppIcon.icon/Assets/supermux.jpg` (no new asset).

The 20 `README.<lang>.md` translation files remain upstream's, byte-for-byte — deleting them
would create recurring modify/delete merge conflicts for zero gain, so they are kept but no
longer linked from `README.md`.

Re-apply note: on any upstream merge conflict in `README.md`, take OUR whole file
(`git checkout --ours README.md`). Never union the two; upstream's marketing sections don't
apply here. When upstream ships features worth surfacing on the fork's front page, edit our
README deliberately instead of merging upstream text in. If upstream renames or moves its
README, nothing to do — this file stays.

### 119. `CONTRIBUTING.md` — `contributing-fork-note`

Upstream's contributing guide tells people to clone `manaflow-ai/cmux` and grants Manaflow a
license over contributions — misleading on a public fork that invites fork-feature PRs. One
fenced blockquote directly after the `# Contributing to cmux` H1 redirects fork contributions
to `rajinsyed/supermux` and to `SUPERMUX.md` as the fork contract; the rest of the file stays
upstream's, byte-for-byte.

Re-apply note: on merge conflict, take upstream's whole file, then re-insert the fenced
blockquote immediately after the H1. If upstream restructures the file heading, the fence just
goes at the very top.

### 120. `README.<lang>.md` (all 20) — `readme-translation-banner`

Each translation file still describes upstream cmux under cmux branding (title, DMG download
badge), and each links "English" back to our fork-owned `README.md` — so a non-English visitor
lands on a document about a different app with no explanation. A one-line fenced blockquote,
written in that file's language, is prepended to every `README.<lang>.md`: "this is the upstream
cmux README, translated; this repo is supermux, a fork — the fork's additions are documented in
README.md (English)". Nothing else in the files is touched.

Only `README.ja.md` carries a registry row (the check script wants one file per row); the fence
id is identical in all 20 files, and the check script's fence-registration scan accepts them all
via this entry. Files: ar, bs, da, de, es, fr, it, ja, km, ko, no, pl, pt-BR, ru, th, tr, uk,
vi, zh-CN, zh-TW.

Re-apply note: upstream edits to translation bodies merge cleanly under the banner (it sits
above the first heading). On a conflict, take upstream's file and re-prepend the banner —
recover the localized text with `git show <our-side>:README.<lang>.md | head -3`. If upstream
adds a new `README.<lang>.md`, prepend a banner in that language and add it to the list above.

### 130. `Sources/FeatureFlags.swift` — `appkit-sidebar-default-off`

Pins upstream's `sidebar-appkit-list-experiment` OFF on the fork. **Five fenced regions** since
the 0.64.21 merge (it was two — upstream added a production control-plane ingestion path, and an
automerge would have left the fork's gate covering only the now-test-only site):

1. **The default.** `private static let appKitSidebarListDefault = false` (upstream: `= true`).
2. **The gate.** `private static func supermuxIngestibleRemoteValue(_ value: Bool?, for key: String) -> Bool?`
   — `guard key == appKitSidebarListFlag.key else { return value }` then
   `return value == false ? false : nil`. Keying off `appKitSidebarListFlag.key` (not a string
   literal) means an upstream key rename cannot silently disarm it.
3. **`init`**, remote-cache seeding: wraps `Self.storedBoolValue(forKey: Self.remoteCacheKey(for:), …)`.
4. **`applyRemoteFlagValues(_:)`**, the PostHog control-plane loader (**the production path since
   this merge**): wraps `values[definition.key]`. Filtering to `nil` falls into upstream's `else`,
   which also evicts the cached value from `defaults`.
5. **`applyLoadedFlags()`**, the PostHog-SDK path (now reached only from tests): wraps
   `Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key))`. Filtering to `nil` falls
   into upstream's `else if`, which evicts a cached `true`.

**Invariants a re-applier must preserve:**

- A remote `true` for `sidebar-appkit-list-experiment` is **never** ingested at ANY site; a cached
  `true` is evicted.
- A remote `false` **still ingests** — that is upstream's kill-switch direction, so a Debug opt-in
  cannot outlive an upstream emergency disable.
- Every other flag passes through untouched.
- **Any NEW writer of `remoteValuesByKey` must route through `supermuxIngestibleRemoteValue`.**
  Find them with `git grep -n 'remoteValuesByKey\[' Sources/FeatureFlags.swift` after every merge;
  each assignment must sit inside a fence or behind the gate.

Why it matters: a remote rollout outranks both the flipped default and the user's local override
(`setOverride` refuses to shadow a remote value), and `appKitWorkspaceScrollArea` then renders
`SidebarWorkspaceTableView` directly — bypassing the SwiftUI list that hosts every supermux
sidebar feature.

Known gaps (both recorded in SUPERMUX.md "Known limitations"): three tests in
`cmuxTests/PostHogAnalyticsPropertiesTests.swift` assert upstream's contract and contradict this
fence, and **nothing asserts the ingestion invariant** — this merge is proof an upstream refactor
can defeat it with a clean automerge.

### 142. `cmuxTests/SSHPTYAttachNoProgressRetryTests.swift` — RETIRED (0.64.22 merge)

Existed for exactly one merge. Upstream `84f5755b56` (cmux #9425) shipped a compile break into
`cmuxTests` — `#expect(execution.status == 0, execution.stderr)`, where `#expect(_:_:)`'s second
parameter is a `Comment?` and a `String` **variable** does not convert (only a string *literal*
does, through `ExpressibleByStringInterpolation`). That broke the whole `cmuxTests` target, so the
0.64.21 merge carried a one-line fence wrapping it in `Comment(rawValue:)`.

Upstream fixed it in `b0b96e7b34` ("Fix Swift Testing diagnostic type") with
`#expect(execution.status == 0, "\(execution.stderr)")`. Exactly as the retirement note predicted,
that produced a conflict on these lines at the 0.64.22 merge; it was resolved by taking upstream
and deleting the fence. Nothing to re-apply — the file is byte-identical to upstream again.

### 143. `Packages/macOS/CmuxSettingsUI/.../Sections/SupermuxAISettingsCard.swift` — unfenced

Pre-existing registry gap, surfaced (not caused) by the 0.64.21 merge: the file is byte-identical
to pre-merge `HEAD`. It is a **whole fork-owned file inside an upstream package**, the same
situation as #68 and #69, and it is registered for the same reason — so
`supermux-check-touchpoints.sh` fails if an upstream package restructure drops it.

Why it lives there at all: `SettingsWindowScene.sectionStack` in `CmuxSettingsUI` is a closed,
hard-coded section list with no app-side injection seam, and the package cannot import
`SupermuxKit` (that would be a reverse dependency). So the card is self-contained, depending only
on `CmuxSettings`/SwiftUI, and shares two literals with `SupermuxKit.SupermuxAIConfig`: the secret
file name (`supermux-ai-gateway-key`) and the model-override UserDefaults key
(`supermux.ai.model`). Mounted by the #18 `ai-settings` fences in `AutomationSection.swift`.

Re-apply: keep the file compiled into the `CmuxSettingsUI` target. If upstream ever opens the
section stack to injection, move the card into `Sources/Supermux/` and retire both this row and
#18.

### 144. `scripts/cleanup-dev-builds.sh` — unfenced (**fence still to be added**)

Pre-existing unfenced fork edit, surfaced (not caused) by the 0.64.21 merge: the file is
byte-identical to pre-merge `HEAD`. Registered so the check at least guards the file's existence.

**Action still outstanding:** unlike `project.pbxproj` or a plist, this file is a shell script and
the surrounding lines already carry comments, so it **is** fenceable and should carry a real
`SUPERMUX:begin/end` pair rather than an `unfenced` row. Whoever owns
`scripts/cleanup-dev-builds.sh` should wrap the edit and change this row's fence-id cell from
`unfenced` to the new id.

The edit, in the running-tag detection loop (`# Running cmux DEV processes by tag`):

```bash
# upstream:
if [[ "$line" =~ cmux\ DEV\ ([A-Za-z0-9._-]+) ]]; then
# fork:
if [[ "$line" =~ cmux\ DEV\ ([A-Za-z0-9-]+)\.app ]]; then
```

Why: the running process path is `.../cmux DEV <slug>.app/Contents/MacOS/cmux DEV`, and the
captured slug must match the `cmux-<slug>` DerivedData directory name. Upstream's char class
includes `.` and has no anchor, so the greedy match ate the bundle suffix and captured
`<slug>.app` — which never matched a DerivedData dir, silently defeating the running-app
protection and letting cleanup delete DerivedData for a tag that was still running. Excluding `.`
from the class and anchoring on the literal `.app` stops the match at the bundle suffix.

Re-apply: restore the fork regex (both the class change AND the `\.app` anchor — either alone is
wrong) and keep the explanatory comment block above it.

### 322–324. Panel-scoped agent liveness evidence (`panel-agent-liveness-evidence`)

Closes the crash-path orphan the #292 SessionEnd fix cannot reach: with several Claudes sharing
the `claude_code` key, only ONE panel owns the PID slot, so a non-owner Claude that dies without
a SessionEnd (SIGKILL, terminal crash) leaves its `running`/`needsInput` lifecycle entry invisible
to both stale sweeps — the workspace spinner stays on with zero agents running.

Mechanism: `recordAgentPID` (the single path every PID-bearing agent report crosses) also records
the reporting panel's `AgentPIDProcessIdentity` into `SupermuxPanelAgentEvidence`, keyed
per (workspace, panel, status key) so a sibling stealing the shared slot cannot erase it. The two
existing sweeps then get one fenced companion call each: the prompt-idle panel sweep and the 30 s
workspace sweep retire lifecycle entries whose recorded process is provably dead AND whose status
key the panel no longer owns (owned keys stay upstream's job). The workspace sweep folds that result
into `didChange`, so its notification cleanup still runs, and `clearAllAgentPIDs` removes the whole
workspace evidence bucket during reset/teardown. No evidence or a live process ⇒ never touched;
retirement goes through the ordinary panel-scoped `clearAgentLifecycle`, so the lifecycle relay and
mobile observers fire like any other clear.

Re-apply: restore the four `panel-agent-liveness-evidence` fences in
`Workspace+PanelLifecycle.swift` (record hook after the ownership write in `recordAgentPID`;
companion calls at the end of both `clearStaleAgentPIDs` variants before their `didChange`
handling; workspace evidence removal in `clearAllAgentPIDs`), keep
`Sources/Supermux/SupermuxPanelAgentEvidence.swift` compiled into the cmux target (pbxproj ids
`50BE0001…0101`/`…0102`), and keep the fenced tests in `AgentHibernationTests.swift`.

### 292–296. Multi-agent workspace activity cleanup and missing row mounts

These five touchpoints close three independent gaps that combine in multi-Claude workspaces:

- **292. `Workspace+PanelLifecycle.swift` — `panel-scoped-shared-agent-lifecycle-clear`:**
  `clearAgentPID` still rejects a supplied panel when another panel owns the shared PID key, but
  before returning it now clears the requesting panel's lifecycle unless `requireOwnedKey` is true.
  This distinction is load-bearing: `claude_code` is one shared key across every Claude terminal,
  so PID ownership legitimately moves to the latest reporter, while lifecycle state remains
  panel-scoped. Never clear the sibling owner's PID/identity/ownership from this mismatch branch.
  Re-apply immediately inside the `ownedPanelId != panelId` guard, before any PID dictionaries mutate.
- **293. `AgentHibernationTests.swift` — same id:** keep the two-panel regression next to the existing
  same-status-key clear test. The second panel owns `claude_code`; clearing the first must remove only
  its `needsInput` lifecycle and retain the second panel's running lifecycle, PID, and ownership.
- **294. `WorkspaceListTableCoordinator.swift` — `supermux-mobile-row-activity`:** attach
  `.supermuxWorkspaceActivityDot(rawActivity: workspace.supermuxActivity)` directly to the hosted
  `WorkspaceRow`, before its accessibility modifiers. The #103 call site remains for the SwiftUI
  list branch, but iPhone renders this UIKit table and never executes that branch.
- **295. `SidebarWorkspaceRowCellView.swift` — `sidebar-appkit-row-activity`:** the AppKit row's
  existing `GPUSpinnerNSView` slots also activate when `snapshot.supermuxActivity == .working`, even
  when upstream's agent-spinner experiment is off. The Supermux path is amber and uses the existing
  `supermux.activity.working` tooltip; the upstream spinner path keeps its original color/count
  tooltip. The leading-row spacing must derive from the actual mounted spinner so either path lays
  out correctly. Keep the DEBUG visible-spinner-count seam with this fence.
- **296. `SidebarAppKitRowCellTests.swift` — same id:** preserve the helper's defaulted
  `supermuxActivity`/`showsAgentActivity` inputs and the real-cell test proving `.working` mounts one
  spinner with `showsAgentActivity=false` and an upstream active count of zero.

The shared aggregation and mobile association fixes live in fork-owned `Packages/SupermuxKit` files,
so they need no fences: `SupermuxWorkspaceActivity.resolve` makes running win over a sibling
needs-input state, and `SupermuxMobileWorkspaceFields.fields` emits activity for unassociated/global
workspaces while keeping project id/branch/PR association-gated.

### 145. `cmuxTests/PostHogAnalyticsPropertiesTests.swift` — unfenced (**debt placeholder, file not yet modified**)

Registered so the fork's outstanding test debt against #130 is visible in the manifest rather than
only in a review thread. **Nothing has been changed in this file** — the row exists to stop the
problem being rediscovered from scratch at the next merge, and to guard the file's existence.

Three upstream tests assert upstream's flag contract and therefore contradict the fork's
`appkit-sidebar-default-off` pinning:

| Test | Asserts | Why it fails on the fork |
|---|---|---|
| `appKitSidebarFeatureFlagDefaultsOn` | `flag.defaultWhenUnavailable` is true for `sidebar-appkit-list-experiment` | #130 flips `appKitSidebarListDefault` to `false` |
| `featureFlagResolutionPrecedence` | after a remote `true` for that key, `flags.remoteValue(for: flag) == true` | #130's gate filters a remote `true` to `nil` at every ingestion site |
| `remoteControlledFlagsRejectNewLocalOverrideWrites` | after a remote `true` for that key, `setOverride(false, …)` is rejected | there is no ingested remote value to reject against |

Verified with `git show HEAD:cmuxTests/PostHogAnalyticsPropertiesTests.swift` that all three method
bodies are byte-identical to pre-merge `HEAD`: this is **standing fork debt, not 0.64.21 merge
damage**.

OPEN DECISION (see SUPERMUX.md "Known limitations"): the cleanest fix is probably to **retarget**
the three tests onto a flag key the fork does not pin — they are testing the generic
default/override/remote precedence machinery, not the sidebar experiment specifically — which
keeps upstream's coverage intact behind a small fence. The alternative is to fence the three
expectations to the fork's values, which is a larger fence and loses upstream's own assertions. Do
not pick one from inside a merge. When it is resolved, replace this row's `unfenced` cell with the
real fence id.

### 134–138. Upstream conventions-lint debt at the 0.64.20 merge — `lint-allow-upstream-debt`

Upstream paused its automatic CI on 2026-07-13 (all core workflows became `workflow_dispatch`-
only), so `scripts/lint-ios-package-conventions.sh` violations accumulated on upstream `main`
unchecked. The 0.64.20 merge (upstream snapshot `98a701ffd9`) imported five of them; the fork
still dispatches the `iOS simulator tests` workflow, whose `package-conventions-lint` job fails
on any ERROR. Each offender carries a two-line fence directly above the flagged declaration,
with the `lint:allow <rule>` marker on the `SUPERMUX:end` line so it lands inside each rule's
suppression window (free-function/lock: ≤2–3 lines above; namespace-enum: exactly 1 line above;
namespace-type: ≤3 lines above). Per #109's rule, `scripts/lint-namespace-types-baseline.txt`
was NOT grown.

Re-apply note: re-insert the two fence lines directly above the flagged declaration (below any
doc comment; above `@MainActor` in `CmuxPopoverMutation.swift`), keeping `lint:allow <rule>` on
the `SUPERMUX:end` line. Verify with `./scripts/lint-ios-package-conventions.sh` (expect
"OK: no unjustified convention violations."). Drop any of these fences as soon as an upstream
merge brings the real fix for (or upstream's own `lint:allow` at) that site — these fences are
pure grandfathering and may only shrink.

### 244–250. Agent chat Focus Mode — `agent-chat-focus-mode` + `ios-agent-chat-focus-mode`

A coding-agent session is mostly tool calls. Rendered one row each, they bury the handful of
sentences the agent actually said — which is what the user opened the phone to read. Focus Mode
folds each consecutive run of work rows behind a single tappable "Working · N steps" summary.

**What folds:** `toolUse`, `thought`, `terminal`, `fileEdit`.
**What never folds:** prose, user prompts, `question`, `permissionRequest`, `status`, `attachment`,
date headers, the unread separator, and pending outbound prompts. Questions and permission requests
BLOCK the agent — hiding them behind a disclosure would strand the session. `SupermuxChatFocusGroupingTests`
pins both lists, plus the invariant that grouping never drops or reorders a row.

Runs shorter than `minimumGroupSize` (2) stay expanded: folding a single call costs a tap and saves
nothing.

**Where the code lives.** All of it is fork-owned under
`Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/AgentChat/`
(`SupermuxChatFocusGrouping` — the pure fold; `SupermuxChatFocusMode` — the modifier that owns
expanded state; `SupermuxChatWorkGroupRow` — the summary; `SupermuxChatShimmerText`). Upstream keeps
owning the table, keyboard tracking, paging, and every individual row view — expanded runs call
straight back into `ChatTranscriptRowView`.

**Three things are load-bearing and easy to lose on a re-apply:**

1. **Entries are computed once per update, in `updateUIView`** (#245), and shared by `makeItems()`
   and the cell factory. Computing them inside the factory instead re-runs the fold for every
   visible cell on every streamed delta, and lets the two disagree about what entry N is.
2. **`groupingReloadIdentity` must stay in `shouldReload`** (#245). It combines the grouping's
   configuration identity with the ordered entry ids, so both "the setting flipped" and "a group
   expanded, so its rows moved" force a reload. Without it the table keeps stale cells.
3. **Expanded state lives in `SupermuxChatFocusModifier`, above the transcript** — deliberately not
   in `SupermuxChatWorkGroupRow`. The transcript is a `UITableView` that decides to reload by
   comparing item identity; a tap that only flipped a child view's private `@State` would resize a
   cell the table does not know changed (self-sizing drift). Keeping it above means a tap changes
   the grouping identity, which forces a clean reload.

**To re-apply after an upstream merge:**

- If upstream reshapes `ChatTranscriptTableView`, re-add the seven fences from #245. The
  `.groupedEntry` case follows whatever item taxonomy upstream now has.
- If upstream reshapes the Display settings section, re-add the #247 toggle.
- Verify it is actually live, not just compiling: open a Claude session with Focus Mode on and
  confirm runs of tool calls appear as one "Working · N steps" row that expands on tap. If every
  tool call still renders individually, the #248 modifier or item 1 above was dropped.

### 338–339. Mac user-dogfood profile seeding — `reload-supermux-profile*` + `mac-dogfood-supermux-profile`

**Problem.** A tagged Debug Mac build bakes `CMUX_AUTH_WWW_ORIGIN=http://localhost:<port>` into its
`LSEnvironment`, so its sign-in flow redirects to a dev web origin nothing serves; and even with
`--prod-auth`, the tag's bundle id isolates its token store, so the user starts signed out with
default settings. The user cannot dogfood such a build.

**Fix.** `scripts/reload.sh` gains `--supermux-profile` (three small fences in #338, all calling out
to the supermux-owned `scripts/supermux-seed-dev-profile.sh`):

1. `reload-supermux-profile` — declares `SUPERMUX_PROFILE=0` next to `PROD_AUTH` and documents the
   flag in the usage text.
2. `reload-supermux-profile-parse` — `--supermux-profile) SUPERMUX_PROFILE=1; PROD_AUTH=1` in the
   arg loop (implies `--prod-auth`, so the plist gets `CMUX_AUTH_ENVIRONMENT=production` and the
   cmux.com origins).
3. `reload-supermux-profile-seed` — after the tag-mode "quit the old same-tag app" block, calls the
   seeder with `--target-bundle-id "$BUNDLE_ID"` and `--wait-for-exit` on the tagged executable
   path. Failure fails the reload (a silently signed-out dogfood build is the bug this exists to
   prevent).

The seeder (fork-owned, no fence) copies from the `com.supermux.app` release install:
- the full UserDefaults domain (`defaults export | import`), then force-writes
  `cmux.auth.stackProjectID` to the production Stack project id (parsed out of
  `Sources/Auth/AuthEnvironment.swift`) so `MacAuthComposition.detectAuthProjectSwitch` does not
  clear the seeded tokens on first launch, and `cmux.auth.hasTokens=true`;
- `~/Library/Application Support/cmux/com.supermux.app/credentials.json` (the release build's Stack
  file token store) into the tag's directory via 0600 temp file + atomic rename in a 0700 dir,
  after validating ownership, non-symlink, JSON shape, and a non-empty refresh token. Tagged Debug
  builds are ad-hoc signed, so their keychain writes fail and they read the same file fallback.

**Why sharing tokens is safe / the one hazard.** Stack Auth does not rotate refresh tokens
(`alwaysIssueNewRefreshToken: false` server-side; the vendored SDK writes the same refresh token
back on refresh), so both apps mint access tokens off one session concurrently. Sign-out is the
exception: `DELETE /auth/sessions/current` revokes the shared session row, signing out the main
app too. Hence the documented rule: never sign out inside a seeded build.

**#339** is the `mac-dogfood-supermux-profile` fence in `CLAUDE.md` (after upstream's "Build and
reload" section): user-facing Mac dogfood builds must use `--supermux-profile`; agent-only builds
keep plain `--tag` + the `~/.secrets` auto-sign-in.

**To re-apply after an upstream merge:** re-add the three #338 fences around reload.sh's flag
declarations, arg parse, and the post-quit block (the seeder script itself is fork-owned and merges
clean), and re-insert the #339 doc fence after upstream's reload section.
