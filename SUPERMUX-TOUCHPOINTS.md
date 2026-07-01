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
| 2 | `Sources/ContentView.swift` | `sidebar-projects-section`, `sidebar-hide-project-workspaces`, `sidebar-flatrow-activity`, `sidebar-selection-faint`, `sidebar-projects-empty-area` | Mounts `SupermuxProjectsMount()` atop the sidebar; hides project-owned workspaces from the flat list; renders the agent-activity indicator on flat-list workspace rows; gives the flat-list selection the faint accent tint used by nested project rows; subtracts the Projects-section height from the empty-area remainder so the sidebar's empty space stays unscrollable |
| 3 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the SupermuxKit package + `Sources/Supermux/` files into the cmux target, `cmuxTests/SupermuxSidebarBranchTests.swift` into the cmuxTests target, and the three `AppIcon*.icon` Icon Composer files into the app Resources phase (see #17) |
| 4 | `.github/swift-file-length-budget.tsv` | `unfenced` | Budget rows raised by exactly the fenced growth in their files (see #4 notes below) |
| 4b | `Resources/Localizable.xcstrings` | `unfenced` | Adds en+ja entries for all `supermux.*` keys (additive only; never edits non-supermux keys) |
| 5 | `Sources/RightSidebarPanelView.swift` | `right-sidebar-changes-mode-*`, `right-sidebar-compact-mode-bar` | Adds the `changes` right-sidebar mode (case/label/symbol/shortcut/rootsync) and renders `SupermuxChangesMount` for it; `right-sidebar-compact-mode-bar` wraps the mode-bar controls in `ViewThatFits` so the mode buttons collapse to icon-only when the sidebar is narrow (keeps the close button visible down to the lowered min width) |
| 6 | `Sources/RightSidebarMode+Availability.swift` | `right-sidebar-changes-mode-*` | `changes` is always available and reachable from the CLI mode argument |
| 7 | `Sources/RightSidebarToolPanel.swift` | `right-sidebar-changes-mode-*` | `.changes` joins the `.feed, .dock` no-op groups (sync/focus/intent/anchor, ×4) |
| 8 | `Sources/MainWindowFocusController.swift` | `right-sidebar-changes-mode-*` | Focus routing for the changes mode (host, no special endpoint) |
| 9 | `Sources/ContentView+RightSidebarCommandPalette.swift` | `right-sidebar-changes-mode-*` | Palette command id for "Show Changes"; not openable as a pane |
| 10 | `CLI/cmux.swift` | `right-sidebar-changes-mode-*` | CLI accepts `cmux right-sidebar set changes` (and the `changes` alias) |
| 11 | `Sources/KeyboardShortcutSettings.swift` | `run-toggle-shortcut-*` | `supermuxToggleRun` action (case/label/default ⌘G, shared with Find Next) |
| 12 | `Sources/AppDelegate.swift` | `run-toggle-shortcut-*` | ⌘G dispatch: Find Next while find overlay is open, run toggle otherwise |
| 13 | `.github/workflows/ci.yml` | `ci-package-tests` | Adds `SupermuxKit` to the SPM package-test allowlist so its tests gate CI |
| 14 | `web/data/cmux.schema.json` | `unfenced` | Adds `supermuxToggleRun`, `supermuxWorkspaceSwitcherNext`, and `supermuxWorkspaceSwitcherPrevious` to the shortcut-action enum so cmux.json validation accepts rebinding them |
| 15 | `web/data/cmux-shortcuts.ts` | `run-toggle-shortcut-doc` | Documents the `supermuxToggleRun` ⌘G shortcut in the keyboard-shortcut registry |
| 16 | `Sources/WorkspaceContentView.swift` | `presets-bar` | Renders `SupermuxPresetsBarMount(workspace:)` above the splits (normal mode only); minimal mode keeps the original top-safe-area layout |
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + byte-identical `AppIcon-Debug.icon` + `AppIcon-Nightly.icon` (no DEV/NIGHTLY bands — all three channels share one mark); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered icon. Wiring lives in touchpoint #3. || 18 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) at the end of the Automation section, and stores the `secretStore` + `errorLog` the card needs. The card itself is a new supermux-owned file, `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). **Upstream relocated this package under `Packages/macOS/`; the new card moved with it (git rename detection placed it at the new path).** |
| 20 | `Sources/GhosttyTerminalView.swift` | `browser-link-new-tab` | When a cmd-clicked terminal link opens in the embedded browser and there is no existing browser pane to reuse, open it as a new browser tab in the current pane (and switch to it) instead of creating a horizontal split |
| 21 | `Sources/App/ShortcutRoutingSupport.swift` | `run-toggle-shortcut-dispatch` | ⌘G (the supermux Run/Stop toggle, shared with Find Next) is never ceded to a focused browser's native find, so cmux always owns the chord (otherwise WebKit swallows ⌘G and it is a dead key in the browser) |
| 22 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `run-toggle-shortcut-dispatch` | Updates the browser-find routing contract for ⌘G (run-toggle chord excluded from browser-first routing) and adds the regression test |
| 23 | `Sources/KeyboardShortcutSettings.swift` | `workspace-switcher-shortcut-case`, `workspace-switcher-shortcut-label`, `workspace-switcher-shortcut-default` | Adds the two workspace-switcher shortcut actions: `supermuxWorkspaceSwitcherNext` (default ⌘\`) and `supermuxWorkspaceSwitcherPrevious` (default ⇧⌘\`) |
| 24 | `Sources/AppDelegate.swift` | `workspace-switcher-monitor` | One hook in the app-local NSEvent monitor routes every event to `SupermuxComposition.workspaceSwitcher.handleMonitorEvent(_:appDelegate:)`: idle it acts only on the open chord; while presented it owns keyDown/keyUp/flagsChanged so it can cycle and commit on ⌘ release |
| 25 | `web/data/cmux-shortcuts.ts` | `workspace-switcher-shortcut-doc` | Documents the two workspace-switcher shortcuts in the keyboard-shortcut registry |
| 26 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` | `right-sidebar-min-width` | Lowers the right-sidebar minimum width floor from upstream's 276 to 200 so the panel can be dragged narrower (mode bar collapses to icon-only via touchpoint #5). **Upstream relocated this package under `Packages/macOS/` (cmux package reorg).** |
| 27 | `cmuxTests/SidebarWidthPolicyTests.swift` | `right-sidebar-min-width-test` | Two right-sidebar clamp assertions read `RightSidebarWidthSettings.minimumWidth` instead of the hardcoded `276`, so they track the lowered floor |
| 28 | `Sources/KeyboardShortcutSettings.swift` | `toggle-split-zoom-rebind` | Rebinds the `toggleSplitZoom` default from ⇧⌘↩ to ⌃⌘Z (canonical table) so ⇧⌘↩ is free for the supermux Changes-panel commit accelerator |
| 29 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `toggle-split-zoom-rebind` | Mirror of the rebound ⌃⌘Z default for the settings-UI package. **Upstream relocated this package under `Packages/macOS/`.** |
| 30 | `web/data/cmux-shortcuts.ts` | `toggle-split-zoom-rebind` | Documents Toggle Pane Zoom as ⌃⌘Z in the keyboard-shortcut registry |
| 31 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `toggle-split-zoom-rebind` | The split-zoom shortcut test drives the configured default, so it presses ⌃⌘Z (was ⇧⌘↩) |
| 32 | `cmuxTests/KeyboardShortcutContextTests.swift` | `toggle-split-zoom-rebind` | Comment accuracy: toggleSplitZoom is no longer the Return-based shortcut (now ⌃⌘Z); assertions unchanged |
| 33 | `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | `toggle-split-zoom-rebind` | Two browser zoom round-trip UI tests press ⌃⌘Z instead of ⇧⌘↩ |
| 34 | `Sources/GhosttyTerminalView.swift` | `ghostty-unbind-split-zoom-return` | Unbinds Ghostty's built-in `super+shift+enter = toggle_split_zoom` so the freed ⇧⌘↩ actually reaches the Changes-panel commit accelerator in a focused terminal (without it the rebind is incomplete — same class as the numbered-tab unbinds, #5189) |
| 35 | `Sources/App/ShortcutRoutingSupport.swift` | `toggle-split-zoom-rebind` | Comment accuracy: the browser-Return rule no longer cites Toggle Pane Zoom as the Command-Return app shortcut (now ⌃⌘Z); notes ⇧⌘↩ is the commit accelerator. Logic unchanged |
| 36 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Regression test `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback` asserts the loaded Ghostty config has no `super+shift+enter` binding (companion to the #5189 numbered-fallback test) |
| 37 | `Sources/KeyboardShortcutSettings.swift` | `supermux-commit-shortcut-case`, `supermux-commit-shortcut-label`, `supermux-commit-shortcut-default` | Registers the Changes-panel `supermuxCommit` (⌘↩) and `supermuxCommitAccelerator` (⇧⌘↩) actions (case/label/default) so both are editable in Settings, live in `cmux.json`, and participate in conflict detection; applied by the panel's SwiftUI buttons (read via `SupermuxChangesMount`), not the app monitor |
| 38 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `supermux-commit-shortcut` | `testSupermuxCommitDefaultsBindReturnChords` asserts the two commit actions default to ⌘↩ / ⇧⌘↩ and do not cross-match |
| 39 | `Sources/FileExplorerView.swift` | `file-explorer-operations`, `file-explorer-operations-empty`, `file-explorer-operations-reveal` | Adds file-management to the right-sidebar file tree (local provider only): context-menu items New File/New Folder/Rename/Duplicate/Move to Trash on a clicked node, New File/New Folder on the empty area (root); the `-reveal` fence scrolls a just-created/renamed item into view after the reload. Keyboard handling (`file-explorer-operations-keys`) moved to #46 when upstream extracted the outline-view subclass into its own file (cmux #6001). All logic lives in supermux-owned files (`Sources/Supermux/SupermuxFileExplorerCommands.swift`, `SupermuxFileExplorerPrompt.swift`) and `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileSystemOperations.swift`; the fences are one-line calls into a `FileExplorerPanelView.Coordinator` extension |
| 40 | `Sources/FileExplorerStore.swift` | `file-explorer-operations-reveal` | Adds `supermuxRevealPath` + `supermuxReveal(path:)` to `FileExplorerStore` so a supermux file operation can select a just-created/renamed item by path (the selection state is `private(set)`, so this must live in the store's own file). Paired with the coordinator's `-reveal` hook in touchpoint #39 |
| 41 | `Sources/TabManager.swift` | `new-workspace-standalone` | Marks every workspace created through cmux's normal new-workspace flow (`+` / ⌘T / surface tab bar) as standalone (`SupermuxWorkspaceAssociationStore.markStandalone` in `addWorkspace`) so it lands at the root of the flat list, never nested under the focused project. The project opener clears it via `associate`; the central close path clears it via `forget`. `restoreClosedWorkspace` (reopen) goes through `addWorkspace` too, so it explicitly `forget`s the mark afterwards to re-nest by directory; **session**-restore builds `Workspace` objects directly (no `addWorkspace`) and is unaffected |
| 42 | `Sources/TabManager+DetachedWorkspace.swift` | `new-workspace-standalone` | The detached-surface path (move-tab / move-surface to a new workspace) builds a `Workspace` directly, not via `addWorkspace`, so it marks the new workspace standalone too — a moved-out surface becomes a root-level workspace, never nested under a project whose directory it inherited |
| 43 | `Sources/TabManager.swift` | `keep-window-on-last-close` | Keeps the window open as an empty home when the last workspace closes — instead of `window.performClose`, which quit the app on the last window. `closeWorkspace(allowEmptyingWindow:)` removes the final workspace (selection clears to `nil`); the three last-workspace close sites + the bulk-close short-circuit/plan + the child-exit path route through it, failed closed-workspace restore cleanup can empty the window again, and close confirmations no longer mark last-workspace closes as window-closing. Explicit window close (red button / ⌘⇧W) is unchanged |
| 44 | `Sources/ContentView.swift` | `empty-home` | `terminalContent` renders `SupermuxEmptyHomeView` (centered "No open tabs" hint) when `tabManager.tabs` is empty, gated to the `.tabs` sidebar surface and non-interactive. New file `Sources/Supermux/SupermuxEmptyHomeView.swift` wired via touchpoint #3 (IDs `…F5`/`…F6`); `supermux.emptyHome.*` keys under #4b |
| 45 | `cmuxTests/TabManagerUnitTests.swift` | `keep-window-on-last-close` | Repurposes the child-exit window-close test to assert the window stays open (empty home), adds two tests for `closeWorkspace(allowEmptyingWindow:)` emptying the window vs. a plain close keeping the last workspace, and covers failed closed-workspace restore cleanup from empty home |
| 46 | `Sources/FileExplorerNSOutlineView.swift` | `file-explorer-operations-keys` | ⌘⌫ (Move to Trash) / Return (Rename) keyboard handling in the outline view's `keyDown`, placed **before** upstream's `handleOpenSelectionShortcut` so Return renames (Finder-standard) and ⌘⌫ trashes; ⌘↓ still opens via upstream's Finder alias. Upstream (cmux #6001) extracted `FileExplorerNSOutlineView` out of `FileExplorerView.swift` into this file, so the `-keys` fence (originally part of #39) moved here. One-line call into the `FileExplorerPanelView.Coordinator` extension |
| 47 | `CLI/CMUXCLI+ThemeSupport.swift` | `right-sidebar-changes-mode-cli-set`, `right-sidebar-changes-mode-cli-normalize` | Adds `"changes"` to `isRightSidebarCLIMode` and `normalizedRightSidebarCLIArgument` so `cmux right-sidebar set changes` / `cmux right-sidebar changes` validate and normalize. Upstream (cmux CLI refactor) moved these two helpers out of `CLI/cmux.swift` into this file, so the `-cli-set` fence (originally part of #10) moved here; `-cli-normalize` is new (the normalizer did not exist at the previous merge base) |
| 48 | `Sources/RightSidebarChromeStyle.swift` | `right-sidebar-compact-mode-bar` | Adds a `showsLabel` flag to upstream's `ModeBarButton` (icon-only when the sidebar is narrow). Upstream relocated `ModeBarButton` here from `RightSidebarPanelView.swift` and switched it to an `item:`-based API; the compact-mode-bar fence (part of #5) moved with it. `RightSidebarPanelView.modeButtonsRow` now drives the `modeBarItems`/`ModeBarButton(item:showsLabel:)` API inside `ViewThatFits` |
| 49 | `Sources/Sidebar/SidebarWorkspaceSnapshotRefreshPolicy.swift` | `sidebar-flatrow-activity` | Carries `supermuxActivity` through the frozen-snapshot `applyingContextMenuImmediateFields` rebuild (the third construction site of `SidebarWorkspaceSnapshotBuilder.Snapshot`, alongside the two in `ContentView.swift`). Previously an unfenced edit; fenced and registered during the upstream merge that added `finderDirectoryPath`/`mediaActivity` to the same initializer |
| 50 | `Sources/ContentView.swift` | `sidebar-hide-scrollbar` | Hides the left workspace sidebar's scrollbar. Two layers: (a) `VerticalTabsSidebar.configureSidebarScrollView` (the shared resolver hook for both the default projects+workspaces list and the extension-provider list) no longer calls upstream's `applySidebarOverlayScrollerConfiguration()`; it instead forces `hasHorizontalScroller`/`hasVerticalScroller` to `false` (write-only-when-differs). (b) Both sidebar `ScrollView`s get `.scrollIndicators(.hidden)` so SwiftUI itself keeps the indicator hidden — the AppKit resolver alone loses to SwiftUI, which re-asserts the scroller from its default `.scrollIndicators(.automatic)` after the resolver's deferred apply. Scrolling still works via trackpad/wheel |
| 51 | `scripts/reload.sh` | `reload-prune-leftover-base-app` | After a tagged build renames the raw `cmux DEV.app` into `cmux DEV <tag>.app`, calls the supermux-owned `scripts/supermux-prune-dev-builds.sh --reload-leftover` to deregister + delete the never-launched leftover base bundle, so macOS stops accumulating one stale "cmux DEV" row per tag in System Settings > Login Items & Extensions. The prune script is supermux-owned (no touchpoint); only this one-line call into it is fenced |
| 52 | `ios/cmuxPackage/Sources/cmuxFeature/MobileAuthComposition.swift` | `force-production-auth` | Lets the DEBUG iOS build opt into the PRODUCTION Stack project + cmux.dev callback when the bundled `LocalConfig.plist` sets `STACK_ENVIRONMENT=production`, so a personally-signed DEBUG phone build pairs with the installed production Supermux Mac. Without the key, behavior is unchanged (DEBUG → development) |
| 53 | `ios/Config/cmux.entitlements` | `unfenced` | Strips `com.apple.developer.applesignin`, `aps-environment`, and `com.apple.developer.usernotifications.time-sensitive` so automatic signing can provision a personal Apple team that lacks those capabilities (comments are unsafe to fence around a plist-key removal) |
| 54 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires `LocalConfig.plist` into the iOS app's Copy Bundle Resources phase (build file `FCAB1004…`, file ref `FCAB101B…`) so the app can read it from the bundle |
| 55 | `ios/cmux/Resources/LocalConfig.plist` | `unfenced` | New supermux-owned resource read by touchpoint #52; sets `STACK_ENVIRONMENT=production`. Not an upstream modification — registered so the check guards its existence (the pbxproj entry in #54 references it) |
| 56 | `Sources/DragOverlayRoutingPolicy.swift` | `browser-hover-drag-guard` | Bug fix (re-land of fcb443d8df, dropped in the undo/re-land cycle around 544bdc1d5d): gates the browser-portal hover→drag pass-through on the left mouse button actually being held, so a stale `.drag` pasteboard (Bonsplit/sidebar tab-transfer types persist after a drag ends) can no longer misroute ordinary hover past the WKWebView. Regression test in `cmuxTests/PortalTabDragRoutingTests.swift` (#58) |
| 57 | `Sources/Panels/BrowserPanelView.swift` | `browser-hover-webkit-topmost-gate` | Bug fix: WebKit only processes hover (mouseMoved → CSS `:hover`, cursor updates, tooltips) when `window.contentView.hitTest(...)` resolves to the WKWebView or a descendant (`updateViewIsTopmostAtMouseLocation:` in WebKit's WebViewImpl.mm). cmux's browser portal hosts the web view on the theme frame — outside the contentView subtree — so that gate always failed and hover was dead in every embedded browser pane while clicks/scroll kept working. The SwiftUI-side anchor (`WebViewRepresentable.HostContainerView`) now delegates hover-time hit tests to the portal-hosted web view (page + docked DevTools frontend). Two fences: the anchor property/helper/`hitTest` hook, and the `updateNSView` wiring. Regression test in #58 |
| 58 | `cmuxTests/PortalTabDragRoutingTests.swift` | `browser-hover-drag-guard`, `browser-hover-webkit-topmost-gate` | Regression tests for #56 (hover with no held button must not pass through the portal; active drags still do) and #57 (the anchor delegates hover hit tests to the portal-hosted web view; non-hover contexts, out-of-bounds points, and other-window web views are not claimed) |

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
let mainListTabs = SupermuxMainListFilter.tabsForMainList(tabs)
let workspaceRenderItems = SidebarWorkspaceRenderItem.renderItems(
    tabs: mainListTabs, groupsById: workspaceGroupById)
```

If upstream restructures the sidebar, the requirements are: render `SupermuxProjectsMount()` once
at the top of the scrollable workspace list, and feed the flat-list row builder
`SupermuxMainListFilter.tabsForMainList(tabs)` instead of the raw `tabs` (a no-op when no
projects are registered; `tabManager.tabs` itself is never filtered).

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

Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `73`.

### 4. `.github/swift-file-length-budget.tsv` — unfenced

Several rows carry supermux's fenced growth over upstream. Each was raised by exactly the
number of fenced lines added to that file — never to absorb unrelated debt:

| Row | Δ | Reason |
|-----|---|--------|
| `Sources/ContentView.swift` | +9, +14, +28, +26, +19 | `sidebar-projects-section` mount (+3) and `sidebar-hide-project-workspaces` filter (+6); `sidebar-selection-faint` (+14: faint-tint `backgroundColor` + `usesInvertedActiveForeground` overrides); `sidebar-projects-empty-area` (+28: `@State` height + empty-area subtraction + `.onPreferenceChange` handler, 19311→19339). Budget also absorbed a pre-existing 2-line drift (HEAD file was 19297 vs a 19295 budget). `empty-home` (+26: `SupermuxEmptyHomeView` mount in `terminalContent`, the startup-recovery auto-add suppression, and clearing the titlebar title on empty, 16751→16777); `sidebar-hide-scrollbar` (+19: replaces the one-line `applySidebarOverlayScrollerConfiguration()` call in `configureSidebarScrollView` with the inlined hidden-scroller config and folds the now-stale upstream overlay-scroller doc comment into the fence; plus `.scrollIndicators(.hidden)` on both sidebar `ScrollView`s — workspace list and extension-provider list — so SwiftUI does not re-assert the scroller, 16236→16255) |
| `Sources/TabManager.swift` | +25, +28 | `new-workspace-standalone` (+25: `markStandalone` call in `addWorkspace`, the central close-path `forget` cleanup, and the `forget` clear in `restoreClosedWorkspace` so reopened project workspaces re-nest); `keep-window-on-last-close` (+28: `allowEmptyingWindow` param/guard, selection-to-`nil`, the three last-workspace close sites + bulk short-circuit/plan, the child-exit path, close-confirmation metadata cleanup, and failed closed-workspace restore cleanup, 6116→6169) |
| `cmuxTests/TabManagerUnitTests.swift` | +69 | `keep-window-on-last-close` (repurposed `testChildExitOnLastWorkspaceKeepsWindowOpenAsEmptyHome`, updated all-workspaces confirmation copy expectations, two new empty-home close tests, and failed restore cleanup coverage, 3926→3995) |
| `Sources/WorkspaceContentView.swift` | +12 | `presets-bar` mount above the splits (if/else branch on minimal mode) |
| `Sources/RightSidebarPanelView.swift` | +18, +35, +3 | `right-sidebar-changes-mode-*` (case/label/symbol/shortcut/rootsync/content, +18); `right-sidebar-compact-mode-bar` (+35: `ViewThatFits` wrapper with pinned trailing controls + `modeButtonsRow(showsLabels:)` helper + `showsLabel` pill param/conditional, 743→778); `right-sidebar-changes-mode-content` (+3: `SupermuxChangesMount` now also passes `isVisible: fileExplorerState.isVisible`, 778→781) |
| `Sources/RightSidebarToolPanel.swift` | (within budget) | `.changes` added to 4 existing case groups |
| `Sources/MainWindowFocusController.swift` | +10 | changes-mode focus routing |
| `Sources/KeyboardShortcutSettings.swift` | +13, +18, +4, +22 | `supermuxToggleRun` action (+13); `workspace-switcher-shortcut-*` (+18: case/label/default for the two switcher actions, 2586→2604); `toggle-split-zoom-rebind` (+4: fence + comment around the rebound default, 2604→2608); `supermux-commit-shortcut` (+22: case/label/default for the two commit actions, 2608→2630) |
| `cmuxTests/KeyboardShortcutContextTests.swift` | +2 | `toggle-split-zoom-rebind` (fence around the updated rationale comment, 688→690) |
| `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | +6 | `toggle-split-zoom-rebind` (fences around the two browser zoom round-trip tests, 1677→1683) |
| `Sources/AppDelegate.swift` | +10, +10 | `run-toggle-shortcut-dispatch` (+10); `workspace-switcher-monitor` (+10, 17788→17798) |
| `Sources/App/ShortcutRoutingSupport.swift` | +11, +5 | `run-toggle-shortcut-dispatch` (⌘G never browser-first); `toggle-split-zoom-rebind` (+5: fenced comment correcting the stale Toggle Pane Zoom reference, 945→950) |
| `cmuxTests/AppDelegateShortcutRoutingTests.swift` | +32, +26 | `run-toggle-shortcut-dispatch` (contract update + regression test); `toggle-split-zoom-rebind` (+26: fenced `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback`, 12078→12104) |
| `Sources/GhosttyTerminalView.swift` | +16 | `ghostty-unbind-split-zoom-return` (fenced second `loadInlineGhosttyConfig` unbinding `super+shift+enter`, 12105→12121) |
| `CLI/cmux.swift` | +4 | `changes` CLI mode |
| `Sources/FileExplorerView.swift` | +14, +6 | `file-explorer-operations` (+3: end-of-menu call), `file-explorer-operations-empty` (+5: empty-area `else` block adding root New File/Folder), `file-explorer-operations-keys` (+6: ⌘⌫/Return hook in the outline `keyDown`), 2355→2369; `file-explorer-operations-reveal` (+6: scroll-into-view hook in `reloadIfNeeded`, 2369→2375) |
| `Sources/FileExplorerStore.swift` | +17, +14 | `file-explorer-operations-reveal` (`supermuxRevealPath` property + `supermuxReveal(path:)` method, 1446→1463; then `supermuxClearSelection()` + the `setRootPath` reveal-flag clear, 1463→1477) |
| `Sources/DragOverlayRoutingPolicy.swift` | (no tsv row — under the 500-line floor) | `browser-hover-drag-guard` (+14: injectable `pressedMouseButtons` parameter + pointerHover pressed-button guard, 385→399) |
| `Sources/Panels/BrowserPanelView.swift` | +48 | `browser-hover-webkit-topmost-gate` (anchor `portalHoverHitTestWebView` + `portalHoverDelegationTarget(at:routingContext:)` + `hitTest` delegation hook, and the `updateNSView` wiring, 7986→8034) |
| `cmuxTests/PortalTabDragRoutingTests.swift` | +120 | `browser-hover-drag-guard` + `browser-hover-webkit-topmost-gate` regression tests (594→714) |

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

`WorkspaceContentView.body` returns the workspace's `bonsplitView`. The fence
wraps that return so the presets bar renders once per workspace, above the
splits, in normal mode only:

```swift
// SUPERMUX:begin presets-bar
if isMinimalMode {
    bonsplitView
        .ignoresSafeArea(.container, edges: isFullScreen ? [] : .top)
} else {
    VStack(spacing: 0) {
        SupermuxPresetsBarMount(workspace: workspace)
        bonsplitView
    }
}
// SUPERMUX:end presets-bar
```

The minimal-mode branch reproduces upstream's original
`bonsplitView.ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])`
exactly (it's only reached when `isMinimalMode` is true). If upstream
restructures this view, the requirement is: render `SupermuxPresetsBarMount`
once above the split container for normal-mode workspaces, and leave minimal
mode's top-safe-area-ignoring layout untouched.

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

**25. `web/data/cmux-shortcuts.ts` — `workspace-switcher-shortcut-doc`.** Two registry rows after
the run-toggle doc fence, documenting ⌘\` (cycle) and ⇧⌘\` (reverse). Pair with the
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
  `loadCmuxOwnedGhosttyKeybindOverrides` adds `keybind = super+shift+enter=unbind` (prefix
  `supermux-owned-keybind-overrides`). `super+shift+enter` parses to the physical Enter trigger,
  exactly matching the default binding, and Ghostty's `unbind` removes it (`Binding.zig`), after
  which the chord falls through to the SwiftUI accelerator. If upstream adds the equalize/zoom
  unbinds itself, drop this fence; if it changes the zoom trigger, mirror the new trigger here.
- **35. `Sources/App/ShortcutRoutingSupport.swift`:** a fenced comment in
  `shouldDispatchBrowserReturnViaFirstResponderKeyDown` no longer cites Toggle Pane Zoom as the
  example Command-Return app shortcut (it is ⌃⌘Z now, not Return-based); it notes ⇧⌘↩ is the
  Changes-panel commit accelerator. Comment-only — the routing logic is unchanged.
- **36. `cmuxTests/AppDelegateShortcutRoutingTests.swift`:** a fenced regression test,
  `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback`, asserts the loaded Ghostty config has no
  `super+shift+enter` binding (via the same `ghosttyConfigKeyIsBinding` helper as the #5189
  numbered-fallback test). Red without #34, green with it.

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
conflict warning. Budget bump for #37 is in the #4 table; #38 (a small test file) is not
budget-tracked.

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
if fileExplorerCoordinator?.handleSupermuxFileOperationKey(event, in: self) == true {
    return
}
// SUPERMUX:end file-explorer-operations-keys
```

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
  `store.supermuxReveal(path: created/renamed.path)` before the reload.
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
  If upstream restructures the store/reload, the requirement is: after a file op, select the new
  path and scroll it into view once its row loads.

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

   The explicit window-close paths (red button / ⌘⇧W / `closeWindow`) are intentionally left as
   upstream — closing the *window* still quits on the last window; only closing the last *tab*
   keeps it open.

**`Sources/ContentView.swift` (`empty-home`):** `terminalContent` renders `SupermuxEmptyHomeView`
(centered "No open tabs" hint) inside the existing `ZStack` when `tabManager.tabs.isEmpty`, gated
to the `.tabs` sidebar surface and non-interactive. The one-shot startup recovery's upstream
`if tabManager.tabs.isEmpty { addWorkspace() }` block is suppressed, because zero workspaces is a
valid supermux runtime state and the delayed recovery could otherwise refill a window the user had
intentionally emptied.

**`cmuxTests/TabManagerUnitTests.swift` (`keep-window-on-last-close`):** the child-exit
window-close test is repurposed to assert the window stays open (no close request, tabs empty,
selection `nil`), all-workspace close confirmation expectations now use "Close workspaces?", plus
two new tests cover `closeWorkspace(allowEmptyingWindow:)` emptying the window and the plain close
still keeping the last workspace. `testFailedClosedWorkspaceRestoreFromEmptyHomeCleansUpTemporaryWorkspace`
covers cubic's review finding that failed closed-workspace restore cleanup must not leave a
temporary workspace behind when reopening from empty home.

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

### 56. `Sources/DragOverlayRoutingPolicy.swift` — `browser-hover-drag-guard`

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
`testBrowserPortalDoesNotPassHoverThroughWithoutPressedMouseButton` (see #58).

### 57–58. `Sources/Panels/BrowserPanelView.swift` + tests — `browser-hover-webkit-topmost-gate`

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

1. In `WebViewRepresentable.HostContainerView`: a `weak var portalHoverHitTestWebView: WKWebView?`
   plus `portalHoverDelegationTarget(at:routingContext:)`, which returns the hosted page web view
   (or the docked DevTools frontend, `hostedInspectorFrontendWebView`) when the routing context is
   `.pointerHover`, the web view is hosted in the same window, and the point maps inside its
   bounds; `hitTest` consults it after the sidebar-resizer and hosted-inspector-divider branches,
   before `super.hitTest`. Only hover-kind events are delegated — real event routing (clicks,
   drags, scroll) is handled by the portal host above the contentView and never consults the
   anchor. The `routingContext` parameter defaults to `WindowInputRoutingContext(event:
   NSApp.currentEvent)` and exists so tests can inject a hover context.
2. In `WebViewRepresentable.updateNSView`: one line keeping `portalHoverHitTestWebView` pointed
   at the panel's current web view.

If upstream restructures the anchor or the portal, the requirement is: a hit test rooted at
`window.contentView` over visible browser page area must resolve to the hosted `WKWebView` (or a
descendant) for hover-kind events. Regression test: `cmuxTests/PortalTabDragRoutingTests.swift` →
`testBrowserAnchorDelegatesHoverHitTestToPortalHostedWebView` (fenced, see #58).
