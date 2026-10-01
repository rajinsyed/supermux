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
- Numbering: the highest number in use is **689**. The remote-workspaces work (#517–#599) left
  unassigned gaps it may still grow into: **523–524, 527–529, 539–544, 558–559, 562–569,
  578–579 and 588–589** (never assigned, not retired); #600–#601 came from the 2026-10-01 upstream merge; #620–#622 and
  #630–#639 are the remote-workspaces feedback round (602–619 and 623–629 unassigned). The second
  feedback round uses #640–#644 (busy mirror tab close), #650–#653 (mirror appearance), #660–#664
  (new tabs append), #665–#670 (terminal size preference) and #675–#681 (a mirror's Files panel);
  its stabilization uses #682–#684 (preview refresh and its alert) and #685–#686 (replayed mouse modes); its second review and visual check use #687–#689 (mirror placeholders after a relaunch, Mac wording, a cancelled close's selection);
  645–649, 654–659, 671–674 are unassigned. Number **351** is unused (the notifications
  redesign started at 352; the pane-unread family uses 386–396 to avoid the mobile-usage
  touchpoints at #340/#340b/#341). Numbers **4, 19, 52, 82, 83, 89, 106, 121, 142, 213, 214,
  220, 229, 237, 250, 251, 252–258, 335, 470, 473–481, 483, 484, and 487** are unused; all are
  documented as RETIRED below except **#19**, which was never assigned (the table jumps #18 →
  #20). The 2026-08-24 upstream merge retired #213/#214, #229/#237, #250, and #252–258; the
  2026-09-30 upstream merge retired #82/#83, #220, #251, #335, #470, #473–481, #483/#484, and
  #487. Do not reuse any of them. Numbers **134** and **135** are each used
  **twice** (`RemoteTmuxMirrorCloseDetachTests` / `ClaudeHookLiveDeliveryTargetTestSupport` and
  two `lint-allow-upstream-debt` rows) — a pre-existing collision, deliberately left as-is so
  existing cross-references keep resolving. Do not reuse them, and do not renumber. Letter
  suffixes (`4b`, `33b`, `62b`) keep a new row adjacent to its family without renumbering.

## Registry

| # | File | Fence id | What it does |
|---|------|----------|--------------|
| 1 | `CLAUDE.md` | `claude-md-pointer` | Points agents at SUPERMUX.md before they work in this repo |
| 244 | `CLAUDE.md` | `ios-dogfood-release-build` | Overrides upstream's "iOS builds open on the iPhone by default" section for this fork: `reload.sh --tag` ships a tagged DEV build the user cannot sign in to, so physical-phone dogfood uses a Release build with `CMUX_DEV_TAG=` empty and `CMUX_IOS_AUTH_ENV=production`. Records the exact invocation — the FIXED dogfood bundle id `com.supermux.ios.dogfood` (one persistent identity so sign-in/pairing survive across tags; per-tag `dev.cmux.ios.<tag>` is retired, and keychain-group sharing with the main install is forbidden — Iroh stores would mutually wipe), `SUPERMUX_IOS_DISPLAY_SUFFIX=" <tag>"`, the sanctioned per-build naming knob (#238/#239) — and the two overrides never to pass on it (`PRODUCT_DISPLAY_NAME`, `ASSETCATALOG_COMPILER_APPICON_NAME`). Since the 2026-09-30 upstream merge upstream's CLAUDE.md is a short index, so this is a self-contained `##` section ("Supermux: phone dogfood…") after "Area instructions"; it overrides the "iOS builds open on the iPhone by default" section upstream moved to `ios/AGENTS.md` |
| 2 | `Sources/ContentView.swift` | `sidebar-projects-section`, `sidebar-hide-project-workspaces`, `sidebar-flatrow-activity`, `sidebar-selection-faint`, `sidebar-unified-row-style`, `sidebar-projects-empty-area` | Mounts `SupermuxProjectsMount()` atop the sidebar; hides project-owned workspaces from the flat list and threads a `projectHiddenWorkspaceIds` set through `WorkspaceListRenderContext` — shift-click ranges (`selectWorkspaceRow`) and the actions-bundle Close Other/Below/Above closures exclude project-hidden workspaces (via a fenced parent-level `supermuxProjectHiddenWorkspaceIds()` helper — since upstream's 0.65 snapshot-boundary refactor moved row actions from `TabItemView` to the sidebar owner, the fenced logic lives in those parent functions; Move Up/Down stepping lives in the SHARED entrypoint, #131, so `moveWorkspaceRow` is back to the upstream one-liner), the actions bundle gets a fenced `supermuxMenuVisibility` provider (keyed by workspace id; consumed by #114, declared in #129, move enablement via the #131 stepped-plan check) so the four Move/Close menu items disable on real reachability instead of raw full-list indices, a fenced `.onChange` strips newly project-hidden ids from `selectedTabIds`, the row-input construction computes fenced `supermuxVisibleIndex`/`supermuxVisibleCount` (#132/#133) and the `workspaceSnapshot.accessibilityLabel(index:workspaceCount:)` call site in `TabItemView.body` passes `supermuxVisibleIndex`/`supermuxVisibleCount` so it announces "workspace N of M" against the visible list (upstream moved the label builder into `SidebarWorkspaceSnapshotBuilder.Snapshot`); renders the agent-activity indicator on flat-list workspace rows (indicator overlay in `TabItemView`; snapshot resolution moved to #128); gives the flat-list selection the faint accent tint used by nested project rows in a fence at the top of `backgroundStyle(for:isEmphasized:)` (returns a `SidebarWorkspaceRowBackgroundStyle` at opacity 0.16 with no `edgeColor`, so upstream's subtle-selection hairline never draws on the active row; honoring `sidebarSelectionColorHex` — the user hue at 0.16 opacity — before falling back to `accentColor`); restyles the flat-list row to the nested project-workspace design (`sidebar-unified-row-style`: 11.5·scale title semibold-only-when-selected, spacing-2 line stack, vertical padding 4 at the row's padding site, corner radius 5 and hover tint primary@0.06 via `isPointerHovering` in a fence at the top of `rowBackgroundShape`); subtracts the Projects-section height from the empty-area remainder so the sidebar's empty space stays unscrollable. Since the 2026-09-30 upstream merge the `renderItems(tabs: mainListTabs …)` argument is its own small fence, with upstream's `orderedGroups:`/`effectiveMembership:` (computed over the FULL `tabs`) passed through; the fenced `supermuxMenuVisibility:` stays after upstream's `onPointerDragEligibilityChange:` actions arg; the flat-row spinner fence adds `&& workspaceSnapshot.supermuxActivity != .working` to upstream's compact-agent-status code |
| 3 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the SupermuxKit package + `Sources/Supermux/` files (incl. `SupermuxRowMenuVisibility.swift`, ids `…00F9`/`…00FA`, `SupermuxWorkspaceReorderStepping.swift`, ids `…00FB`/`…00FC`, `SupermuxDirectPhonePush.swift`, ids `…0103`/`…0104`, `SupermuxFocusedPaneNotificationPolicy.swift`, ids `…0142`/`…0143`, `SupermuxChangesPullRequestSupport.swift`, ids `…0144`/`…0145`, `SupermuxFileDiffOpener.swift`, ids `…0146`/`…0147`, and `SupermuxMobileHost+Agent.swift`, ids `50BE0002…00E3`/`…00E4`) into the cmux target, `cmuxTests/SupermuxSidebarBranchTests.swift` + `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` + `cmuxTests/SupermuxSidebarAgentStatusRowsTests.swift` + `cmuxTests/SupermuxFocusedPaneNotificationTests.swift` into the cmuxTests target, (upstream now links `CMUXAuthCore` and `CmuxAuthRuntime` into cmuxTests itself — `A9994001…`/`A9994002…` — so the fork's duplicate `F10000A1…`/`F10000A2…` build files were dropped at the 2026-09-30 upstream merge), and the three `AppIcon*.icon` Icon Composer files into the app Resources phase (see #17; the SupermuxMobile package/test wiring in this file is registered separately as #95) |
| 4b | `Resources/Localizable.xcstrings` | `unfenced` | Adds en+ja entries for all `supermux.*` keys (additive only; never edits non-supermux keys — sole exception, for the #80 fork behavior: the en+ja values of `settings.search.alias.setting.app.workspace-inherit-working-directory` (#84) are rewritten; the former `…subtitleOff` exception retired with #82 at the 2026-09-30 upstream merge, when upstream replaced the ON/OFF subtitle pair with one fixed `…subtitle` key) |
| 5 | `Sources/RightSidebarPanelView.swift` | `right-sidebar-changes-mode-*`, `right-sidebar-compact-mode-bar` | Renders `SupermuxChangesMount` for the `changes` mode (`-content`, after upstream's `.machines` → `MachinesPanelView` arm) and syncs its root (`-rootsync`: `case .sessions, .feed, .dock, .machines, .changes, .customSidebar:`); the case/label/symbol/shortcut fences moved to #498 when upstream extracted the `RightSidebarMode` enum into `Sources/RightSidebarMode.swift`. `right-sidebar-compact-mode-bar` wraps the mode-bar controls in `ViewThatFits` so the mode buttons collapse to icon-only when the sidebar is narrow (keeps the close button visible down to the lowered min width), with a third fallback putting the icon-only row in a horizontal `ScrollView` so mode buttons scroll instead of clipping at extreme narrowness; the fenced `modeButtonsRow(showsLabels:)` also carries upstream's `.onDrag`/`.onDrop` tab-reorder modifiers (`RightSidebarModeBarDropDelegate`), and upstream's `.contextMenu { tabCustomizationMenu }` and the `isAvailable()` open-as-pane guard are kept. `right-sidebar-changes-mode-focushost` mounts `SupermuxChangesFocusHostBridge`/`SupermuxChangesFocusHostView` as the changes panel's background, registering a geometry-based focus host with the window's `MainWindowFocusController` |
| 6 | `Sources/RightSidebarMode+Availability.swift` | `right-sidebar-changes-mode-*` | `changes` is always available and reachable from the CLI mode argument. The fork's `"changes"` CLI arm sits beside upstream's `cloud/machines/vms`, `devices/device/macs` and `custom/custom-sidebar` arms; the `-available` fence lives in upstream's `isAvailable(feedEnabled:machinesEnabled:devicesEnabled:)` |
| 7 | `Sources/RightSidebarToolPanel.swift` | `right-sidebar-changes-mode-*` | `.changes` joins upstream's no-op groups, which now read `.feed, .dock, .machines, .changes, .customSidebar` (sync/focus/intent/anchor, ×4); in the view switch upstream's `.machines` → `MachinesPanelView` arm precedes the fenced no-op arm |
| 8 | `Sources/MainWindowFocusController.swift` | `right-sidebar-changes-mode-*` | Focus routing for the changes mode; the `right-sidebar-changes-mode-focushost` fences add a weak `changesHost` + `registerChangesHost(_:)` and changes-ownership checks in `ownsRightSidebarFocus`/`rightSidebarModeOwning`, so commit-field focus maps to the `.changes` intent and the hide path restores terminal focus. The fenced case list also includes upstream's `.machines` mode |
| 9 | `Sources/ContentView+RightSidebarCommandPalette.swift` | `right-sidebar-changes-mode-*` | Palette command id for "Show Changes"; not openable as a pane. Upstream's `.machines` show-id / pane-id / pane-title arms (`palette.openCloudPane`, "Open Cloud as Pane") precede the fork's `.feed, .dock, .changes, .customSidebar` fences |
| 10 | `CLI/cmux.swift` | `right-sidebar-changes-mode-*` | CLI accepts `cmux right-sidebar set changes` (and the `changes` alias). The alias fence holds upstream's full list (`cloud, machines, devices, custom, custom-sidebar`) plus `"changes"`. Separately (unfenced string edits), the per-command `new-surface` help here lists `claude-harness`; the top-level `usage()` moved to `CLI/CMUXCLI+TaskHelp.swift` (#506) |
| 11 | `Sources/KeyboardShortcutSettings.swift` | `run-toggle-shortcut-*` | `supermuxToggleRun` action (case/label/default ⌘G, shared with Find Next) |
| 12 | `Sources/AppDelegate.swift` | `run-toggle-shortcut-*` | ⌘G dispatch: Find Next while find overlay is open, run toggle otherwise; auto-repeat key events are excluded from the run toggle |
| 13 | `scripts/ci/package-test-lane.sh` | `ci-package-tests` | Adds a fenced loop at the end of `run_package_tests` (after upstream's selected-package loop, before the results table) that runs `swift test` for `Packages/SupermuxKit`, `Packages/Shared/SupermuxMobileCore`, `Packages/iOS/SupermuxMobileKit` and `Packages/iOS/SupermuxMobileUI` on every lane run, feeding the same summary/failure accounting. Upstream split `ci.yml` into reusable workflows and lane scripts at the 2026-09-30 upstream merge, so the fence moved here out of `ci.yml`. The fork packages run only when upstream's `swift-package-tests` lane runs (full suite, or a routed upstream-package change): a PR touching only a fork package no longer routes the lane on pull requests, because upstream's selector only knows packages in its own `PACKAGES` list. The router parses that array with a regex, so never put comments inside it |
| 14 | `web/data/cmux.schema.json` | `unfenced` | Adds all six supermux ids — `supermuxToggleRun`, `supermuxWorkspaceSwitcherNext`, `supermuxWorkspaceSwitcherPrevious`, `supermuxCommit`, `supermuxCommitAccelerator`, and `supermuxNewClaudeHarness` — to the shortcut-action enum so cmux.json validation accepts rebinding them; also rewrites the `workspaceInheritWorkingDirectory` description for the #80 fork behavior (off = always home directory) and gives it a `descriptionKey` (`schemaDescriptions.app.workspaceInheritWorkingDirectory`, messages under #86/#87) so the docs page localizes it |
| 15 | `web/data/cmux-shortcuts.ts` | `run-toggle-shortcut-doc` | Documents the `supermuxToggleRun` ⌘G shortcut in the keyboard-shortcut registry |
| 16 | `Sources/WorkspaceContentView.swift` | `presets-bar` | Renders `SupermuxPresetsBarMount(workspace:)` above the splits inside a single `VStack` wrapper that keeps upstream's `WorkspaceContentMinimalModeSafeAreaModifier` — one structural identity. The minimal-mode hide moved INTO the supermux-owned mount (v0.64.19 merge): upstream's `WorkspaceContentViewVisibilityTests` asserts mode toggles re-evaluate neither `ContentView` nor `WorkspaceContentView` bodies, so the fence must not read the presentation mode. Since the 2026-09-30 upstream merge upstream's `.overlay { CloudSurfaceDropGate }` attaches to the fork's `workspaceContent` Group (the splits, not the presets bar), and upstream's `.modifier(CloudPaneCreationFailurePresentation)` sits after `// SUPERMUX:end presets-bar`, applied to the fork's VStack |
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + byte-identical `AppIcon-Debug.icon` + `AppIcon-Nightly.icon` (no DEV/NIGHTLY bands — all three channels share one mark); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered icon. macOS wiring lives in touchpoint #3; iOS renders from the same bundles via #241, and `AppIcon-Demo.icon` (iOS demo lane only) is a fourth sibling. |
| 18 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) and, right after it inside the same body fence, `SupermuxRemoteMacsSettingsCard(hostActions: hostActions)` (the Remote Macs card, #596; `hostActions` is upstream's own stored property) at the end of the Automation section, and stores the `secretStore` + `errorLog` the AI card needs. The card itself is a new supermux-owned file, `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). **Upstream relocated this package under `Packages/macOS/`; the new card moved with it (git rename detection placed it at the new path).** |
| 20 | `Sources/Workspace+TerminalLinkOpening.swift` | `browser-link-new-tab` | When a Command-clicked terminal link — a web URL, or a local `.html`/`.htm` file routed through `Sources/TerminalHTMLFileBrowserAction.swift` — opens in the embedded browser and there is no existing right-side browser pane to reuse, open it as a new browser tab in the current pane (and switch to it) instead of creating a horizontal split. Upstream (0.65) deleted `GhosttyTerminalView.openEmbeddedBrowserLink(...)` and replaced it with the `TerminalLinkOpenContainer` protocol; the fence moved into `Workspace.openTerminalBrowserLink(url:sourcePanelId:)`. The SECOND conformance, `Sources/DockSplitStore+TerminalLinkOpening.swift`, is deliberately NOT fenced (known deviation — dock terminals keep upstream's split fallback) |
| 21 | `Sources/App/ShortcutRoutingSupport.swift` | `run-toggle-shortcut-dispatch` | ⌘G (the supermux Run/Stop toggle, shared with Find Next) is never ceded to a focused browser's native find, so cmux always owns the chord (otherwise WebKit swallows ⌘G and it is a dead key in the browser) |
| 22 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `run-toggle-shortcut-dispatch` | Updates the browser-find routing contract for ⌘G (run-toggle chord excluded from browser-first routing) and adds the regression test |
| 23 | `Sources/KeyboardShortcutSettings.swift` | `workspace-switcher-shortcut-case`, `workspace-switcher-shortcut-label`, `workspace-switcher-shortcut-default` | Adds the two workspace-switcher shortcut actions: `supermuxWorkspaceSwitcherNext` (default ⌘\`) and `supermuxWorkspaceSwitcherPrevious` (default ⇧⌘\`) |
| 24 | `Sources/AppDelegate.swift` | `workspace-switcher-monitor` | One hook in the app-local NSEvent monitor routes every event to `SupermuxComposition.workspaceSwitcher.handleMonitorEvent(_:appDelegate:)`: idle it acts only on the open chord; while presented it owns keyDown/keyUp/flagsChanged so it can cycle and commit on ⌘ release |
| 25 | `web/data/cmux-shortcuts.ts` | `workspace-switcher-shortcut-doc` | Documents the two workspace-switcher shortcuts in the keyboard-shortcut registry (in the Workspaces section, after `prevSidebarTab`) |
| 26 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` | `right-sidebar-min-width` | Lowers the right-sidebar minimum width floor from upstream's 276 to 200 so the panel can be dragged narrower (mode bar collapses to icon-only via touchpoint #5). **Upstream relocated this package under `Packages/macOS/` (cmux package reorg).** |
| 27 | `cmuxTests/SidebarWidthPolicyTests.swift` | `right-sidebar-min-width-test` | Two right-sidebar clamp assertions read `RightSidebarWidthSettings.minimumWidth` instead of the hardcoded `276`, so they track the lowered floor. Since the 2026-10-01 upstream merge the file is Swift Testing (`@Test`/`#expect`): the two clamp expectations subtract `CGFloat(RightSidebarWidthSettings.minimumWidth)` inside the fence, and the fork's below-legacy-floor case is a fenced `@Test` (`rightSidebarClampAllowsWidthBelowLegacyFloor`) |
| 28 | `Sources/KeyboardShortcutSettings.swift` | `toggle-split-zoom-rebind` | Rebinds the `toggleSplitZoom` default from ⇧⌘↩ to ⌃⌘Z (canonical table) so ⇧⌘↩ is free for the supermux Changes-panel commit accelerator. Sits right after upstream's new `.newPaneAutoLayout` (⌃⌘N) default |
| 29 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `toggle-split-zoom-rebind` | Mirror of the rebound ⌃⌘Z default for the settings-UI package. **Upstream relocated this package under `Packages/macOS/`** (the old `Packages/CmuxSettings/…` path in the re-apply prose was stale). Upstream moved the table into `builtInDefaultStroke` (front door `defaultStroke(using: ShortcutDefaultResolver)`) and added `newPaneAutoLayout` ⌃⌘N right before `toggleSplitZoom`; the fork arms sit inside `builtInDefaultStroke` |
| 30 | `web/data/cmux-shortcuts.ts` | `toggle-split-zoom-rebind` | Documents Toggle Pane Zoom as ⌃⌘Z in the keyboard-shortcut registry |
| 31 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `toggle-split-zoom-rebind` | The split-zoom shortcut test drives the configured default, so it presses ⌃⌘Z (was ⇧⌘↩). **This file is Swift Testing since 0.65** (`@Suite(.serialized) @MainActor final class`, no `: XCTestCase`, no `import XCTest`, file-private `XCTAssert*` shims forwarding to `#expect`) — the fenced test MUST carry `@Test` or it silently stops running with green CI |
| 32 | `cmuxTests/KeyboardShortcutContextTests.swift` | `toggle-split-zoom-rebind` | Comment accuracy: toggleSplitZoom is no longer the Return-based shortcut (now ⌃⌘Z); assertions unchanged |
| 33 | `cmuxUITests/BrowserPaneNavigationKeybindUITests.swift` | `toggle-split-zoom-rebind` | Two browser zoom round-trip UI tests press ⌃⌘Z instead of ⇧⌘↩. The file now builds its app with upstream's `XCUIApplication.cmuxTestApplication()` helper, not bare `XCUIApplication()` |
| 33b | `cmuxTests/AppDelegateSurfaceShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Seventh `toggle-split-zoom-rebind` site in the #28–33b sequence (the id appears in nine files tree-wide once #35/#36 are counted), never registered before the 0.65 merge: `cmdControlZInCanvasModeDoesNotToggleBonsplitSplitZoom` (upstream: `cmdShiftReturnInCanvasModeDoesNotToggleBonsplitSplitZoom`) presses ⌃⌘Z (`key: "z", modifiers: [.command, .control], keyCode: 6`) because `withTemporaryShortcut(action: .toggleSplitZoom)` installs the action's CONFIGURED default, which the fork rebound. Swift Testing (`@Test`) — same silent-skip hazard as #31 |
| 34 | `Sources/GhosttyApp+KeybindOverrides.swift` | `ghostty-unbind-split-zoom-return` | Unbinds Ghostty's built-ins `super+shift+enter = toggle_split_zoom` **and** `super+enter = toggle_fullscreen` so the freed ⇧⌘↩ / ⌘↩ actually reach the Changes-panel commit shortcuts in a focused terminal (without them the rebind is incomplete — same class as the numbered-tab unbinds, #5189). Upstream moved `loadCmuxOwnedGhosttyKeybindOverrides` and `numberedWorkspaceGhosttyUnbinds` out of `GhosttyTerminalView.swift` into this file at the 2026-09-30 upstream merge; the fence (a second `loadInlineGhosttyConfig`, prefix `supermux-owned-keybind-overrides`) sits at the end of `loadCmuxOwnedGhosttyKeybindOverrides`. Upstream's new `loadGhosttyHostKeybindDefaults` already unbinds `super+enter` before user config; the fork line is redundant for defaults but still overrides a user binding, and `super+shift+enter` is unbound only by the fork |
| 35 | `Sources/App/ShortcutRoutingSupport.swift` | `toggle-split-zoom-rebind` | Comment accuracy: the browser-Return rule no longer cites Toggle Pane Zoom as the Command-Return app shortcut (now ⌃⌘Z); notes ⇧⌘↩ is the commit accelerator. Logic unchanged |
| 36 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `toggle-split-zoom-rebind` | Regression test `testGhosttyConfigDoesNotRetainSplitZoomReturnFallback` asserts the loaded Ghostty config has no `super+shift+enter` binding (companion to the #5189 numbered-fallback test) |
| 37 | `Sources/KeyboardShortcutSettings.swift` | `supermux-commit-shortcut-case`, `supermux-commit-shortcut-label`, `supermux-commit-shortcut-default` | Registers the Changes-panel `supermuxCommit` (⌘↩) and `supermuxCommitAccelerator` (⇧⌘↩) actions (case/label/default) so both are editable in Settings, live in `cmux.json`, and participate in conflict detection; applied by the panel's SwiftUI buttons (read via `SupermuxChangesMount`), not the app monitor. Settings visibility/conflict detection is actually delivered by the settings-package enum registration (#62/#63) |
| 38 | `cmuxTests/AppDelegateEqualizeSplitsShortcutTests.swift` | `supermux-commit-shortcut` | `testSupermuxCommitDefaultsBindReturnChords` asserts the two commit actions default to ⌘↩ / ⇧⌘↩ and do not cross-match |
| 39 | `Sources/FileExplorerView.swift` | `file-explorer-operations`, `file-explorer-operations-empty`, `file-explorer-operations-reveal` | Adds file-management to the right-sidebar file tree (local provider only): context-menu items New File/New Folder/Rename/Duplicate/Move to Trash on a clicked node, New File/New Folder on the empty area (root); the `-reveal` fence scrolls a just-created/renamed item into view after the reload. Keyboard handling (`file-explorer-operations-keys`) moved to #46 when upstream extracted the outline-view subclass into its own file (cmux #6001). All logic lives in supermux-owned files (`Sources/Supermux/SupermuxFileExplorerCommands.swift`, `SupermuxFileExplorerPrompt.swift`) and `Packages/SupermuxKit/Sources/SupermuxKit/SupermuxFileSystemOperations.swift`; the fences are one-line calls into a `FileExplorerPanelView.Coordinator` extension |
| 40 | `Sources/FileExplorerStore.swift` | `file-explorer-operations-reveal` | Adds `supermuxRevealPath` + `supermuxReveal(path:)` to `FileExplorerStore` so a supermux file operation can select a just-created/renamed item by path (the selection state is `private(set)`, so this must live in the store's own file). The store fence also carries `var supermuxRevealRequestedAt: Date?` (set in `supermuxReveal`, cleared in `supermuxClearSelection`) used by the coordinator to expire a reveal after 10s, and two minimal same-id fences in `select(node:)` and `select(nodes:anchor:)` clear `supermuxRevealPath` when the selection moves to a different path. Paired with the coordinator's `-reveal` hook in touchpoint #39. In `setRootPath` the fenced `supermuxRevealPath = nil` precedes upstream's new `resourceContextID = UUID()` |
| 41 | `Sources/TabManager.swift` | `new-workspace-standalone` | Marks every workspace created through cmux's normal new-workspace flow (`+` / ⌘T / surface tab bar) as standalone (`SupermuxWorkspaceAssociationStore.markStandalone` in `addWorkspaceIfActive` — upstream's replacement for `addWorkspace`, which is now a deprecated trapping wrapper) so it lands at the root of the flat list, never nested under the focused project. The project opener clears it via `associate`; the central close path clears it via `forget`. `restoreClosedWorkspace` (reopen) goes through `guard let … = addWorkspaceIfActive(…) else { return false }` too, so it explicitly `forget`s the mark afterwards to re-nest by directory; **session**-restore builds `Workspace` objects directly and is unaffected. `releaseRestoredAwayWorkspace` `forget`s each released pre-restore workspace after upstream's `workspace.retireFromOwningTabManager()` (it never reaches the central close path; the restored replacement re-nests by directory) |
| 42 | `Sources/TabManager+DetachedWorkspace.swift` | `new-workspace-standalone` | The detached-surface path (move-tab / move-surface to a new workspace) builds a `Workspace` directly, not via `addWorkspace`, so it marks the new workspace standalone too — a moved-out surface becomes a root-level workspace, never nested under a project whose directory it inherited. The fence precedes upstream's new `normalizedCustomTitle` / `repairInitialTabTitle` block |
| 43 | `Sources/TabManager.swift` | `keep-window-on-last-close` | Keeps the window open as an empty home when the last workspace closes — instead of `window.performClose`, which quit the app on the last window. `closeWorkspace(allowEmptyingWindow:)` removes the final workspace (selection clears to `nil`); the two surviving last-workspace close sites (`closeWorkspaceIfRunningProcess`, `closePanelAfterChildExited` — upstream deleted the bulk-close anchor branch at 0.65) + the bulk-close short-circuit/plan route through it, failed closed-workspace restore cleanup can empty the window again, and close confirmations no longer mark last-workspace closes as window-closing. Also fenced: `detachWorkspace` leaves the source window empty (`selectedTabId = nil`) when its last workspace moves to another window instead of upstream's `recoverEmptyWorkspaceAfterStartupIfNeeded()` refill; `restoreSessionSnapshot` restores a zero-workspace snapshot as an empty home (fallback fabrication gated on `!snapshot.workspaces.isEmpty`); and a fenced comment marks `markRemoteTmuxKillOnWindowCloseIfNeeded` as intentionally orphaned (kept verbatim for merge cleanliness). Explicit window close (red button / ⌘⇧W) is unchanged. Since the 2026-09-30 upstream merge: the post-close selection is a fenced `if tabs.isEmpty { selectedTabId = nil }` ahead of upstream's `workspaces.selectionTargetAfterClose(closedIndex:)`; `closeWorkspacesPlan` passes `willCloseWindow: false` (upstream replaced the plan's `acceptCmdD` with `willCloseWindow`, which drives both Cmd-D acceptance and the `.window` vs `.workspace` warning); `closeWorkspaceIfRunningProcess` drops upstream's `closeWindowForLastWorkspace(workspaceId:closeAlreadyConfirmed:)` call. **Relaunch caveat:** upstream #14788 (`isPhantomSessionWindow` in `SessionPersistencePolicy+CrashStorage.swift`, unfenced) drops every 0-workspace window on save/load/reopen, so an empty-home window does not survive relaunch — open decision, see the 43–45 re-apply section |
| 44 | `Sources/ContentView.swift` | `empty-home` | `terminalContent` renders `SupermuxEmptyHomeView` (centered "No open tabs" hint) when `tabManager.tabs` is empty, gated to the `.tabs` sidebar surface and non-interactive. New file `Sources/Supermux/SupermuxEmptyHomeView.swift` wired via touchpoint #3 (IDs `…F5`/`…F6`); `supermux.emptyHome.*` keys under #4b. Since the 2026-09-30 upstream merge the startup-recovery guard `guard !tabManager.tabs.isEmpty else { … return }` replaces upstream's `if tabManager.recoverEmptyWorkspaceAfterStartupIfNeeded() { didRecover = true }`, and the titlebar guard reads `guard let authoritativeSelection else { updateTitlebarText(); return }` |
| 45 | `cmuxTests/TabManagerUnitTests.swift` | `keep-window-on-last-close` | Repurposes the child-exit window-close test to assert the window stays open (empty home), adds two tests for `closeWorkspace(allowEmptyingWindow:)` emptying the window vs. a plain close keeping the last workspace, and covers failed closed-workspace restore cleanup from empty home; plus `testDetachingLastWorkspaceLeavesEmptyHome` and `testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty`. The child-exit test also asserts `XCTAssertFalse(closeRequestSawRegisteredOwner)` (upstream's new flag); upstream's `testSessionSnapshotDropsWindowWithNoRestorableWorkspaces` is taken as-is |
| 46 | `Sources/FileExplorerNSOutlineView.swift` | `file-explorer-operations-keys` | ⌘⌫ (Move to Trash) / Return (Rename) keyboard handling in the outline view's `keyDown`, placed **before** upstream's `handleOpenSelectionShortcut` so Return renames (Finder-standard) and ⌘⌫ trashes; ⌘↓ still opens via upstream's Finder alias. Return/⌘⌫ are never claimed during an active `/` quick-search (Return keeps upstream's end-search+open semantics), and `handleSupermuxFileOperationKey` yields to a user-**explicitly**-configured Open Selection binding (Settings override or cmux.json) matching the keystroke, while the built-in Return default remains shadowed. Upstream (cmux #6001) extracted `FileExplorerNSOutlineView` out of `FileExplorerView.swift` into this file, so the `-keys` fence (originally part of #39) moved here. One-line call into the `FileExplorerPanelView.Coordinator` extension |
| 47 | `CLI/CMUXCLI+ThemeSupport.swift` | `right-sidebar-changes-mode-cli-set`, `right-sidebar-changes-mode-cli-normalize` | Adds `"changes"` to `isRightSidebarCLIMode` and `normalizedRightSidebarCLIArgument` so `cmux right-sidebar set changes` / `cmux right-sidebar changes` validate and normalize. Upstream (cmux CLI refactor) moved these two helpers out of `CLI/cmux.swift` into this file, so the `-cli-set` fence (originally part of #10) moved here; `-cli-normalize` is new (the normalizer did not exist at the previous merge base). Since the 2026-09-30 upstream merge each fence holds upstream's full list (`cloud`, `machines`, `vms`, `devices`, `device`, `macs`, `custom`, `custom-sidebar` / `machines`, `custom`, `custom-sidebar`) plus `"changes"` |
| 48 | `Sources/RightSidebarChromeStyle.swift` | `right-sidebar-compact-mode-bar` | Adds a `showsLabel` flag to upstream's `ModeBarButton` (icon-only when the sidebar is narrow). Upstream relocated `ModeBarButton` here from `RightSidebarPanelView.swift` and switched it to an `item:`-based API; the compact-mode-bar fence (part of #5) moved with it. `RightSidebarPanelView.modeButtonsRow` now drives the `modeBarItems`/`ModeBarButton(item:showsLabel:)` API inside `ViewThatFits` |
| 49 | `Sources/Sidebar/SidebarWorkspaceSnapshotRefreshPolicy.swift` | `sidebar-flatrow-activity` | Carries `supermuxActivity` through the frozen-snapshot `applyingContextMenuImmediateFields` rebuild — since upstream 0.65 this is the SECOND production construction site of `SidebarWorkspaceSnapshotBuilder.Snapshot`, alongside `SidebarWorkspaceSnapshotFactory.makeSnapshot` (#128); `ContentView.swift` no longer constructs Snapshots. Previously an unfenced edit; fenced and registered during the upstream merge that added `finderDirectoryPath`/`mediaActivity` to the same initializer. `supermuxActivity` is still LAST, after upstream's new `taskStatusInput:`, `deviceWorkspaceLabel:` and `compactStatusGlyph:` |
| 50 | `Sources/ContentView.swift` | `sidebar-hide-scrollbar` | Hides the left workspace sidebar's scrollbar. Two layers: (a) `VerticalTabsSidebar.configureSidebarScrollView` (the shared resolver hook for both the default projects+workspaces list and the extension-provider list) no longer calls upstream's `applySidebarOverlayScrollerConfiguration()`; it instead forces `hasHorizontalScroller`/`hasVerticalScroller` to `false` (write-only-when-differs). (b) Both sidebar `ScrollView`s get `.scrollIndicators(.hidden)` so SwiftUI itself keeps the indicator hidden — the AppKit resolver alone loses to SwiftUI, which re-asserts the scroller from its default `.scrollIndicators(.automatic)` after the resolver's deferred apply. Scrolling still works via trackpad/wheel |
| 51 | `scripts/reload.sh` | `reload-prune-leftover-base-app` | After a tagged build renames the raw `cmux DEV.app` into `cmux DEV <tag>.app`, calls the supermux-owned `scripts/supermux-prune-dev-builds.sh --reload-leftover` to deregister + delete the never-launched leftover base bundle, so macOS stops accumulating one stale "cmux DEV" row per tag in System Settings > Login Items & Extensions. The prune script is supermux-owned (no touchpoint); only this one-line call into it is fenced |
| 53 | `ios/Config/cmux.entitlements` | `unfenced` | Strips `com.apple.developer.applesignin`, `aps-environment`, and `com.apple.developer.usernotifications.time-sensitive` so automatic signing can provision a personal Apple team that lacks those capabilities (comments are unsafe to fence around a plist-key removal). Known divergence since the 2026-09-30 upstream merge: upstream's `ios/tests/tagged-device-entitlements.test.mjs` ("tagged Debug API-key signing can retry without the App Group") expects `aps-environment` in this file and fails against the fork |
| 54 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires `LocalConfig.plist` into the iOS app's Copy Bundle Resources phase (build file `FCAB1004…`, file ref `FCAB101B…`) so the app can read it from the bundle |
| 55 | `ios/cmux/Resources/LocalConfig.plist` | `unfenced` | New supermux-owned resource; sets `AuthEnvironment=production`, read by upstream's `MobileAuthComposition.authOverrides` LocalConfig override table (which replaced the retired #52 fence at the v0.64.19 merge). Not an upstream modification — registered so the check guards its existence (the pbxproj entry in #54 references it) |
| 56 | `Sources/Workspace+AgentLifecycle.swift` | `workspace-agent-lifecycle-observation` | One fenced line at the top of `recordAgentLifecycleChange(panelId:)` — the single choke point every agent-lifecycle set/clear routes through — calls `SupermuxWorkspaceLifecycleRelay.workspaceDidChangeAgentLifecycle(self)` (relay lives in supermux-owned `Sources/Supermux/SupermuxWorkspaceActivityResolver.swift`), making lifecycle-only mutations observable: cmux's sidebar publishers carry no lifecycle field, so without it the supermux activity indicators went stale on socket `set_agent_lifecycle`, hibernation clears, and feed-attention conclusion. Placed before the `AgentHibernationController` call, whose tracking gate drops events when disabled. **Upstream (0.64.x) extracted the lifecycle code out of `Workspace.swift` into `Workspace+AgentLifecycle.swift`; the fence moved with it** |
| 57 | `Sources/Workspace.swift` | `keep-window-on-last-close` | Remote-tmux close-button fallback: the last workspace of the last window closes into the empty home (`closeWorkspace(self, recordHistory: false, allowEmptyingWindow: true)`) instead of falling through to a replacement local shell in the dead mirror; the multi-window discard branch stays upstream |
| 58 | `Sources/AppDelegate.swift` | `new-workspace-standalone` | `unregisterMainWindow` prunes the association store against the union of every remaining window's workspace ids on whole-window teardown (which skips the per-workspace close path); durable directory links live in the projects model and survive, so a revived closed window re-nests by directory. Since the 2026-09-30 upstream merge the retained set is the union of `mainWindowContexts` and upstream's `recoverableMainWindowRoutes()` tab managers' workspace ids (orphaned routes whose workspaces are still live), and the anchor is upstream's `closingTabManager` |
| 59 | `Sources/TerminalController.swift` | `keep-window-on-last-close` | The socket `close_workspace` command routes through `closeWorkspace(tab, allowEmptyingWindow: true)` and replies OK only when the workspace actually left `tabs` (upstream `closeTab` silently no-ops on a window's last workspace while replying OK). At the 2026-10-01 upstream merge upstream added a `--force` token and a `workspaceNeedsConfirmCloseForClose` confirmation ("retry with --force"); that check stays upstream's and sits just before the fence |
| 60 | `Sources/RemoteTmuxController.swift` | `keep-window-on-last-close` | BOTH arms of upstream 0.65's teardown-reason switch are fenced: `.sessionEnded` (dead mirror) drops upstream's add-a-replacement-workspace workaround and closes with `allowEmptyingWindow: true`; `.explicitDetach` (deliberate detach, remote session kept alive) replaces upstream's `closeWorkspaceNonInteractively(allowPinned: true)` — which closes the whole window (and on the last window quits the app) when the mirror is the window's last workspace — with the same `closeWorkspace(allowEmptyingWindow: true)`, leaving the empty home. Pre-0.65 both cases shared one teardown path and one fence. Upstream's `.sessionEnded` workaround is now `acquireOptionalWorkspaceIfActive { addWorkspaceIfActive(…) }` plus a plain close; the fork arm still replaces it wholesale |
| 61 | `Sources/AppleScriptSupport.swift` | `keep-window-on-last-close` | AppleScript `close tab` (`ScriptTab.handleCloseTab`) and terminal `close` last-panel path (`ScriptTerminal.handleClose`) call `closeWorkspace(workspace, allowEmptyingWindow: true)` instead of the `tabs.count > 1` fork + `window.performClose(nil)`, so scripted last-workspace closes leave the empty home like ⌘W |
| 62 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift` | `run-toggle-shortcut-case`, `workspace-switcher-shortcut-case`, `supermux-commit-shortcut-case` | Adds the supermux cases (`supermuxToggleRun`, the two workspace-switcher actions, the two commit actions; `supermuxNewClaudeHarness` under #440) to the settings-package enum that drives the Settings UI and its conflict detection (reuses the app-target fence ids). Upstream (0.65) extracted `group` and `displayName` out of this file, so the two other fences moved to #62b/#62c |
| 62b | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Group.swift` | `supermux-shortcut-groups` | Places the supermux actions in the Settings groups (`supermuxToggleRun`/`supermuxCommit`/`supermuxCommitAccelerator` → `.workspace`; the two workspace-switcher actions and `supermuxNewClaudeHarness` → `.navigation`). Upstream extracted `ShortcutAction.group` out of `ShortcutAction.swift` into this file; the fence moved with it |
| 62c | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+DisplayName.swift` | `supermux-shortcut-display-names` | The `String(localized: "supermux.*.label", …)` display names (five `supermux.shortcut.*` plus `supermux.harness.shortcut.newPane.label`) shown in the Settings shortcut list. Upstream extracted `ShortcutAction.displayName` out of `ShortcutAction.swift` into this file; the fence moved with it. The package resolves `String(localized:)` against `Bundle.main`, so the app catalog (`Resources/Localizable.xcstrings`, #4b) serves these keys in en + ja |
| 63 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction+Defaults.swift` | `supermux-shortcut-defaults` | Package mirror of the six supermux default strokes (⌘G, ⌘\`, ⇧⌘\`, ⌘↩, ⇧⌘↩, ⌃⌘A) from `Sources/KeyboardShortcutSettings.swift`; both tables must agree. The arms sit inside upstream's `builtInDefaultStroke` (see #29) |
| 64 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Stores/SecretFileStore.swift` | `secret-file-0600-write` | Temp-file-at-0600 + `rename(2)` write path removing the chmod-after-write exposure window for the AI gateway key |
| 65 | `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/SecretFileStoreTests.swift` | `secret-file-0600-write` | Regression test for the 0600 write path (same fence id as #64) |
| 66 | `cmuxTests/KeyboardShortcutContextTests.swift` | `settings-package-shortcut-action-drift` | Drift test that fails on app-target shortcut actions unmapped in the settings-package enum, plus an alignment test for the six supermux actions |
| 67 | `web/data/cmux-shortcuts.ts` | `supermux-commit-shortcut-doc` | Documents the two Changes-panel commit chords (⌘↩ / ⇧⌘↩) in the diff-viewer section of the keyboard-shortcut registry |
| 68 | `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/SupermuxShortcutActionTests.swift` | `unfenced` | Whole-file supermux-owned test inside the upstream `CmuxSettings` package test target (SupermuxAISettingsCard precedent, #18); registered so the check guards its existence |
| 69 | `Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/SupermuxAISettingsCardContractTests.swift` | `unfenced` | Whole-file supermux-owned contract test inside the upstream `CmuxSettingsUI` package test target (SupermuxAISettingsCard precedent, #18) |
| 70 | `Sources/TerminalController+ControlWorkspaceContext.swift` | `keep-window-on-last-close` | The control-socket `workspace.close` resolver (`controlCloseWorkspace`) routes through `closeWorkspace(ws, allowEmptyingWindow: true)` and returns `.resolved` only when the workspace actually left `tabs` (plain close silently no-ops on a window's last workspace while still replying `.resolved`). At the 2026-10-01 upstream merge upstream added `force` and a `.confirmationRequired` check (running process, or the window dock on a window's last workspace); it stays upstream's, just before the fence |
| 71 | `Sources/TerminalController+MobileWorkspaceList.swift` | `keep-window-on-last-close` | The mobile `v2MobileWorkspaceClose` API drops upstream's `tabs.count > 1` last-workspace rejection, closes via `closeWorkspace(workspace, allowEmptyingWindow: true)`, and replies ok only when the workspace actually left `tabs`; the doc comment is updated in a fence to match. At the 2026-10-01 upstream merge upstream added a `force` param and a `confirmation_required` reply; the fork's close fence is now SPLIT in two around that upstream block (protected result + `canCloseWorkspace` guard before it, the empty-home close + still-present check after it) |
| 72 | `cmuxTests/FileExplorerStoreTests.swift` | `file-explorer-operations-reveal` | Four regression tests for pending-reveal invalidation: selecting a different path or multi-selecting away cancels a pending supermux reveal, re-selecting the reveal path keeps it, and supermuxClearSelection resets reveal state |
| 73 | `Sources/DragOverlayRoutingPolicy.swift` | `browser-hover-drag-guard` | Bug fix (re-land of fcb443d8df, dropped in the undo/re-land cycle around 544bdc1d5d): gates the browser-portal hover→drag pass-through on the left mouse button actually being held, so a stale `.drag` pasteboard (Bonsplit/sidebar tab-transfer types persist after a drag ends) can no longer misroute ordinary hover past the WKWebView. Regression test in `cmuxTests/PortalTabDragRoutingTests.swift` (#75). Since the 2026-09-30 upstream merge upstream's signatures gained `hasLiveTabTransfer:`/`hasLiveFileDropPayload:` (a live tab-drag registry via `LiveTabDragCapabilityResolver`, #10804) and upstream dropped sidebar-reorder from hover (`.pointerHover` returns `hasTabTransfer`). The fenced `pressedMouseButtons:` param still sits before `hasActiveDropDrag:`, followed by upstream's new params. Upstream's liveness gate now fixes the same stale `.drag`-pasteboard bug, so this family (#73–79) is defense in depth and a candidate for retirement |
| 74 | `Sources/Panels/BrowserPanelView.swift` | `browser-hover-webkit-topmost-gate` | Bug fix: WebKit only processes hover (mouseMoved → CSS `:hover`, cursor updates, tooltips) when `window.contentView.hitTest(...)` resolves to the WKWebView or a descendant (`updateViewIsTopmostAtMouseLocation:` in WebKit's WebViewImpl.mm). cmux's browser portal hosts the web view on the theme frame — outside the contentView subtree — so that gate always failed and hover was dead in every embedded browser pane while clicks/scroll kept working. The SwiftUI-side anchor (`WebViewRepresentable.HostContainerView`) now delegates hover-time hit tests to the portal-hosted web view — but only while no tab drag is in flight (those hit tests must keep resolving to the Bonsplit/sidebar drop targets behind the portal) and only when the web view is actually topmost in its slot (find-bar/omnibar-suggestion overlays are slot siblings layered above it). Wired only in window-portal hosting mode; an inline-hosted web view already sits in the anchor's subtree. Two fences: the anchor property/test-seam/helper/`hitTest` hook, and the `updateNSView` wiring. Regression test in #75. Since the 2026-09-30 upstream merge `portalHoverDelegationTarget` passes upstream's now-required `hasLiveTabTransfer` to `shouldPassThroughPortalHitTesting`; without it an in-flight tab drag would be claimed for the web view. The fenced param is `hasLiveTabTransfer: @autoclosure () -> Bool? = nil` (a test seam), and nil is resolved INSIDE the main-actor body to `DragOverlayRoutingPolicy.hasLiveTabTransfer(in: NSPasteboard(name: .drag), resolver: AppDelegate.shared?.liveTabDragCapabilityResolver)` — a default-argument autoclosure is nonisolated and cannot read the main-actor tab-drag registry, so never move that call back into the default |
| 75 | `cmuxTests/PortalTabDragRoutingTests.swift` | `browser-hover-drag-guard`, `browser-hover-webkit-topmost-gate` | Regression tests for #73 (hover with no held button must not pass through the portal; active drags still do) and #74 (the anchor delegates hover hit tests to the portal-hosted web view — including end-to-end through `hitTest` via the routing-context test seam; non-hover contexts, in-flight tab drags, occluding slot overlays, out-of-bounds points, and other-window web views are not claimed). Since the 2026-09-30 upstream merge the #73 regression test uses only the Bonsplit payload plus `hasLiveTabTransfer: true` (the button is the only variable; sidebar reorder no longer routes on hover), and one #74 assertion passes `hasLiveTabTransfer: true` |
| 76 | `Sources/BrowserWindowPortal.swift` | `browser-hover-drag-guard` | Injectable `pressedMouseButtons` parameter on `WindowBrowserHostView.shouldPassThroughToDragTargets` (forwards to the #73 policy; keeps the #78 tests deterministic) plus a comment at the pass-through call site noting the fork's pressed-button gate. The fenced param sits before upstream's new `hasLiveTabTransfer:`/`hasLiveFileDropPayload:` params |
| 77 | `Sources/BrowserPaneDropTargetView.swift` | `browser-hover-drag-guard` | Same stale-drag-pasteboard fix one layer down: the slot's invisible pane drop target no longer captures hover-kind hit tests while no left button is held, so a stale tab-transfer/file payload can't misroute post-drag cursor updates and tooltips inside the slot (and can't defeat #74's topmost check, which hit-tests the slot). The hover guard stays right after `allowsPaneDropHitTesting`, before upstream's new mouse-up liveness gate |
| 78 | `cmuxTests/BrowserPanelTests.swift` | `browser-hover-drag-guard` | Updates upstream's two hover pass-through tests to the fork contract (hover-kind pass-through requires the left button held; the sidebar-reorder test is renamed accordingly); upstream's originals asserted exactly the stale-hover behavior #73 removes and would fail deterministically on CI. Since the 2026-09-30 upstream merge upstream renamed the sidebar test to `testStaleSidebarReorderDoesNotPassThroughBrowserHoverEvents` (both assertions false with button 0 and 1); the tab-transfer hover test passes `pressedMouseButtons` plus `hasLiveTabTransfer: true` |
| 79 | `cmuxTests/BrowserPaneDropRoutingTests.swift` | `browser-hover-drag-guard` | Updates upstream's capture test to inject the pressed-button state and adds stale-hover regression coverage for #77. Since the 2026-09-30 upstream merge every hover call injects `pressedMouseButtons: 1` so upstream's liveness rules are tested independently; the fork stale-hover test passes all live flags with `pressedMouseButtons: 0`; mouse-up and dragged positives add `hasLiveTabTransfer: true` |
| 80 | `Sources/TabManager.swift` | `new-workspace-home-dir` | With "Inherit Workspace Working Directory" OFF, new workspaces always start in the home directory. **TWO fence sites since 0.65.** (a) `addWorkspace` — upstream rewrote it to resolve the cwd through `WorkspaceCreationWorkingDirectoryPolicy(inheritanceEnabled:).resolve(explicitWorkingDirectory:inheritedWorkingDirectory:defaultWorkingDirectory:)` and STOPPED calling `implicitWorkingDirectoryForNewWorkspace`; the fence supplies `FileManager.default.homeDirectoryForCurrentUser.path` as `defaultWorkingDirectory` in place of upstream's `defaultWorkspaceWorkingDirectoryProvider()`. The guard keys off the **SETTING alone**, never `inheritanceEnabled`, so an explicit `inheritWorkingDirectory: false` call with the setting ON still takes upstream's default (upstream's `testExplicitNoInheritanceUsesGhosttyDefaultWhenGlobalInheritanceEnabled` depends on that). (b) `implicitWorkingDirectoryForNewWorkspace` — same home pin, now serving only the detached path (#42's file). Regression test: `cmuxTests/SupermuxNewWorkspaceHomeDirectoryTests.swift` (wired via #3). See the OPEN DECISION note in the #80 re-apply section: upstream has since closed the nil-cwd leak on its own terms |
| 81 | `cmuxTests/WorkspaceUnitTests.swift` | `new-workspace-home-dir` | Upstream renamed this test to `testDisabledInheritanceUsesGhosttyDefaultForNewWorkspaceCwd` (was `…LeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback`) and it now asserts `fallbackCwd` via an injected `defaultWorkspaceWorkingDirectoryProvider` instead of a nil cwd. Either form contradicts the fork, so it stays fenced as `testDisabledInheritancePinsNewWorkspaceCwdToHomeDirectory`, keeps the injected provider, and asserts the explicit home directory (proving the fork's pin beats the provider). Only coverage of #80's `addWorkspace` fence site. Adapted to upstream's closure signature `withWorkspaceWorkingDirectoryInheritanceSetting(false) { settings in … }` |
| 84 | `Sources/SettingsSearchAliases.swift` | `new-workspace-home-dir` | The toggle's settings-search alias swaps the stale `ghostty` keyword for `home` (the OFF behavior no longer involves Ghostty's working-directory setting); en/ja catalog values under #4b |
| 85 | `Sources/SettingsSearchIndex.swift` | `new-workspace-home-dir` | Same `ghostty` → `home` keyword swap in the `workspace-inherit-working-directory` entry's search keywords. Upstream extracted `enum SettingsSearchIndex` out of `SettingsNavigation.swift` into this file at the 2026-09-30 upstream merge, and `SettingsNavigation.swift` is byte-identical to upstream again. The swap stays while #80's OFF behavior is "home"; revert it together with #84 if #80 is ever retired |
| 86 | `web/messages/en.json` | `unfenced` | Adds `schemaDescriptions.app.workspaceInheritWorkingDirectory` so the localized docs configuration page renders the reworded #14 schema description through `descriptionKey` (the sibling mechanism 32 other schema properties use) instead of the English-only `description` fallback |
| 87 | `web/messages/ja.json` | `unfenced` | Japanese translation for the #86 message key |
| 88 | `skills/cmux-settings/references/all-keys.md` | `unfenced` | Regenerated the `app.workspaceInheritWorkingDirectory` description row to match the #14 schema description (the file is auto-generated from `web/data/cmux.schema.json` and had the removed Ghostty-fallback wording) |
| 90 | `cmux.xcworkspace/contents.xcworkspacedata` | `unfenced` | Adds the supermux-owned package FileRefs to the workspace groups: `Packages/Shared/SupermuxMobileCore` (Shared group), and `Packages/iOS/SupermuxMobileKit` and `Packages/iOS/SupermuxMobileUI` (iOS group). Generated file — regenerate with `python3 scripts/check-workspace-package-groups.py --write` (the `Packages/` folder layout is the source of truth), never hand-edit |
| 91 | `Sources/TerminalController.swift` | `mobile-supermux-dispatch` | One case in the `mobileHostHandleRPC` switch routes the whole `mobile.supermux.*` namespace to `v2MobileSupermuxDispatch` (fork-owned `Sources/Supermux/TerminalController+SupermuxMobile.swift`), mirroring the adjacent prefix cases. Since the 0.64.21 merge it sits **after upstream's new `mobile.browser.*` case** (it used to follow `mobile.chat.*` directly); position among the prefix cases is irrelevant as long as it precedes `default:` |
| 92 | `Sources/Mobile/MobileHostService+TicketAuthorization.swift` | `mobile-supermux-authz` | In `ticketAuthorizationError(authorization:request:)` (**upstream 0.64.x extracted ticket authorization out of `MobileHostService.swift` into this file; the fence moved with it**), after the alias/conflict guards and before the upstream method switch, delegates every `mobile.supermux.*` method to the fail-closed `SupermuxMobileAuthorization.ticketError` table (fork-owned `Sources/Supermux/SupermuxMobileAuthorization.swift`); reachable in tests by calling `ticketAuthorizationError` directly (upstream removed the `debugTicketAuthorizationError` seam) |
| 93 | `Sources/Mobile/MobileHostService+Capabilities.swift` | `mobile-supermux-capabilities` | `capabilities += SupermuxMobileCapabilities.advertised` (fork-owned `Sources/Supermux/SupermuxMobileCapabilities.swift`) inside `mobileHostCapabilities(includingWorkspaceChanges:)`, placed **after** upstream's `includingWorkspaceChanges` filter and **before** the `#if DEBUG` `CMUX_DEBUG_SUPPRESS_MOBILE_CAPS` suppression, so the phone can gate supermux screens on `supermux.*.v1` and a dev Mac can still suppress fork capabilities. **Invariant:** the fork list must never contain the literal `workspace.changes.v1` — upstream's `cmuxTests/MobileHostConnectionLifecycleTests.swift` asserts `enabled.filter { $0 != workspaceChangesCapability } == disabled`, which a duplicate entry breaks |
| 94 | `Sources/AppDelegate.swift` | `mobile-supermux-observers` | One line at the top of `ensureMobileWorkspaceListObserver(for:)` calls `SupermuxMobileHostGlue.activateIfNeeded()` (fork-owned `Sources/Supermux/SupermuxMobileObservers.swift`) so fork mobile observers activate exactly where upstream constructs `MobileWorkspaceListObserver` |
| 95 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the `SupermuxMobileCore` package (local package reference + product dependency on the `cmux` and `cmuxTests` targets), the existing seventeen `50BE0002…` `Sources/Supermux/` mobile files, and `Workspace+SupermuxMobileUnread.swift` (`50BE0003…0001/0002`) into the cmux target; also wires the four Supermux mobile app-host tests into `cmuxTests` |
| 96 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-client-mount` | One computed property `supermuxConnectionSeam` (next to `remoteClientForAgentChat`) exposes the live `MobileCoreRPCClient` + `supportedHostCapabilities` snapshot to the fork's supermux phone stores; `nil` unless connected. All tracked `@Observable` reads, so the fork's section driver re-runs (and rebuilds `SupermuxMacClient` + stores) on every (re)connect and on capability arrival |
| 97 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-projects-section` | Five fences: `import SupermuxMobileUI`; a `@State` `SupermuxProjectsSectionModel` (**internal, not private** — the `+Table.swift` extension projects it into the #148 row payload); the `.supermuxProjectsSectionDriver(model:seams:workspaces:selectedWorkspaceID:selectWorkspace:resolveWorkspace:closeWorkspace:)` session driver on the **iOS** `workspaceTable` (fed by the #581 per-Mac seams and the #582 resolver since #583; `workspaces` + `selectWorkspace` feed the §6 open-workspace join and nested-row navigation); and, in the macOS-only `#else` arm, the legacy `SupermuxProjectsMobileSection(section:actions:)` mount + driver on the SwiftUI `List`. **The two arms are not interchangeable.** Since upstream 0.64.20 the iPhone renders `workspaceTable`, so the `#else` mount is macOS-only and the iOS rows come from #148 instead; a driver left only in `#else` (the state this row shipped in from 0.64.20 until #148) means the section never loads on iOS and every Projects affordance is unreachable. The driver must stay on a STABLE view — never inside a table cell — because it owns the session `.task`, the project-detail `navigationDestination`, and the nested-open error alert. Section renders nothing without `supermux.projects.v1` |
| 98 | `Packages/iOS/CmuxMobileShellUI/Package.swift` | `supermux-mobile-shellui-deps` | Two fenced 1-line additions: `.package(path: "../SupermuxMobileUI")` in `dependencies` and `"SupermuxMobileUI"` in the `CmuxMobileShellUI` target dependencies (fork-owned Projects section package). At the 2026-10-01 upstream merge the fenced lines follow upstream's new `CmuxTerminalSizing` dependency |
| 99 | `Sources/TerminalController+MobileWorkspaceList.swift` | `mobile-supermux-workspace-fields` | Builds the legacy row, merges project/activity/branch/PR metadata, adds `supermux_unread_count` when known, and always adds `supermux_unread_panel_ids` from #389. The always-present array is the exact-pane capability signal; it must remain outside the project-association-gated augmenter |
| 100 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-workspace-fields` | Lossily decodes the additive project/activity/branch/PR fields plus optional unread count and optional `[String]` pane ids; memberwise construction defaults every fork field to `nil` for upstream source compatibility. `nil` pane ids mean unsupported, while `[]` is preserved as supported-empty |
| 101 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-workspace-fields` | Stores the additive metadata, unread count, and optional `supermuxUnreadPanelIDs`, all defaulted to `nil`. The derived `supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen` is true only for unread old-host rows; aggregation copies the whole preview value, preserving both old-host absence and supported-empty pane state |
| 102 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-workspace-fields` | Copies every decoded Supermux workspace field into the preview, including unread count and exact pane ids, so legacy list ingestion feeds the same UI model as state sync v2 |
| 103 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-project-workspaces`, `supermux-mobile-row-activity` | Hide filter: a fenced `supermuxFlatWorkspaces` helper (`workspaces.supermuxFlatRows(hidingProjectIDs: supermuxShownProjectIDs)`), where `supermuxShownProjectIDs` is non-empty only while `snapshot.isVisible && snapshot.hasLoaded && trimmedQuery.isEmpty && !filter.isActive` — i.e. the hide is active only when the Projects section is visible AND loaded AND no search/filter, plus two fenced swaps where upstream read `workspaces` — one in `filteredWorkspaces` (a one-line `let workspaces = supermuxFlatWorkspaces` rebind) and one in `groupedWorkspaces` (the fence wraps only the `return`; upstream's `parsedMachines` precompute sits above it, unfenced). Row dot: one fenced `.supermuxWorkspaceActivityDot(rawActivity:)` modifier on `WorkspaceNavigationRow` in `workspaceRow` |
| 104 | `ios/cmux/AppCompositionRoot.swift` | `uitest-clear-paired-mac-state` | When `UITestConfig.mockDataEnabled` and the harness sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1`, deletes `Application Support/cmux/` (the `MobilePairedMacStore` sqlite + WAL/SHM) once at composition-root init, before `CMUXMobileRootScene` opens the store. Fixes cross-test pairing-state leakage on the shared simulator: since #89 made pairing actually complete, a persisted paired Mac from a prior test/run auto-navigated past `MobileAddDeviceForm` and its dead-host reconnect churn broke 3 cmuxUITests (cmuxUITests.swift:245/:586). No-op for real installs: the mock gate is DEBUG-only and the env var is only set by the XCUITest harness (#105) |
| 105 | `ios/cmuxUITests/cmuxUITests.swift` | `uitest-clear-paired-mac-launch` | `launchApp` sets `CMUX_UITEST_CLEAR_PAIRED_MACS=1` on every harness launch so each test starts from an unpaired slate (consumed by #104) |
| 107 | `scripts/check-package-resolved-policy.py` | `fix-resolved-policy-path-deps` | Manifest diffs whose `.package(…)` changes are limited to path-based dependencies (`.package(path:)`, including brand-new path-referenced manifests) no longer demand a `Package.resolved` diff — SwiftPM never records path deps in any lockfile, so that demand was unsatisfiable (`swift package resolve` rewrites nothing). Pinned URL dependency changes still require lockfile churn. Also silences the expected `git show` error for manifests new since the merge base. **Five fence blocks:** `lockfile_recorded_dependency_calls`, `path_dependency_remote_pin_roots`, the `current_remote_memo` declaration, the changed-roots skip, and `file_text_at`. The two higher-level remote-closure skips (per-package root and iOS workspace gates) were dropped at the 2026-09-30 upstream merge because upstream now ships the same logic (with a `merge_base is not None` guard) |
| 108 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-workspace-tools` | Two fences: `import SupermuxMobileUI`, and the `.supermuxWorkspaceTools(connection:workspaceID:workspaceName:showingChanges:showingFiles:)` modifier on the detail `body`'s outer `Group`. Since the #228 toolbar consolidation the modifier mounts ONLY the two sheets (`SupermuxChangesScreen` / `SupermuxFileBrowserScreen`), driven by the `isSupermuxChangesSheetPresented` / `isSupermuxFilesSheetPresented` bindings that #228's explicit overflow menu flips via the fork-owned `SupermuxWorkspaceToolsMenuEntries`; it no longer adds `ToolbarItem`s of its own. Fed by `supermuxWorkspaceSeam` (#584 — the seam of the Mac that OWNS the workspace, #585) rather than the #96 foreground seam; each menu entry hides without its capability (`supermux.changes.v1` / `supermux.files.v1`). Note upstream now ships its OWN mobile diff viewer behind `workspace.changes.v1`; both are advertised whenever `CmuxFeatureFlags.mobileWorkspaceChangesFlag` is on — see SUPERMUX.md "Known limitations", open decision 2. Since the 2026-09-30 upstream merge `.supermuxWorkspaceTools(...)` is attached to upstream's new `Group { VStack { terminalCreationRecovery…; detailSurfaceContent } }`, so it still covers every detail surface including the recovery banner |
| 109 | `scripts/lint-ios-package-conventions.sh` | `lint-ios-conventions-fork-scopes` | Adds the fork mobile packages (`Packages/Shared/SupermuxMobileCore`, `Packages/iOS/SupermuxMobile*`) to the lint's SCOPES so the iOS conventions lint (CI job `package-conventions-lint` in `.github/workflows/test-ios.yml`) mechanically enforces its per-line rules on them; deliberate constant/text namespace holders in the fork packages carry inline `lint:allow` justifications |
| 110 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-hide-search` | ⚠️ **INERT since the 0.64.21 merge — comment-only marker, the fork behavior is gone.** It used to replace upstream's `.searchable(text: $searchText)` on the workspace `List` so the phone had no main-list search bar. Upstream moved search into two NEW files (`…/WorkspaceListSearchHost.swift` pre-iOS 26, `…/MobilePrimaryTabScaffold.swift` for the iOS 26 search Tab) and `searchText` is now an injected property rather than `@State`, so **phone search is LIVE again** and there is nothing left in this file to remove. OPEN DECISION — re-apply at the new hosts, retire the touchpoint, or accept upstream's search (current default). See SUPERMUX.md "Known limitations" |
| 111 | `.gitignore` | `supermux-gitignore-mission` | One fenced line ignoring the fork-local `mission/` mission-kit state directory (mission-plan/mission-run progress artifacts; local tooling data, never product code). `.phone-build/` directly above is upstream/pre-existing and stays unfenced. Re-apply: if upstream rewrites `.gitignore`, re-add `mission/` inside the fence anywhere in the file |
| 112 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/SupermuxWorkspaceListFieldsDecodeTests.swift` | `unfenced` | Whole fork-owned test file in the upstream RPC test target. Proves additive-field tolerance and preview mapping, including upstream absence, exact pane-id arrays, supported-empty `[]`, and malformed mixed-type pane arrays degrading to unsupported `nil` without failing the workspace list |
| 113 | `Sources/SidebarWorkspaceSnapshotBuilder.swift` | `sidebar-flatrow-activity` | The fenced `var supermuxActivity: SupermuxWorkspaceActivity = .idle` field (defaulted so non-production construction sites can omit it) + a fenced `import SupermuxKit`. Upstream (0.64.x) extracted `SidebarWorkspaceSnapshotBuilder` out of `ContentView.swift` into this file; the Snapshot-field part of the #2 fence moved with it. The production construction sites (`SidebarWorkspaceSnapshotFactory.makeSnapshot` in #128, the frozen-snapshot rebuild in #49) pass it as the LAST parameter (the struct declares it after upstream's checklist fields). Still the LAST stored property, after upstream's new `taskStatusInput`, `deviceWorkspaceLabel` and `compactStatusGlyph`, and before upstream's computed `remoteWorkspaceBadge*` / `accessibilityLabel(index:workspaceCount:)` |
| 114 | `Sources/TabItemView+WorkspaceContextMenu.swift` | `sidebar-hide-project-workspaces` | Upstream (0.64.x) extracted `workspaceContextMenu` out of `ContentView.swift` into this file; the context-menu enablement part of the #2 fence moved with it: one fenced `let menuVisibility = actions.supermuxMenuVisibility(workspaceId, Set(targetIds))` resolve before Move Up (keyed by workspace id — the row's snapshot `index` is its visible ordinal since the VoiceOver fix, so the provider resolves the full-list position itself), and the five fenced `.disabled(...)` overrides: Move Up/Down disable on `canMoveUp`/`canMoveDown` (stepped-plan reachability, matching the #131 mover), Close Other/Below/Above on visible-row availability. Since upstream's 0.65 snapshot boundary the row holds no `tabManager`, so visibility resolves through the #129 actions field (bound in #2, value type in fork-owned `SupermuxRowMenuVisibility.swift`) |
| 115 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `keep-window-on-last-close` | Repurposes upstream's `testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace` (renamed `testCmdWLeavesEmptyHomeWhenClosingLastSurfaceInLastWorkspace`): with the close-workspace-on-last-surface setting on, Cmd+W on the last surface of the last workspace closes the WORKSPACE but keeps the window open as the empty home; upstream asserted the window closes, which is exactly the behavior keep-window-on-last-close removes (same class as #45/#81/#83) |
| 116 | `Sources/Workspace.swift` | `workspace-geometry-snapshot-dedup` | Early-return in `splitTabBar(_:didChangeGeometry:)` when the incoming `LayoutSnapshot` differs from `tmuxLayoutSnapshot` only by `timestamp` (Bonsplit stamps every snapshot with `Date()`, so synthesized equality never dedupes, and its container re-emits geometry from `onAppear`/`onChange` during SwiftUI remounts). Skips the `@Published` republish, the `.workspacePaneGeometryDidChange` post, and `scheduleTerminalGeometryReconcile()`; keeps the order-gated `surfaceList.registerGeometryChange()` and `scheduleFocusReconcile()` unconditional. Selection/focus changes always pass (carried by `selectedTabId`/`focusedPaneId`). Breaks the layout→publish→layout feedback loop captured in the supermux CPU investigation. Since the 2026-09-30 upstream merge upstream's `didChangeGeometry` defers publishing, the notification and terminal reconcile into `geometryNotificationScheduler.schedule(zeroDelayPolicy: .yieldOnce)` (deferred, latest-wins). The fence is still the first statement and now also requires `!geometryNotificationScheduler.isScheduled` — otherwise X→Y→X inside one yield would dedupe the final X against a stale cache while Y is still pending, and Y would win |
| 117 | `cmuxTests/TabManagerUnitTests.swift` | `workspace-geometry-snapshot-dedup` | Regression test `WorkspaceGeometrySnapshotDedupTests`: a timestamp-only geometry callback must not republish `tmuxLayoutSnapshot`; a real geometry change must still publish (two-commit red/green pair). Rewritten as `async` at the 2026-09-30 upstream merge (geometry is delivered asynchronously): it awaits delivery with `AppKitTestEventPump.waitUntil`/`drain()`; the assertions are unchanged |
| 118 | `README.md` | `readme-fork-rewrite` | Wholesale replaces upstream's README with the supermux one (fork identity, features, build-from-source, upstream credit). The fence wraps the whole file. The `README.<lang>.md` translations stay upstream's apart from the #120 banner |
| 119 | `CONTRIBUTING.md` | `contributing-fork-note` | One fenced blockquote after the H1: upstream's guide is kept for reference; fork issues/PRs go to rajinsyed/supermux and SUPERMUX.md is the fork contract |
| 120 | `README.ja.md` | `readme-translation-banner` | Same one-line fenced banner (localized per file) prepended to all 20 `README.<lang>.md` translations: "this is the upstream cmux README; the fork's additions are in README.md". Only the `ja` file is registered here; the fence id is identical in all 20 |
| 122 | `.github/test-determinism-allowlist.txt` | `unfenced` | Three grandfathered entries for supermux-owned tests the determinism gate flags by heuristic: `SupermuxMobileChangesStoreSyncTests.swift` (assert-on-duration — static assertion on a configured RPC timeout, not a measured duration) and `SupermuxMobileObserversTests.swift` + `SupermuxMobileRunObserverTests.swift` (sleep-then-assert — prove-silence tests must outwait the poke throttle window). Data file like #4; re-add the three lines if a merge drops them |
| 123 | `scripts/ci/run-app-host-xcodebuild.sh` | `actool-crash-retry`, `ci-exclude-icon-composer` | One fenced `elif` in the retry-reason chain (`Command CompileAssetCatalogVariant failed` retries as "asset catalog compiler crash") plus a fenced trailing `'EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon'` build setting on the xcodebuild invocation. Since the 2026-09-30 upstream merge the trailing setting follows upstream's `"${attempt_xcodebuild_arguments[@]}"` (which may add `-resultBundlePath`); upstream moved `TEST_RUNNER_CMUX_TEST_PROCESS=1` into the `app_host_test_runner_environment` array, so the fence no longer has to enclose an env prefix. ibtoold crashes rendering the fork's Icon Composer `AppIcon*.icon` files (#17) on some CI VMs — deterministically on affected machines, so the exclusion is the fix and the retry is a backstop for other asset-catalog flakes; upstream has no `.icon` files, so this crash class is fork-introduced. The app icon is cosmetic in headless CI |
| 124 | `scripts/ci/compile-app-host-test-product.sh` | `ci-exclude-icon-composer` | `caller_settings+=('EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon')` before the canonical `build-for-testing` loop (same rationale as #123). Upstream deleted the `ci.yml` "Build for runtime regressions" step at the 2026-09-30 upstream merge (`tests-build-and-lag` now restores a prebuilt product), so only the exclusion was re-homed here; the old fenced 2-attempt `actool-crash-retry` loop was dropped |
| 125 | `.github/workflows/perf-activation.yml` | `actool-crash-retry` | The "Build tagged app" step's single `reload.sh` invocation is wrapped in a fenced 2-attempt retry loop (the pattern `ci.yml` carried as #124 before the 2026-09-30 upstream merge re-homed #124 to an exclusion-only fence) and sets `CMUX_EXCLUDE_ICON_COMPOSER=1` (consumed by #126) |
| 126 | `scripts/reload.sh` | `ci-exclude-icon-composer` | Fenced env hook: `CMUX_EXCLUDE_ICON_COMPOSER=1` appends `'EXCLUDED_SOURCE_FILE_NAMES=AppIcon*.icon'` to `XCODEBUILD_ARGS` so headless CI reload builds skip Icon Composer rendering (see #123); local/dev reloads are unaffected |
| 127 | `.github/workflows/ci-macos.yml` | `release-build-timeout` | `release-build`'s `timeout-minutes` raised 60 → 120 (fenced): a cold universal Release build exceeds 60 minutes on the fork's runner pool, and a job killed at the cap never seeds the DerivedData cache, so the upstream cap could never converge on the fork. Upstream moved every macOS job out of `ci.yml` into `ci-macos.yml` at the 2026-09-30 upstream merge; the fence moved with the `release-build` job |
| 128 | `Sources/SidebarWorkspaceSnapshotFactory.swift` | `sidebar-flatrow-activity` | Upstream (0.65) extracted per-workspace snapshot building out of `TabItemView` into this parent-side factory; the snapshot-resolution part of the #2 fence moved with it: resolves `SupermuxWorkspaceActivityResolver.activity(for:)` + `activityByAgentKey(for:)` once per snapshot, filters duplicate agent lifecycle rows out of `metadataEntries` via `SupermuxSidebarAgentStatusRows.droppingAgentStatusRows`, and passes `supermuxActivity` as the Snapshot's LAST parameter (#113). The metadata filter is gated OFF when `isAppKitSidebarListEnabled`: the factory feeds BOTH list implementations, and #295 ports only the working spinner to the AppKit row; retaining metadata there preserves the needs-input/ready text that AppKit does not visualize. Since the 2026-09-30 upstream merge the activity fence sits before upstream's `statusEntries = SidebarCompactStatusGlyph.partition(…)` / `activeCodingAgentCount` / `compactStatusGlyph`, and the `metadataEntries` filter input is upstream's `statusEntries.rows` (upstream: `showsMetadata ? statusEntries.rows : []`) instead of `workspace.sidebarStatusEntriesInDisplayOrder()`; the AppKit-gated branch passes `statusEntries.rows` unfiltered |
| 129 | `Sources/SidebarWorkspaceRowActions.swift` | `sidebar-hide-project-workspaces` | One fenced defaulted `var supermuxMenuVisibility: (UUID, Set<UUID>) -> SupermuxRowMenuVisibility = { _, _ in .allVisible }` at the end of the actions struct — keyed by the row's workspace id, not an index (rows hold no store reference under upstream's 0.65 snapshot boundary, so menu enablement resolves through the actions bundle on menu open, like `currentWindowMoveTargets`). The provider is bound in the #2 actions-bundle construction; the value type lives in fork-owned `Sources/Supermux/SupermuxRowMenuVisibility.swift` (now also carrying `canMoveUp`/`canMoveDown` from the #131 stepped-plan check); consumed by the #114 menu builder. Defaulted so upstream construction sites (tests) compile unchanged. The fenced defaulted `var supermuxMenuVisibility` stays last, after upstream's new `let onPointerDragEligibilityChange` |
| 130 | `Sources/FeatureFlags.swift` | `appkit-sidebar-default-off` | **FIVE fenced regions** (was two before the 0.64.21 merge) pinning upstream's `sidebar-appkit-list-experiment` OFF on the fork: (a) `appKitSidebarListDefault` flipped `true` → `false`; (b) a shared `supermuxIngestibleRemoteValue(_:for:)` gate; and one-line wraps at **all three** `remoteValuesByKey` write sites — (c) the `init` remote-cache seeding, (d) `applyRemoteFlagValues(_:)` (the production PostHog control-plane path this merge added), and (e) `applyLoadedFlags()` (now test-only). **Invariant:** a remote `true` for `sidebar-appkit-list-experiment` is never ingested at ANY site, a cached `true` is evicted, and a remote `false` still ingests as upstream's kill switch — a Debug opt-in cannot outlive an upstream emergency disable. The gate is keyed off `appKitSidebarListFlag.key`, not a string literal, so an upstream key rename cannot silently disarm it. **ANY new writer of `remoteValuesByKey` must route through the gate.** Why: a remote rollout outranks both the default and the user's local override, and `appKitWorkspaceScrollArea` then renders `SidebarWorkspaceTableView` directly, bypassing the SwiftUI list that hosts most supermux sidebar features (Projects section, project-workspace nesting/hiding, unified row style); only the working activity spinner is ported to AppKit via #295. Debug local override remains the opt-in; while it is on, fork-owned `SupermuxMainListFilter.tabsForMainList` returns the list unfiltered and #128's metadata filter is bypassed, so the AppKit list behaves like stock cmux (no hidden rows for its full-list NSMenu actions to destroy). Three upstream tests currently contradict this fence — see SUPERMUX.md "Known limitations", entry on `PostHogAnalyticsPropertiesTests`. Re-evaluate when porting the Projects section to the AppKit list. Since the 2026-09-30 upstream merge region (c) sits inside upstream's `remoteValuesByKey = pinsFlagsToLocalValues ? [:] : Self.allFlags.reduce…` closure |
| 131 | `Sources/TabManager+AdjacentWorkspaceReordering.swift` | `sidebar-hide-project-workspaces` | `reorderWorkspace(tabId:by:)` — the ONE adjacent-move entrypoint shared by the sidebar context menu, the menu-bar/keyboard shortcut (`moveSelectedWorkspace`), and the socket `workspace.action move_up`/`move_down` verbs — is fenced to route through fork-owned `TabManager.supermuxSteppedReorderTarget` (`Sources/Supermux/SupermuxWorkspaceReorderStepping.swift`): steps over project-hidden rows to the nearest visible neighbor and returns `false` (no mutation) when the clamped destination (pin tier / group section, via the coordinator's public `workspaceReorderPlan`) would not change the visible flat-list order. The same helper drives the #114 Move Up/Down enablement, so menu state and mutation agree. With no hidden rows (or under the AppKit list, where #130's filter gate empties the hidden set) it degrades to upstream's `currentIndex + offset` |
| 132 | `Sources/SidebarWorkspaceRowInput.swift` | `sidebar-hide-project-workspaces` | Two fenced defaulted fields `supermuxVisibleIndex`/`supermuxVisibleCount: Int?` (visible-flat-list ordinal/total for the row's VoiceOver "workspace N of M" announcement; `nil` falls back to the full-list values) plus the fenced pass-through in `rowSnapshot(list:)`. `index`/`workspaceCount` keep upstream's full-list semantics (⌘-number digits, shift-range selection, `lastSidebarSelectionIndex`). Values computed in the #2 row-input construction from `renderContext.projectHiddenWorkspaceIds`; consumed by the fenced `accessibilityTitle` in `TabItemView` (#2). Defaulted so upstream construction sites compile unchanged |
| 133 | `Sources/SidebarWorkspaceRowSnapshot.swift` | `sidebar-hide-project-workspaces` | The matching two fenced defaulted fields on the row snapshot value (`supermuxVisibleIndex`/`supermuxVisibleCount: Int?`); synthesized `Equatable` covers them, preserving the row's change-detection contract. See #132 |
| 134 | `cmuxTests/RemoteTmuxMirrorCloseDetachTests.swift` | `keep-window-on-last-close` | Repurposes two upstream tests to the fork contract (#60, same class as #115/#45/#81/#83): `explicitDetachOfDedicatedLastMirrorClosesOwningWindow` → `explicitDetachOfDedicatedLastMirrorLeavesEmptyHomeWindow` (window stays open/visible/listed with `tabs.isEmpty` instead of closing), and `remoteSessionEndOfDedicatedLastMirrorKeepsOwningWindowUsable`'s replacement-workspace assertion flips `tabs.count == 1` → `tabs.isEmpty` (the fork leaves the empty home, never a fresh local replacement shell) |
| 135 | `cmuxCLITestSupport/ClaudeHookLiveDeliveryTargetTestSupport.swift` | `claude-hook-mock-server-threads` | `startMockServer`'s blocking accept loop and per-connection reader run on dedicated `Thread`s instead of upstream's `DispatchQueue.global(qos: .userInitiated).async`. A blocking `accept()`/`read()` parks its GCD worker for the queue's lifetime; the 0.64.20 app-host under test raises global-pool pressure enough that those blocks could wait indefinitely on the macOS 15 CI runners — the hook CLI's `connect()` completed into the kernel backlog with nobody accepting, all 7 ClaudeHook* tests timed out with zero recorded commands (empirically isolated: the same binary/env/protocol runs clean on the same runner outside the app host). Sibling harnesses with the same upstream pattern (`CLINotifyProcessTestSupport`, `CLICodexHookTimeoutRegressionTestSupport`, `CLIMockSocketServerSupport`) pass in their shards and are left upstream-shaped; apply this fence's pattern to them if shard composition ever surfaces the same starvation there. Upstream #14211 moved this file out of `cmuxTests/` into the `cmuxCLITestSupport` target at the 2026-09-30 upstream merge; the fence carried over unchanged |
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
| 147 | `.github/workflows/ci-guards.yml` | `local-release-script-guard` | Runs the fork-owned `tests/test_supermux_release_stale_artifact.sh` in Linux preflight so the local Release scripts must refresh GhosttyKit, clear stale explicit-module caches and DerivedData products, preserve xcodebuild's status, persist diagnostics, complete the mocked iOS release **before** the self-hosted Mac app shutdown/restart boundary, and exercise the current app + notification-extension production signing/install/launch path without touching a real app or device. Upstream moved the Linux guard steps into `ci-guards.yml` at the 2026-09-30 upstream merge: the step now sits after "Validate release-build timeout guard" with `if: ${{ matrix.group == 'release-notary' }}`, so it runs only when that guard group is routed; unknown indirect inputs (`scripts/supermux-release.sh`, `scripts/supermux-ios-release.sh`) fail open to every group |
| 146b | `Sources/ContentView.swift` | `sidebar-usage-analytics-button` | In `SidebarFooterButtons`, the `shows(.help)` branch mounts the fork's `SupermuxUsageAnalyticsMenuButton()` (`Sources/Supermux/SupermuxUsageAnalyticsMenuButton.swift`, pbxproj ids `50BE0001…00FF`/`…0100` under #3) **immediately after** the usage-limits button of #146 and before upstream's untouched `SidebarHelpMenuButton(onSendFeedback:)` — a purely additive one-line insert. The button opens a token-spend popover (SupermuxKit `UsageAnalytics/` + `UI/SupermuxUsageAnalyticsPopoverView.swift` + `UI/SupermuxUsageAnalyticsChart.swift`) computing per-day, per-model cost from Claude Code's `~/.claude/projects/**/*.jsonl` transcripts and Codex's `~/.codex/sessions/**/rollout-*.jsonl` logs, read-only, with a per-file scan cache in Application Support |
| 148 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableItem.swift` | `supermux-mobile-projects-table-row` | **The row that renders Projects on iPhone.** Upstream 0.64.20 rebuilt the iOS workspace list on `UITableView`; the #97 mount stayed in the now-macOS-only `#else` arm, so the whole fork Projects surface (detail, worktrees, presets, run, actions, editor) was DEAD on iOS from that merge until #148–#151 existed. Two fences: `WorkspaceListChromeKind.supermuxProjects`, and its stable `id` `"chrome.supermuxProjects"`. **Chrome is load-bearing, not cosmetic.** `chromePrefixCount` counts a LEADING `.chrome` run, and the drag-reorder handler subtracts it to map UIKit rows onto SwiftUI workspace indices — a non-chrome row above the workspaces would silently move the WRONG workspace while every range guard still passed. `.chrome` additionally already means forbidden-as-drop-target, non-movable, no workspace lookup, and no native swipe/context menu. The id must NEVER vary with project expansion, or a disclosure becomes a structural change and triggers a whole-table `reloadData()` that destroys the section's animation and hosted state. Pinned by `SupermuxProjectsTableRowTests` |
| 149 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTable.swift` | `supermux-mobile-projects-table-row` | Two fences: `import SupermuxMobileUI`, and the optional `supermuxProjects: SupermuxProjectsTableRowConfiguration?` payload (defaulted `nil`, so upstream call sites need no change). A `nil` payload means the table emits no Projects row at all — a fork phone paired with an upstream Mac renders exactly upstream's list. See #148 |
| 150 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-projects-table-row` | Five fences since upstream's table-engine rewrite (c4dcf650783): `import SupermuxMobileUI`; `isIndividuallyMeasuredModel` returns `false` for `.supermuxProjects` (equal models reuse their height); a `measuredHeight` case through upstream's shared LRU height cache keyed on `.supermuxProjects(projects.heightIdentity)` (a LAYOUT identity, so live activity/PR/run/unread repaints never re-measure the section); a zero-margin `case .supermuxProjects:` in `configure`'s switch over the row model (the shared `.chrome` 8/12 banner margins would double the section's own insets); and a `hostedView(item:model:)` case rendering `SupermuxProjectsTableSection` from the model's payload. Upstream removed `HeightKind`, `dataSource`, `rowChanged` and the configuration-driven content builder: change detection is now `WorkspaceListRowModel` equality, which for Projects is the fork-owned `SupermuxProjectsTableRowConfiguration: Equatable` (`==` is `!renderChanged(previous:next:)`). The row-model half lives in #502. See #148 |
| 151 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Table.swift` | `supermux-mobile-projects-table-row` | Four fences: `import SupermuxMobileUI`; the `supermuxProjectsRowConfiguration` helper; the `items.append(.chrome(.supermuxProjects))` **inside the leading chrome run** (immediately after the connection-chrome switch, before groups/workspaces — see #148 on why the position is load-bearing); and the `supermuxProjects:` argument, bound to a `let` OUTSIDE the memberwise init because that expression already overwhelms the type checker. See #148 |
| 152 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `mobile-event-liveness-observation`, `mobile-liveness-background-gate` | Keeps per-envelope liveness bookkeeping (`lastTerminalEventAt` and the consecutive-probe counter) out of Swift Observation, and makes the render-grid liveness watchdog foreground-only both before a probe starts and when an already-started probe completes. The timer deliberately stays on `.main`; only the recovery decision is gated. Regression coverage: #154 |
| 153 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellRenderGridLivenessTestSupport.swift` | `mobile-liveness-background-gate` | Adds a delayed-success probe mode to the existing scripted liveness router so #154 can deterministically prove that a probe started just before backgrounding cannot publish a late recovery. The pre-existing held-probe mode still returns no response and remains unchanged |
| 154 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellEventStreamPerformanceTests.swift` | `unfenced` | Whole fork-owned Swift package test file in the upstream `CmuxMobileShellTests` target. Proves high-frequency event liveness timestamps update without Observation notifications, backgrounded watchdog ticks start no probes, and an in-flight probe completing after background cannot publish recovery |
| 155 | `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxTailscaleRouteProof.swift` | `tailscale-packet-tunnel-proof` | Accepts a missing `NWPath.localEndpoint` for an established packet-tunnel route while retaining upstream's generation guard and every route-substitution check. A present local endpoint must still equal a proven Tailscale self-address; the authority generation, exact interface identity and self-address set, active connection-path interface, peer address, and peer port remain fail-closed |
| 156 | `Packages/iOS/CmuxMobileTransport/Tests/CmuxMobileTransportTests/CmxTailscaleRouteProofTests.swift` | `tailscale-packet-tunnel-proof` | Regression coverage for #155: an established route succeeds when Network.framework omits the local endpoint, while a present-but-wrong local address still fails. Upstream-owned coverage also proves a newer authority generation throws `routeGenerationChanged` and a substituted interface throws `interfaceChanged` |
| 157 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession.swift` | `mobile-rpc-client-work-quota` | Backpressures the phone's multiplexed RPC writer against `MobileHostRPCWorkQuota` instead of letting post-pairing bootstrap fan out enough requests for the Mac host to close the entire connection as `rpc work capacity exceeded`. `PendingWrite` carries the decoded payload byte count; the session tracks only requests already sent and still awaiting a host response, mirrors both the host's request-count and aggregate-byte policies, and keeps one request slot free because the client may receive a response just before the host actor removes that response task. A host response or teardown wakes the writer; requests cancelled or timed out before transmission are skipped when capacity becomes available. Upstream #14695 control-stream repair re-queues stranded frames and sends a verification probe. Both new `PendingWrite` sites carry `decodedFrameByteCount` (fenced). In `resolveControlFramesStranded(before:)` a fence first releases the stranded request's slot (`releaseRequestWorkCapacity(requestID:)`), because a replaced stream can never deliver its answer; a resend re-enters admission with the recorded decoded size (fallback `written.frame.count`). The `verifyReplacedControlStream` probe carries `decodedFrameByteCount: payload.count`. The writeLoop keeps upstream's `Task<UInt64?, any Error>` with the fork capacity-wait fence in front of it |
| 158 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileCoreRPCSession+IndependentEvents.swift` | `mobile-rpc-client-work-quota` | Releases the client-side work-quota slot as soon as any response id returns, before checking whether the local caller is still pending. This is required because a timed-out or cancelled caller may still receive the host's late response; ignoring that response would leak one writer slot for the rest of the session |
| 159 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileCoreRPCSessionPipelinedTests.swift` | `mobile-rpc-client-work-quota` | Red/green regression for #157–#158. Enqueues one more request than the client's host-compatible window, proves the extra request is not written while all earlier responses are outstanding, then delivers one response and proves exactly one queued request advances. Before #157 the writer immediately sent the whole burst and the expectation failed |
| 160 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+PairedMacPersistence.swift` | `paired-mac-persistence-result` | Makes `persistPairedMacFromTicket` report success only after the authoritative store mutation actually lands. The result now starts `false` and flips to `true` after either ordinary `upsert` or an accepted conditional route upsert; losing `ifStillCurrent` authority, crossing a team-scope boundary, or a conditional rejection can no longer return `true` while writing nothing. This closes the state where pairing reports `.connected` but `hasKnownPairedMac` and the SQLite store remain empty |
| 161 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobilePairedMacPersistenceFailureTests.swift` | `paired-mac-persistence-result` | Red/green regression for #160. Supplies `ifStillCurrent: { false }`, proves persistence returns `false`, leaves the store empty, and does not set the known-Mac hint. Before #160 the serialized operation was skipped but the method returned `true` |
| 162 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileMacBuildCompatibilityPolicy.swift` | `official-ios-persistence-scope` | Adds `persistenceScope(from:)`, making compatibility policy authoritative over storage partitioning. Development policy retains the detected iOS tag; official policy discards it. This matters for personal-team Release builds signed under a `dev.cmux.ios.<suffix>` bundle id: bundle metadata looks tagged, but Release compatibility correctly allows Stable/Nightly Macs and must not wrap storage in an inner exact-development-tag filter that silently rejects those same rows. Sits beside upstream's new `developmentAdditionalInstanceTags` / `developmentExpectedInstanceTag` / `isNonDevelopmentTag` |
| 163 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileMacBuildCompatibilityPolicyTests.swift` | `official-ios-persistence-scope` | Regression coverage for #162: official policy maps a detected sideload tag to no persistence scope, while development policy retains the exact same scope. Upstream's `case development` now carries associated values, so the test uses `.development(expectedInstanceTag: "fix-mobile-ui").persistenceScope(from:)` |
| 164 | `ios/cmuxPackage/Sources/cmuxFeature/CMUXMobileRootScene.swift` | `official-ios-persistence-scope` | In `makeStore`, separates the raw bundle-detected scope from the effective persistence scope. Build compatibility is resolved first, then `persistenceScope(from:)` supplies the value used by `IOSBuildScopedPairedMacStore` and backup-client partitioning. Debug tagged builds remain isolated; sideloaded Release builds use official untagged persistence and can save the Stable/Nightly Mac they already passed live compatibility checks against |
| 168 | `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Config/GhosttyConfig.swift` | `ghostty-bold-is-bright-mobile-theme` | Mirrors Ghostty's `bold-is-bright` compatibility alias into the Swift config model as `boldColor = "bright"`. Ghostty itself still honors this legacy key, but the Swift parser previously ignored it, so the Mac producer rendered bold ANSI 0–7 through bright palette 8–15 while exporting a phone config with no bold-color behavior |
| 169 | `Packages/macOS/CmuxTerminalCore/Tests/CmuxTerminalCoreTests/GhosttyConfigBoldColorTests.swift` | `ghostty-bold-is-bright-mobile-theme` | Parser regression for #168: `bold-is-bright = true` resolves to the same canonical `"bright"` value as `bold-color = bright` |
| 170 | `cmuxTests/MobileHostTerminalThemeTests.swift` | `ghostty-bold-is-bright-mobile-theme` | End-to-end host-theme regression for #168: parses the legacy alias, serializes the actual mobile host theme payload, decodes it as the phone does, and proves `bold-color = bright` survives into Ghostty directives |
| 171 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridVisualSnapshot.swift` | `verified-replay-semantic-bold-color` | Verified replay compares bold default/palette foregrounds by their semantic source (and palette index) rather than config-dependent resolved RGB. Literal RGB remains exact. This prevents a stale/legacy host theme from freezing an otherwise identical terminal grid behind a blank verification layer while #168 repairs authoritative theme propagation |
| 172 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/MobileTerminalRenderGridVisualSnapshotTests.swift` | `verified-replay-semantic-bold-color` | Regression for #171 using the physical-device mismatch values: equal bold palette semantics compare equal across normal-vs-bright resolved RGB, different palette indices still fail, and bold literal-RGB differences remain exact |
| 173 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift` | `ios-terminal-native-scroll` | Feeds each authoritative render-grid frame's active screen into the mounted surface after successful verified or legacy application, selecting bounded primary-history physics versus alternate-screen wheel delivery. Ported from upstream PR #9762 head `1420c2c972` |
| 174 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttyRuntime.swift` | `ios-terminal-native-scroll` | Processes Ghostty scrollbar actions in all build configurations, updates the surface's authoritative history boundary on the main actor, and keeps the stress-harness/logging extras DEBUG-only. Ported from upstream PR #9762 |
| 175 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+LocalScrollbackScroll.swift` | `ios-terminal-native-scroll` | Delivers local mirror scrolling as precise pixel deltas (one Ghostty cell height per logical line) and re-runs bounded idle resynchronization when the serialized local-apply pump drains. Ported from upstream PR #9762. The work closure now uses upstream's `workQueue.asyncPriority` |
| 176 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplay.swift` | `ios-terminal-native-scroll` | Sizes the frozen verified-replay container through bounds/position rather than frame so its native-scroll transform does not corrupt geometry. Ported from upstream PR #9762 |
| 177 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplayFrozenPresentation.swift` | `ios-terminal-native-scroll` | Carries native-scroll translation on the frozen container only; the copied content layer deliberately does not inherit the renderer transform, preventing double translation during verified replay. Ported from upstream PR #9762 |
| 178 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-native-scroll` | Replaces the million-point unbounded primary-screen surrogate with authoritative bounded history geometry, UIKit tracking/rubber-band behavior, sub-row presentation translation, gesture-end tail flushing, and deterministic settle/resync. Every release stops at the finger-selected position—terminal scrolling intentionally has no inertial coast. The scroll view uses a zero deceleration rate, and end-drag unconditionally resets its pan recognizer plus current offset because physical iOS 26 can resume already-committed physics after a target-offset pin. Bounded history is used only when the local mirror owns presentation; Mac-authoritative verified sessions and alternate-screen TUIs retain unbounded wheel delivery. Ported and hardened from upstream PR #9762. In `flushPendingScrollIfNeeded`'s line path (upstream #10592 whole-line quantization with a fraction carry), a fence sets `dispatchLines = lines` and zeroes `linePathFractionCarry` when `usesBoundedNativeScroll`, so bounded primary history keeps fractional/precise-pixel delivery; alt-screen and unbounded paths keep upstream's quantization. The unfenced guard `pendingScrollLines != 0 || pendingScrollPixels != 0` remains. The #473 lint fence around `localPixelScrollState` is gone (upstream carve-out). At the 2026-10-01 upstream merge `enqueueScrollMechanicsDelta` also applies upstream's shared-sizing `gridDisplayScale` (displayed cell height for lines, pixels divided by it), matching upstream's own delta path; `terminalNativeScrollGeometry` still uses the unscaled cell height (see SUPERMUX-UPGRADES.md 2026-10-01 watch-outs) |
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
| 193 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalOutputDelivery.swift` | `ios-terminal-output-backlog-coalesce` | Caps the per-surface pending render-grid frame queue at `maxTerminalOutputPendingBeforeReplayCoalesce` (24). Physical traces measured 90+ nonreplaceable alt-screen deltas queued during a fast scroll, draining serially for up to 4 s after touch-up — the real "phantom momentum". Past the cap the whole backlog is replaced by one authoritative replay through the standard rebuilt-surface barrier path (queue cleared, stream token rotated, stale acks invalidated). Upstream added its own 128-entry hard overflow cap (`TerminalOutputDeliveryQueue.maxPendingDeliveries`, replay `.droppedFrame`); the fork's 24-frame coalesce block sits immediately after that check — upstream's bounds memory, the fork's fixes gesture latency |
| 194 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-output-backlog-coalesce` | Declares the backlog cap constant beside the replay-barrier fail-open constant (~0.5 s of 60 Hz frames: steady output never trips it; a gesture backlog cannot replay for seconds) |
| 195 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalOutputBacklogCoalesceTests.swift` | `unfenced` | Whole new regression for #193: with the in-flight chunk never acknowledged (slow verified apply), frames past the cap must collapse into a replay barrier with the pending queue cleared, instead of queuing unbounded deferred paints |
| 196 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalScrollSpeedPreference.swift` | `unfenced` | Whole new fork file: shared UserDefaults-backed terminal scroll-speed multiplier (0.25×–1.5×, default 1.0, clamped, non-finite falls back). Read by Settings and by mounted surfaces |
| 197 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-native-scroll` | (Amends #178's file) Adds `scrollSpeedMultiplier` (didSet rejects non-positive values) applied in `enqueueScrollMechanicsDelta` so wheel-line delivery — alt-screen TUIs and unbounded paths — scales with the user preference; bounded primary history remains 1:1 direct manipulation. `enqueueScrollMechanicsLines` keeps the fork's `pendingScrollLines += lines` (upstream's new `cellHeight / 14` wheel divisor is what the fork's `enqueueScrollMechanicsDelta` already does) |
| 198 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileDisplaySettings.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` preference: clamped write-through beside `terminalScrollbackRows`, seeded from defaults in init |
| 199 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileSettingsView.swift` | `ios-terminal-scroll-speed` | Adds the Display-section "Terminal Scroll Speed" slider (tortoise/hare, 0.05 step, live value label, footer) bound to `displaySettings.terminalScrollSpeed`, plus the `CMUXMobileCore` import. Accessibility id `MobileSettingsTerminalScrollSpeed` |
| 200 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/GhosttySurfaceRepresentable.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` input and applies it to the mounted surface's `scrollSpeedMultiplier` in `makeUIView` and every `updateUIView` pass, so slider changes take effect live without remount. The same file's screen-selection change remains registered as #173 |
| 201 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-terminal-scroll-speed` | Adds the `terminalScrollSpeed` computed accessor beside the other display-settings accessors. The same file's workspace-tools mount remains registered as #108 |
| 202 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+TerminalArtifacts.swift` | `ios-terminal-scroll-speed` | Passes `terminalScrollSpeed` into `GhosttySurfaceRepresentable` at the terminal mount site |
| 203 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalAltScrollDirectApplyPolicy.swift` | `unfenced` | Whole new fork file: pure policy deciding when an alternate-screen repaint delta may skip the verified freeze/apply/present/read-back/verify pipeline — non-full frames within 0.8 s of the surface's last alt-screen scroll input. Backwards clocks fail closed; full frames always verify |
| 204 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-alt-scroll-direct-apply` | Adds `terminalAlternateScrollLastInputAtBySurfaceID` (declared beside the scroll budgets, initialized empty, cleared on reconnect reset, removed on surface teardown) |
| 205 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalOutputDelivery.swift` | `ios-terminal-alt-scroll-direct-apply` | In `requiresVerifiedReplayApplication`, alternate-screen delta frames inside the scroll-activity window return `false`, routing them through the ordered legacy VT-patch apply (same bytes, same stateSeq floors, no per-frame Metal fence). Gesture repaints stop clumping; the first verified delta after the window re-checks pixel exactness and drift triggers the existing full-replay recovery. Registered separately from the same file's #193 backlog coalesce. Upstream rewrote `requiresVerifiedReplayApplication` as early-return guards; the fork block sits right after `guard let frame = delivery.sourceRenderGridFrame else { return true }`, before the primary-only guard, and additionally requires `MobileTerminalRenderGridRevisionContinuity.admits(frame, delivered:)` (upstream's own direct-path safety rule), so a stale-base/resize delta is never VT-patched directly |
| 206 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalScrollDelivery.swift` | `ios-terminal-alt-scroll-direct-apply` | Stamps the surface's last alt-screen scroll-input uptime whenever the budget admits gesture lines, opening the direct-apply window. Registered separately from the same file's #191 budget |
| 207 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalAltScrollDirectApplyPolicyTests.swift` | `unfenced` | Whole new regression for #203: in-window deltas apply directly, out-of-window and no-input deltas stay verified, full frames always verify, backwards clocks fail closed |
| 208 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/TerminalAlternateScrollLineQuantizer.swift` | `unfenced` | Whole new fork file: signed fractional-line accumulator that emits only whole alternate-screen scroll lines toward the Mac. Root cause of the "slider does nothing" feel: fractional gesture packets (0.03–0.11 lines each) were rounded up to a full line PER RPC by host-side minimum-magnitude-1 wheel handling, so TUI scroll speed tracked packet rate, not finger travel — physical trace showed a 29 pt drag delivering 0.70 fractional lines across 101 packets yet scrolling far more |
| 209 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-terminal-alt-scroll-quantize` | Adds `terminalAlternateScrollQuantizersBySurfaceID` (declared with the other scroll state, initialized empty, cleared on reconnect reset, removed on surface teardown) |
| 210 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+TerminalScrollDelivery.swift` | `ios-terminal-alt-scroll-quantize` | After the budget admits alt-screen lines, runs them through the per-surface quantizer and forwards only the whole-line portion (fractions carry). Registered separately from the same file's #191 budget and #206 activity stamp |
| 211 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/TerminalAlternateScrollLineQuantizerTests.swift` | `unfenced` | Whole new regression for #208: fractions accumulate before any emit, whole lines pass with carry, reversal unwinds signed carry, non-finite ignored, and 1× vs 0.25× delivery now differs ~4× per identical finger travel |
| 212 | `Sources/AppDelegate+DockShortcutRouting.swift` | `run-shortcut-dock-routing` | Adds all fork shortcut actions (`supermuxToggleRun`, `supermuxWorkspaceSwitcherNext/Previous`, `supermuxCommit`, `supermuxCommitAccelerator`, `supermuxNewClaudeHarness`) as one `.mainContainer` case to upstream's deliberately-exhaustive Dock-routing switch. Upstream added this file with no `default:` so every action must be classified; all fork actions target app/workspace/project state, never a surface tree, so none reroute into the Dock. Re-apply: add the fenced `case ...: .mainContainer` group before the closing brace of `dockShortcutRoutingDisposition` |
| 215 | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/ArrowlessPopoverAnchor.swift` | `popover-dynamic-height-reanchor` | Defers initial show, dismissal, and hosted-root layout until after `NSViewRepresentable.updateNSView` returns, preventing AppKit child-window ordering from re-entering SwiftUI/Observation mid-update. When an already-visible arrowless popover's content changes size, updates `contentSize` and re-shows the same popover against its original synthetic anchor so the edge stays fixed. Deferred work coalesces and rapid open→close cancels the pending show. Fixes the Usage Limits and Token Usage popover crash/drift paths. Since the 2026-09-30 upstream merge the base is upstream's rewrite (`presentationAnimation`, `CmuxPopoverGroup` membership, `updatePresentationBinding`/`updatePresentationAnimation`, `closingPopovers` teardown ownership, `dismiss(resetPresentation:)`, `popoverWillClose`, `dismantleNSView`, #13442's no-binding-write dismiss). `deferDismissal` schedules `dismiss(resetPresentation: false)` (the binding is already false on that path); the designated init takes upstream's `presentationAnimation`/`group` plus the fenced defaulted `showPopover:`; a new fenced convenience `init(isPresented:showPopover:)` (`.automatic`, `group: nil`) exists only so the #216 tests compile unchanged |
| 215a | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/CmuxPopoverMutation.swift` | `popover-dynamic-height-reanchor` | Schedules coalesced popover mutations on the next common-mode main-run-loop turn instead of a main-actor task, because macOS 27 can run that task within the same AppKit layout cycle; generation checks preserve cancellation and rescheduling semantics |
| 215b | `Packages/macOS/CmuxAppKitSupportUI/Sources/CmuxAppKitSupportUI/Popover/ArrowlessPopoverRootViewUpdatePolicy.swift` | `popover-dynamic-height-reanchor` | Changes first presentation from synchronous hosted-root mutation to deferred presentation, and treats dismissal as no root refresh; visible content updates retain their deferred path |
| 216 | `Packages/macOS/CmuxAppKitSupportUI/Tests/CmuxAppKitSupportUITests/ArrowlessPopoverRootViewUpdatePolicyTests.swift` | `popover-dynamic-height-reanchor` | Focused coverage for next-run-loop deferral/coalescing/cancellation, deferred first presentation and cancellation, dismissal skipping hosted-root refresh, visible resize/reanchor planning, subpixel jitter, and hidden/invalid no-ops |
| 217 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceActiveSurface.swift` | `ios-pane-actions` | Adds the captured close-target model and resolves the visible terminal, generic Mac surface, phone-local browser, streamed browser, or Simulator into the exact pane the shared close action must address |
| 218 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-pane-actions` | Stores the pending pane-close target and Simulator-create request, mounts the shared confirmation, passes close availability/action into the title menu and Simulator creation into the surface picker, cancels stale Simulator creates when another surface wins, and exposes the existing selection/toast seams to the fork-owned action extension. `toasts` stays internal in a fence (upstream keeps it `private`); `browserCreateRequest` is internal inside the fence; `canCreateSimulator: canCreateSimulatorPane` follows upstream's `isSSHComputer` in the picker value |
| 219 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+SupermuxPaneActions.swift` | `ios-pane-actions` | Whole-file fork extension: one capability-gated action path captures and confirms the visible pane, closes phone-local browsers locally, closes every remote panel kind through `mobile.supermux.pane.close`, creates native Simulator panes through `mobile.supermux.simulator.create`, activates the returned stream descriptor, and reports failures without optimistic state drift |
| 221 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenuContent.swift` | `ios-pane-actions` | Two fences: `import SupermuxMobileUI`, and, after the creation section (New Workspace / New Terminal / New Browser) in `makeElements()`, appends `SupermuxPaneMenuControls(canCreateSimulator:createSimulator:).makeMenuElement()` (a capability-gated inline New Simulator `UIMenu`) when non-nil. Upstream 02f0ea192bd (#15486) moved the picker from a SwiftUI `Menu` to a presentation-time `UIMenu` built in this new file, so `TerminalPickerMenu.swift` no longer carries fences. Close Pane lives in the workspace title menu |
| 222 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenuValue.swift` | `ios-pane-actions` | Carries snapshot-stable `canCreateSimulator` availability into the equatable native surface-picker value. The three fences (stored property, defaulted init param, assignment) sit AFTER upstream's `sshTabLayout`/`isSSHComputer` fields; the init param is last and defaulted |
| 223 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/TerminalPickerMenuActions.swift` | `ios-pane-actions` | Carries the shared Simulator-create closure emitted by the surface picker. Declared `var createSimulator: () -> Void = {}` — keep it DEFAULTED (upstream's own pattern for `createSSHTab`), never a required memberwise param: upstream's `TerminalPickerMenuPresentationTests` (and any new upstream call site) construct `TerminalPickerMenuActions(...)` without the fork field |
| 224 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceActiveSurfaceTests.swift` | `ios-pane-actions` | Behavior coverage that terminals target the selected terminal, generic Mac surfaces and streamed browser/Simulator surfaces target their panel ids, the phone-local browser targets local close, and missing remote ids fail closed |
| 225 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/TerminalPickerMenuValueTests.swift` | `ios-pane-actions` | Verifies Simulator-creation availability participates in the surface picker’s equatable identity and defaults hidden against unsupported/upstream hosts. (the fork test no longer passes the upstream-removed `snapshotRows:`) |
| 226 | `ios/cmuxUITests/cmuxUITests.swift` | `ios-pane-actions` | End-to-end UI coverage on the local-browser fallback: Close Pane is absent from the surface picker, and the workspace-title Close Pane action confirms and dismisses the captured phone-local browser. Since the 2026-09-30 upstream merge there is no browser × (`MobileBrowserCloseButton`; #220 retired), so `testWorkspaceSurfacePickerClosesTheLocalBrowserThroughSharedPaneAction` uses the web view (`app.webViews.firstMatch`) as its "local browser is up" probe and the old "tap browser × → Cancel" leg is gone |
| 227 | `cmuxTests/SimulatorPanelIntegrationTests.swift` | `ios-pane-actions` | Pins the Mac-side generic close invariant for Simulator panels: `Workspace.closePanel(force:)` removes the Simulator while preserving the sibling terminal, matching the RPC handler’s type-agnostic mutation path |
| 230 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentLaunchEnvironmentPolicy.swift` | `ccx-resume-launcher` | Adds the non-secret `CMUX_CLAUDE_RESUME_LAUNCHER` capture key, accepts only the current user's standardized `~/.local/bin/ccx`, retains it only for Claude restores, and keeps arbitrary launcher paths and secrets outside the replay environment. In `safeEnvironmentKeys` the `claudeResumeLauncherEnvironmentKey` fence sits right after `CMUX_CUSTOM_CLAUDE_PATH`, before upstream's `CMUX_CUSTOM_AMP_PATH`/`CMUX_CUSTOM_CODEX_PATH`; upstream's new `inputEnvironmentKeys` (out-of-process hook capture) intentionally also sees `CMUX_CLAUDE_RESUME_LAUNCHER` |
| 231 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift` | `ccx-resume-launcher` | When a captured Claude launch carries the validated ccx marker, builds `<ccx> --resume <session-id>` instead of replaying expanded ccx-generated Claude arguments; plain Claude keeps the upstream wrapper-routed argv |
| 232 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentRestorePlanner.swift` | `ccx-resume-launcher` | Threads captured launch environment into resume argv resolution and preserves the direct ccx executable while attaching the provider/session-bound one-shot restore authorization. In `routeManagedWrapper` the fence sits after upstream's `restoreLaunch` guard, Subrouter Codex and Subrouter Claude (`sr claude`) routes and `managedWrapperCustomExecutableEnvironment`, and replaces only upstream's final `guard let first …, lastPathComponent == executableName` with the fork's three steps (`guard let first`, the Claude ccx early return, the executable-name guard) |
| 233 | `Sources/RestorableAgentSession.swift` | `ccx-resume-launcher` | Threads the captured launch environment through the app-side shared resume-argument builder so persisted prepared arguments and inline fallback restore both honor ccx |
| 234 | `CLI/cmux.swift` | `ccx-resume-launcher` | Threads the selected replay environment through hook-side resume argv generation so `surface.resume.set` publishes the same ccx-aware command as app-side restore planning |
| 235 | `Sources/SurfaceResumeCommandCanonicalizer+PortableAgentExecutable.swift` | `ccx-resume-launcher` | Recognizes a validated ccx executable in inline stored restore commands and attaches restore authorization without rewriting ccx to the ordinary Claude wrapper |
| 236 | `Packages/macOS/CMUXAgentLaunch/Tests/CMUXAgentLaunchTests/SupermuxCCXResumeLauncherTests.swift` | `unfenced` | Whole-file headless regression coverage for direct ccx restore, one-shot authorization, secret exclusion, Claude-only marker isolation, and invalid-marker fallback to ordinary Claude |
| 228 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `ios-workspace-toolbar-persistent-actions` | Keeps the fork's project Run, Changes, Files, and Close Pane entries in the workspace title menu while leaving upstream's chat-less toolbar structure untouched. Fences own the run-session state, two sheet bindings, keyboard-dismiss parity, `SupermuxWorkspaceToolsMenuEntries`, the title-menu `isEnabled` extension, and `toolEntriesFingerprint` plumbing in `WorkspaceTitleMenuValue.swift` so `.equatable()` refreshes when entry availability or run state changes. `isEnabled` is upstream's `hasTitleMenuActions || canReconnect || sshFilesTerminalID != nil || connectedDevicesMenuItem != nil` plus the fenced fork disjuncts; `toolEntriesFingerprint:` follows upstream's `connectedDevices:` (added at the 2026-10-01 upstream merge). The fingerprint field and its test are #500/#501 |
| 238 | `ios/Config/Shared.xcconfig` | `ios-supermux-brand` | `PRODUCT_DISPLAY_NAME` = `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (was `cmux`), the iOS app's home-screen name. `SUPERMUX_IOS_DISPLAY_SUFFIX` (new fork variable, empty default) lets dogfood builds append `" <tag>"` from the command line without passing `PRODUCT_DISPLAY_NAME` itself. `PRODUCT_NAME` stays `cmux` on purpose — it names the built product (`cmux.app`), which every reload/install/queue script resolves by path |
| 239 | `ios/Config/Release.xcconfig` | `ios-supermux-brand` | Local Release builds display `Supermux$(SUPERMUX_IOS_DISPLAY_SUFFIX)` (was `cmux BETA`; suffix empty → `Supermux`). The TestFlight/App Store lanes pass `PRODUCT_DISPLAY_NAME` on the xcodebuild command line (`ios/scripts/upload-testflight.sh`, `ios/scripts/resolve_testflight_distribution.py`), so upstream channel names and `tests/test_ios_testflight_pro_distribution.py` are untouched |
| 240 | `ios/scripts/reload.sh` | `ios-supermux-brand` | Tagged dev builds display `Supermux DEV <tag>` (was `cmux DEV <tag>`). The tag suffix is kept so parallel tagged installs stay tellable apart; the `cmux.app` product path this script resolves is unchanged |
| 241 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Wires the ROOT `AppIcon.icon` + `AppIcon-Demo.icon` Icon Composer bundles into the iOS app target's Resources phase (ids `IC1000*`, `sourceTree = SOURCE_ROOT`, `path = ../AppIcon*.icon`) and deletes the upstream `AppIcon.appiconset` / `AppIcon-Demo.appiconset` PNG sets. iOS now renders from the same single source of truth as macOS (#17); no PNG icon art exists in the fork. `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` was already correct and is unchanged |
| 242 | `ios/cmux/Assets.xcassets/CmuxLogo.imageset` | `unfenced` | The in-app brand logo (sign-in header, restoring-session screen) re-sourced from the supermux mark, squircle-masked, as a base64-PNG-in-SVG at the same path/name so no Swift call site changes. Upstream (#11725) re-sourced this imageset as `cmux-logo.png`/`@2x`/`@3x` + a PNG Contents.json; the fork keeps its SVG + SVG-only Contents.json and deletes those PNGs on every merge. `RestoringSessionView` still reads `CmuxLogo`; the sign-in header now reads `CmuxSignInMark` (#242b) |
| 242b | `ios/cmux/Assets.xcassets/CmuxSignInMark.imageset/cmux-sign-in-mark.svg` | `unfenced` | Upstream's sign-in header mark (#11872/#11876, read by `SignInView.brandHeader` at 28×28) — file contents replaced with the fork's logo SVG (a byte-identical copy of `CmuxLogo.imageset/cmux-logo.svg`, ~0.5 MB of duplicated source art); its Contents.json is untouched and no Swift changes |
| 243 | `.github/workflows/ios-testflight.yml` | `ios-supermux-brand` | The "Use DEMO-badged app icon" step replaces the whole `AppIcon.icon` directory with `AppIcon-Demo.icon` instead of copying three PNGs into `AppIcon.appiconset`, which no longer exists |
| 245 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileTerminalFontPreference.swift` | `ios-terminal-default-zoom` | Changes the built-in mobile terminal baseline from 10 pt to 12 pt, matching the desktop default and the fork's phone dogfood preference |
| 246 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/MobileTerminalZoomPreference.swift` | `ios-terminal-default-zoom` | Exposes the resolved default font size (explicitly saved zoom, otherwise the 12 pt built-in) so new terminal mounts consume the same preference the floating controls mutate |
| 247 | `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView.swift` | `ios-terminal-default-zoom` | Replaces the initializer's stale literal 10 pt default with `MobileTerminalFontPreference.defaultSize`, preventing the public surface default from drifting from the canonical preference |
| 248 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+TerminalArtifacts.swift` | `ios-terminal-default-zoom` | Mounts each newly selected terminal at `MobileTerminalZoomPreference.resolvedFontSize`, making the floating "Set as default" action affect subsequent terminal mounts instead of only the floating Reset action |
| 249 | `Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/MobileTerminalZoomControlTests.swift` | `unfenced` | Whole-file regression coverage for the 12 pt built-in, saved-default persistence/clearing, and all three floating zoom buttons dispatching their actions |
| 259 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceShellView.swift` | `supermux-mobile-compact-root-chrome` | Ten fences. Everything that gated the phone's ROOT chrome on `compactNavigationPath.isEmpty` now reads `showsCompactRootChrome`, which folds in an in-flight interactive pop: the import, the `@State compactRootChrome`, the `showsCompactRootChrome` predicate, the compose-button (`taskComposerAction`) gate — now inside upstream's new `compactScaffold(presentation:)` — the `rootToolbarContent` gate, a comment-only marker where the fork deletes upstream's destination `.mobileToolbarVisibility(.hidden, for: .tabBar, .bottomBar)`, the stack-level visibility (`.mobileToolbarVisibility` inside `#if os(iOS)`: upstream lowered iOS to 17 and raw `.toolbarVisibility` is iOS 18+), the `SupermuxInteractivePopObserver` mount, the `navigationPathChanged()` reset in `.onChange(of: compactNavigationPath)`, and the `showsNavigationToolbar` argument. See #260 for why; #504 mirrors it in the layout preview. At the 2026-10-01 upstream merge the `taskComposerAction` fence follows upstream's new `feedNeedsInputCount:` / `showsNotificationsTab:` scaffold arguments |
| 260 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxCompactRootChrome.swift` | `unfenced` | **Fork-owned new file.** The predicate + the UIKit pop observer behind #259. Fixes two separate late-chrome bugs on the phone: (a) the top bar's items were absent for the whole edge-swipe back, because `NavigationStack` only writes the emptied path when the gesture COMMITS while UIKit reveals the root immediately — tapping the back button was clean, which is what pinned the cause; (b) the tab bar arrived ~1s late on BOTH back paths, because the `.toolbarVisibility(.hidden, for: .tabBar)` request lives on the pushed destination and that destination stays mounted, still asking for a hidden bar, for the entire pop animation. `SupermuxInteractivePopObserver` only adds a target-action to the pop recognizer — the DELEGATE stays with upstream's `InteractiveSwipeBackEnabler`, which owns whether the gesture may begin and how it arbitrates against terminal pans. A committed pop deliberately does NOT clear the flag (that would re-hide mid-animation); the path change does. `SupermuxCompactRootChromeTests` pins all six transitions |
| 261 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxUnreadBadgeStyle.swift` | `unfenced` | **Fork-owned new file.** The single description of the unread badge's geometry, count text and paint recipe, read by all three renderers (Mac SwiftUI, Mac AppKit, phone). Lives in the wire-contract package because that is the only one BOTH apps already depend on; it deliberately imports no UI framework, so the platforms own painting and share only proportions. Everything derives from the numeral's font size rather than absolute points, and the `99+` overflow marker resolves from the package localization catalog (#298). `SupermuxUnreadBadgeStyleTests` pins the cap, countless-dot fallback, one-digit circularity, the compact 9pt→14pt Mac height, and the phone's 10pt→16pt base height |
| 262 | `Packages/SupermuxKit/Sources/SupermuxKit/UI/SupermuxUnreadBadgeView.swift` | `unfenced` | **Fork-owned new file.** A thin Mac-named wrapper over the shared badge body in #281, adding no rendering of its own, plus the `appKitStops` projection of the shared gradient so the Core Graphics renderer (#267) paints the same wash rather than a hand-matched copy |
| 263 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadBadge.swift` | `unfenced` | **Fork-owned new file.** The phone's wrapper over the same #281 body, supplying the accent/white colors, the badge's accessibility posture, and `@ScaledMetric` headline-relative sizing so the capsule follows Dynamic Type |
| 264 | `Sources/Sidebar/SidebarWorkspaceUnreadBadge.swift` | `supermux-unread-badge-capsule` | Fenced replacement of upstream's flat accent `Circle` with a thin adapter over #262. The adapter takes the already-magnified numeral point size (see #282): the shared style derives every dimension from it, and recovering that from the badge's frame instead would silently drop the user's global font magnification |
| 265 | `Sources/Sidebar/SidebarWorkspaceLeadingStatusSlot.swift` | `supermux-unread-badge-capsule` | The slot relaxes from `.frame(width:height:)` + `.clipped()` to `.frame(minWidth:minHeight:)`. The badge is a capsule now, so a two-digit count is wider than tall; upstream's square frame and clip would together have sheared the second digit off. Height stays pinned so rows keep aligning on it |
| 266 | `Sources/Sidebar/SidebarWorkspaceTrailingStatusSlot.swift` | `supermux-unread-badge-capsule` | Same relaxation as #265. `width` is the close button's reserved width, which a two-digit capsule exceeds; it becomes a minimum so the badge grows leftward into the row instead of being clipped, while the close button and spinner still reserve exactly what they always did |
| 267 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowSlotViews.swift` | `supermux-unread-badge-capsule` | `SidebarRowUnreadBadgeView` paints capsule + gradient + rim in `draw(_:)` rather than composing layers — this is a pooled cell in a hand-laid-out list, and three sublayers per row is exactly the cost that list exists to avoid. Every VALUE comes from #261, so "matched to the SwiftUI badge" is a shared table, not a hand-tuned copy |
| 268 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCellView.swift` | `supermux-unread-badge-capsule` | `layoutContent` measures and draws the badge through the shared AppKit helper instead of assuming a `16 * fontScale` square; the leading advance and the trailing reservation both use the measured width so a wide badge can neither overlap the title nor be clipped. **Only the row-height calculation is floored at the old square**: the visible capsule keeps the shared compact proportions while a non-wrapping row's height remains unchanged. **The trailing reservation is deliberately keyed on whether the row HAS a badge, not on whether it is currently visible**: hover hides the trailing badge behind the close button, and keying off visibility would widen a wrapping title on hover, unwrapping a line — while the table holds the height it cached at `isPointerHovering: false`. Reserving unconditionally keeps row height hover-independent, which is what that cache assumes. `badgeVisible` is upstream's (gated by upstream's new `!compacts`) |
| 269 | `Sources/SidebarWorkspaceGroupHeaderView.swift` | `supermux-unread-badge-capsule` | The SwiftUI group header's own flat accent capsule routed through #262, so a header badge and the workspace badges beneath it stop being two different badges. Since the 2026-09-30 upstream merge the fenced `SupermuxUnreadBadgeView` sits inside upstream's new `else if anchorUnreadCount > 0, !compactsAgentStatus` branch (after the compact-status-glyph branch), and its `fillColor` is upstream's `cmuxNotificationBadgeNSColor(hex: notificationBadgeColorHex, fallback: …)`, so the user's "Notification Badge Color" setting is honoured |
| 270 | `Sources/Sidebar/AppKitList/Cells/SidebarGroupHeaderRowView.swift` | `supermux-unread-badge-capsule` | The AppKit group header measures its badge through the shared style instead of its own `unreadHorizontalPadding`/`unreadVerticalPadding` metrics. Counts past 99 now measure as `"99+"`, which is also what gets drawn |
| 271 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-workspace-fields` | Additive unread count plus pane-id capability/state on the v2 record. Count and pane ids travel for every workspace, not only project-associated rows; absent/malformed values decode to `nil`, while an empty pane array stays distinct |
| 272 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-workspace-fields` | Sets unread count and exact pane ids beside the project augmenter. Count may be absent when the store is unavailable; pane ids are always an array on this supporting host so iOS can disable the legacy broad receipt |
| 273 | `Sources/TerminalController+MobileWorkspaceList.swift` | `mobile-supermux-workspace-fields` | Sends the same unread count and exact pane ids on the legacy list payload, keeping full-list and v2 semantics aligned |
| 274 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-workspace-fields` | Lossily decodes both `supermux_unread_count` and `supermux_unread_panel_ids` from a workspace row |
| 275 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-workspace-fields` | Carries count and pane ids into the preview model |
| 276 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-workspace-fields` | Stores defaulted optional unread count and exact pane ids so upstream initializers stay untouched and `nil` versus `[]` remains observable |
| 277 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+StateSync.swift` | `supermux-mobile-workspace-fields` | Carries count and pane ids through the v2 projection so badge and ring state do not disappear when v2 negotiates |
| 278 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceUnreadDot.swift` | `supermux-unread-badge-capsule` | Rebuilt on upstream's struct (`gutterWidth`, `layoutGap`, `init(unread:leftShift:diameter:)`, `init(isUnread:…)`) with fenced imports (`SupermuxMobileCore`/`SupermuxMobileUI`) plus one fenced block: a `fontSize` (default 10), the fork `body` (`SupermuxMobileUnreadBadge(count: unread.count, …)`, nothing when read) replacing upstream's gutter circle, and a `nonisolated` `heightIdentity(isUnread:unreadCount:)` (the non-MainActor layout key calls it under Swift 6). Reads upstream's `MobileWorkspaceUnreadState`; a nil count draws the countless dot (upstream would draw "1"). Upstream's statics stay so its layout tests and the DEBUG `UnreadIndicatorLabView` compile; their `leftShift`/`diameter` inputs are inert under the fork body |
| 279 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceRow.swift` | `supermux-mobile-unread-badge` | Comment-only marker fence where upstream's gutter badge + spacer were; the inline badge after the title reads `WorkspaceUnreadDot(unread: content.unreadState)` (upstream's count, from upstream's extracted `WorkspaceRowContent`); `railLeadingOffset { 0 }` since there is no gutter left to clear. Upstream's `WorkspaceRowContent` owns `unreadIndicatorLeftShift` itself now, so the fork's old inert-parameter fence is gone; `unreadDotRailVisualGap` and the private `unreadDotRailLayoutGap` remain (unused by the render) so upstream's `WorkspaceUnreadIndicatorLayoutTests` compiles |
| 280 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceGroupHeaderRow.swift` | `supermux-mobile-unread-badge` | Same move for group headers: a marker fence replaces the leading gutter, and the badge trails the group name as `WorkspaceUnreadDot(unread: unread)` (matching the Mac header) with the chevron starting the row. Since the 2026-09-30 upstream merge it shows upstream's aggregate `MobileWorkspaceUnreadState` — the summed count while collapsed, the dot when any member's count is unknown — so it is no longer countless by construction. Body `HStack(spacing: 0)` is upstream's |
| 281 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxUnreadBadgeContent.swift` | `unfenced` | **Fork-owned new file.** The ONE SwiftUI badge body, rendered by both platforms — #262 and #263 are colour-supplying wrappers over it. An earlier revision had a Mac copy and a phone copy whose bodies were line-for-line identical, which is exactly the drift #261 exists to prevent; SwiftUI is cross-platform, so there was never a reason for two. Also holds `SupermuxUnreadBadgeGradient`, whose stops the AppKit renderer derives from rather than restates |
| 282 | `Sources/ContentView.swift` | `supermux-unread-badge-capsule` | Three fences replace upstream's opaque `badgeFont` plumbing with `badgePointSize` (the 9pt sidebar size put through `GlobalFontMagnification`) and pass it through both status-slot call sites. The shared style needs the numeric size; deriving it from the badge's frame would silently drop the user's global font magnification. This file's other fork edits are registered separately as #2 |
| 283 | `Sources/Mobile/MobileWorkspaceListObserver.swift` | `supermux-mobile-workspace-fields` | Subscribes to focused-read changes plus `Workspace.supermuxUnreadPanelIDsPublisher` for exact manual/restored pane-set changes, then folds both unread count and ordered pane ids into the per-workspace preview signature. Count-only changes update the numbered badge; A → A+B pane changes still emit while the workspace unread boolean remains true, so the phone's blue rings cannot stay stale. Upstream #10791 now does `hasher.combine(summary.unreadCount)` itself; the fence stays after it for the `supermuxUnreadCountForWorkspaceID` test seam and the ordered unread pane ids (the count is combined twice, harmlessly) |
| 284 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListRowModel.swift` | `supermux-mobile-unread-badge` | Two fences on `WorkspaceListWorkspaceLayoutKey`: the `supermuxUnreadBadgeText` field and its init (set only when titles wrap, computed through `WorkspaceUnreadDot.heightIdentity` from `content.unreadState`). The badge is inline with the title, so its presence and width steal room from a title that is allowed to wrap; a read → unread flip or 9 → 10 can push a barely-fitting title onto a second line. Keyed on the TEXT, not the count — 100 and 4000 both draw "99+" and must share a cache entry. Upstream's key comment says unread counts are height-neutral, which is false for the fork's inline badge. Re-homed at the 2026-09-30 upstream merge from the coordinator's removed `HeightKind.workspaceWrapped` key |
| 285 | `Packages/iOS/CmuxMobileShell/Package.swift` | `supermux-mobile-selection-sync` | Adds the lower-layer `SupermuxMobileCore` dependency to the shell target so the phone uses the same typed capability and method identifiers as the Mac router. No dependency on `SupermuxMobileKit`, so the existing package DAG stays acyclic |
| 286 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-selection-sync` | Integration fences store the serialized optimistic focus and reconciliation pipelines, the effective focused-panel value, and the panel whose Mac focus is ready for stream startup; send workspace plus the selected terminal/browser/Simulator when navigation or the picker changes; clear readiness with workspace/connection changes; and route list application through the fork reconciliation policy only when `supermux.selection_sync.v1` or `.v2` is advertised. Terminal selection compares the generic effective panel as well as `selectedTerminalID`, so choosing the already-selected terminal while browser/Simulator chrome is active still reclaims Mac focus. A created terminal uses the same chrome-selection action even under version skew. Older/upstream Macs retain the prior phone-local behavior. Since the 2026-09-30 upstream merge: (a) the `.restored` case of upstream's last-opened-tab restore calls the fenced `adoptRestoredTabAsSupermuxFocusedPanel(in:)`; (b) the workspace-list reconcile call is skipped while the selected workspace is `locallyServedOwnsWorkspaceRow` (demo/SSH), so upstream's hold-the-selection path runs instead of every Mac list push yanking the user out of an SSH workspace; `selectTerminalFromChrome` keeps upstream's restore-disarm/record lines ahead of the fork's (unfenced) `guard changed`; `selectedWorkspaceID.didSet` carries both the fork readiness reset and upstream's restore arming |
| 287 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SupermuxSelectionSync.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Serializes rapid phone selections, uses v1 workspace/terminal RPCs for version skew and v2 `mobile.supermux.panel.select` for every panel kind, holds an optimistic request id against stale list frames, and returns a Boolean focus acknowledgement so stream startup can proceed as soon as Mac focus succeeds. A Mac state push that outraces the mutation's own RPC reply clears the pending intent as confirmed; the late reply (or a lost reply) for that exact selection still counts as success instead of abandoning the just-focused surface (the flash-then-revert on re-entering a browser/Simulator tab). Authoritative list reconciliation runs on a separate serialized tail; focus failure clears readiness and rolls back explicitly, while Mac-originated focus records immediate readiness. Adds `adoptRestoredTabAsSupermuxFocusedPanel(in:)` (maps upstream's restored `MobileWorkspaceLastTab` terminal/browserStream/simulatorStream to `selectedWorkspaceFocusedPanel`, so `openWorkspace` pushes that panel to the Mac and it passes the stream gate; `.macSurface`/`.localBrowser` keep the terminal fallback) and a `!locallyServedOwnsWorkspaceRow(workspaceID)` guard in `enqueueSupermuxSelectionSync` (demo/SSH rows do not exist on the Mac) |
| 288 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxSelectionSyncTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Pins Mac→phone workspace, terminal, browser, and Simulator focus; stale browser-frame suppression while a phone mutation is pending; a Mac confirmation that outraces the focus reply still counting as success while a superseded selection does not; focus-readiness gating for optimistic versus authoritative selections; v1 terminal fallback; and the upstream-host fallback |
| 289 | `Sources/Mobile/MobileWorkspaceListObserver.swift` | `supermux-mobile-selection-sync` | Subscribes to the existing deferred `.ghosttyDidFocusSurface` broadcast and folds the generic focused panel id+kind into the mobile summary hash. Focus-only terminal, browser, Simulator, or future-panel changes therefore emit both legacy `workspace.updated` and state-sync-v2 deltas |
| 290 | `cmuxTests/MobileWorkspaceListFidelityTests.swift` | `supermux-mobile-selection-sync` | Behavior coverage proving a focus-only terminal→browser→terminal transition changes the observer hash and that the legacy payload's generic `focused_panel` object reports the exact panel id and kind while terminal `is_focused` compatibility remains correct |
| 291 | `cmuxTests/MobileWorkspaceListFidelityTests.swift` | `supermux-mobile-workspace-fields` | A second, independent fence in the same file for #283: verifies the legacy payload carries `supermux_unread_count` for read and unread workspaces, then uses the observer's narrow count override seam to hold the latest notification and unread boolean fixed while the count falls 2 → 1. The two signatures must differ; reverting #283 turns this red |
| 292 | `Sources/Workspace+PanelLifecycle.swift` | `panel-scoped-shared-agent-lifecycle-clear` | When a panel-scoped `clear_agent_pid` targets a shared structured-agent key currently owned by a sibling panel, preserves that sibling's PID ownership but still clears the requesting panel's lifecycle. Claude Code deliberately uses the single `claude_code` key in every terminal, so the previous ownership-mismatch early return orphaned `running`/`needsInput` entries after non-owner SessionEnd hooks |
| 293 | `cmuxTests/AgentHibernationTests.swift` | `panel-scoped-shared-agent-lifecycle-clear` | Regression coverage for #292: two panels share `claude_code`, the second owns the sole PID slot, and ending the first must clear only the first panel's lifecycle while retaining the second panel's running state, PID, and ownership |
| 294 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListTableCoordinator.swift` | `supermux-mobile-row-activity` | Mounts `supermuxWorkspaceActivityDot(rawActivity:)` on the real iPhone `UITableView` workspace row, in `workspaceRowView(workspaceID:row:)`, reading `row.supermuxActivity` (the row-model field is #503 — without it a status-only activity change would not change the model and the dot would go stale). The older #103 modifier lives on the SwiftUI `List` branch, which is not the iPhone renderer after upstream's table rebuild |
| 295 | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCellView.swift` | `sidebar-appkit-row-activity` | Ports the working-state activity spinner to the locally opt-in AppKit sidebar row using its existing GPU spinner slots: `.working` bypasses upstream's default-off agent-spinner flag, paints amber, uses the Supermux tooltip, and participates in leading-slot spacing. The default SwiftUI sidebar remains unchanged. Since the 2026-09-30 upstream merge the fence reads `showsSupermuxActivity = !compacts && supermuxActivity == .working` and `showsSpinner = showsSupermuxActivity || (!compacts && showsAgentActivity && activeCount > 0)`, so the working spinner is suppressed when upstream's compact status glyph (`sidebar.compactAgentStatus`) is active |
| 296 | `cmuxTests/SidebarAppKitRowCellTests.swift` | `sidebar-appkit-row-activity` | Behavior coverage for #295 through the real AppKit cell configuration: a snapshot with `.working`, zero upstream active count, and `showsAgentActivity=false` still mounts exactly one visible spinner. The fork params/args come after upstream's new `compactStatusGlyph:`/`colorSchemeIsDark:` in `makeSnapshot`, `makeModel` and the Snapshot init |
| 297 | `Packages/Shared/SupermuxMobileCore/Package.swift` | `unfenced` | Fork-owned package manifest: processes the shared core's `Resources` directory so the unread badge's overflow marker is localized from the same bundle on macOS and iOS. Platform floor lowered `.iOS(.v18)` → `.iOS(.v17)` at the 2026-09-30 upstream merge (together with the fork-owned `SupermuxMobileKit`/`SupermuxMobileUI` manifests) because upstream lowered the iOS app and every Cmux iOS package to iOS 17, and SwiftPM rejects an iOS 17 package that depends on an iOS 18 product |
| 298 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/Resources/Localizable.xcstrings` | `unfenced` | Fork-owned package catalog for `supermux.unreadBadge.overflow`, translated for every supported locale (English and Japanese; both use the compact numeric `99+` convention) |
| 299 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileWorkspaceFocusedPanel.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Forward-compatible `{panel_id, kind}` value shared by legacy workspace lists, state-sync-v2 records, the shell model, and UI presentation policy. Unknown kinds remain decodable so newer Macs cannot gap older phone mirrors |
| 300 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-selection-sync` | Adds optional, lossy-decoded `focused_panel` to every workspace record. Record equality includes it, so focus-only browser/Simulator changes produce a v2 delta instead of disappearing as no-ops |
| 301 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-selection-sync` | Projects `Workspace.focusedPanelId` plus the workspace's existing panel-kind mapping into the typed state-sync row, independently of terminal-only `is_focused` compatibility |
| 302 | `Sources/TerminalController+MobileWorkspaceList.swift` | `supermux-mobile-selection-sync` | Adds the same `focused_panel` object to legacy `mobile.workspace.list`, keeping the full-list and v2 transports byte-semantically aligned for terminal, browser, Simulator, and future panel kinds |
| 303 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileSyncWorkspaceListResponse.swift` | `supermux-mobile-selection-sync` | Decodes optional generic focus leniently; absent upstream fields and malformed additive objects both become `nil` rather than failing the whole workspace row |
| 304 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileWorkspacePreview+RemoteMapping.swift` | `supermux-mobile-selection-sync` | Carries generic focused-panel identity from either transport into the immutable workspace preview |
| 305 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileWorkspacePreview.swift` | `supermux-mobile-selection-sync` | Stores optional Mac-authoritative focused-panel identity on each workspace snapshot, defaulted to `nil` so every upstream initializer remains source-compatible |
| 306 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+StateSync.swift` | `supermux-mobile-selection-sync` | Preserves `focused_panel` while projecting the v2 record mirror through the shared full-list apply path; without this line generic focus would work only on the legacy transport |
| 307 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-selection-sync` | Routes phone browser/Simulator picker selections through the shared shell mutation and shared activation sequence, captures the previous stream for unconditional teardown, abandons a failed/stale optimistic surface, and observes Mac-authoritative focus plus late browser discovery to mount the matching streamed surface without echoing either an RPC or a second activation back into the pipeline. Every transition uses the exact current focused-panel predicate, including Mac-originated changes. Terminal selection closes streamed chrome as before. Since the 2026-09-30 upstream merge the fork selection functions (now `internal`, matching upstream) also call upstream's `recordLastOpenedBrowserStreamTab` / `recordLastOpenedSimulatorStreamTab` right after `activate`, and `.task(id:)` runs `refreshWorkspaceSelection()` → `applyFocusedPanelFromStore()` → upstream's `restoreLocalBrowserTabIfRequested()` (restore last, so an upstream reopen-local-browser intent is not immediately closed by a terminal-focused Mac state) |
| 308 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceFocusedPanelPresentationTarget.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** Pure presentation policy maps a generic focused panel to terminal, browser stream, Simulator stream, or unsupported; undiscovered/unknown panels preserve the current phone surface instead of showing an unrelated terminal |
| 309 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceActiveSurfaceTests.swift` | `supermux-mobile-selection-sync` | Behavior coverage for terminal/browser/Simulator presentation mapping plus unknown and not-yet-discovered panel fallback |
| 310 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/SupermuxWorkspaceSyncRecordFieldsTests.swift` | `supermux-mobile-selection-sync` | Record-wire coverage for generic focus and exact pane unread: wire shape, round-trip/equality visibility, upstream `nil`, supported-empty `[]`, and malformed additive-field tolerance |
| 311 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/SupermuxWorkspaceListFieldsDecodeTests.swift` | `supermux-mobile-selection-sync` | Decoder/preview coverage for generic focus and exact pane unread, including upstream absence, supported-empty arrays, and malformed objects/arrays degrading without failing the list |
| 312 | `cmuxTests/SupermuxMobileAuthorizationTests.swift` | `supermux-mobile-selection-sync` | Extends the exhaustive fail-closed method table for `panel.select`; workspace tickets may focus any panel in their workspace, while terminal-pinned tickets remain exact-panel only |
| 313 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `supermux-mobile-create-focus` | Adds `focus: true` to phone terminal creation and routes the returned terminal through the existing chrome-selection action instead of assigning the terminal id directly, keeping local presentation and Mac focus on the one shared mutation path. Since the 2026-09-30 upstream merge the fence wraps only `selectTerminalFromChrome(createdTerminalID)`, replacing upstream's `selectedTerminalID = createdTerminalID`; upstream's `CreatedTerminalSelection` pin (set first, so upstream's didSet does not clear it), `suppressTerminalAutoFocusOnNextAttach` and `armCreatedTerminalSelectionExpiry` stay unfenced |
| 314 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileBrowserCreateParameters.swift` | `supermux-mobile-create-focus` | Adds the default-true additive browser-create `focus` field, preserving source compatibility while requiring a new Mac to select the created panel before replying; older Macs ignore the unknown key |
| 315 | `Sources/TerminalController.swift` | `supermux-mobile-create-focus` | Honors additive `focus: true` on `terminal.create` by focusing the newly created terminal through the shared control action before serializing the response; if focus fails, closes the new panel through the shared history-aware close path and falls back to the captured bonsplit tab id if the panel mapping changed, so the phone never receives a half-created orphan. Calls without the flag keep background-create semantics |
| 316 | `Sources/TerminalController+MobileBrowser.swift` | `supermux-mobile-create-focus` | Applies the same atomic create-then-shared-focus contract to `mobile.browser.create`, with explicit cleanup on focus failure and unchanged background creation for old/no-flag callers |
| 317 | `cmuxTests/TerminalAndGhosttyTests.swift` | `supermux-mobile-create-focus` | Behavior coverage proving `focus: true` terminal, browser, and Simulator creation selects the owning Mac workspace and exact created panel, alongside the existing no-flag terminal/browser tests that pin backward-compatible background creation |
| 318 | `Packages/iOS/CmuxMobileRPC/Tests/CmuxMobileRPCTests/MobileBrowserRPCDTOTests.swift` | `supermux-mobile-create-focus` | Wire coverage proving phone browser creation emits the exact additive `focus: true` field with the Mac-local workspace id |
| 319 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspacePanelStreamActivationSequence.swift` | `supermux-mobile-selection-sync` | **Whole-file fork addition inside an upstream package.** One shared browser/Simulator transition path awaits the Boolean Mac-focus result, always tears down the previous captured stream, rechecks exact current selection after that suspension, explicitly abandons failed/stale current state, and only then starts the current stream |
| 320 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspacePanelStreamActivationSequenceTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Four race-level behaviors prove focus→stop→start ordering, unconditional previous-stream teardown for stale transitions, rejection when selection changes during the suspending stop, and abandonment rather than startup after focus failure |
| 321 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellCompositePreviewTests.swift` | `supermux-mobile-selection-sync` | Exact missed-bug coverage: with `selectedTerminalID` unchanged but browser or Simulator recorded as the effective panel, terminal-picker selection must restore terminal focus and chrome autofocus suppression; the deep-link entrypoint restores the same focus without chrome suppression |
| 322 | `Sources/Workspace+PanelLifecycle.swift` | `panel-agent-liveness-evidence` | Four fences closing the orphaned-indicator hole for shared agent keys: `recordAgentPID` records the reporting panel's process identity; both stale sweeps retire lifecycle entries whose recorded process is dead but whose PID slot a sibling stole, with the workspace-wide pass merging that mutation into its return value so notification cleanup still runs; and `clearAllAgentPIDs` drops the workspace's registry bucket during reset/teardown. Keys with no evidence or a still-live process are never touched. At the 2026-10-01 upstream merge the `recordAgentPID` fence follows upstream's new `noteAgentWakeAgentReported(panelId:statusKey:)` line |
| 323 | `Sources/Supermux/SupermuxPanelAgentEvidence.swift` | `unfenced` | **Fork-owned new file** behind #322: the per-(workspace, panel, status key) last-reported process-identity registry plus the `Workspace` sweep extension (`supermuxClearDeadPanelAgentLifecycle` / `supermuxSweepDeadAgentLifecycle`). The workspace sweep reports whether it mutated lifecycle, and reset/teardown can remove the whole workspace bucket. Evidence-only — retirement clears lifecycle through the same panel-scoped `clearAgentLifecycle` every other clear path uses. Wired via pbxproj ids `50BE0001…0101`/`…0102` under #3 |
| 324 | `cmuxTests/AgentHibernationTests.swift` | `panel-agent-liveness-evidence` | Regression coverage for #322/#323: a dead non-owner Claude's `running` lifecycle is retired while the live owner survives; the workspace-wide sweep reports that mutation; a still-live non-owner is preserved; and clearing all agent PIDs removes the workspace's registry bucket |
| 325 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+BrowserStream.swift` | `supermux-mobile-selection-sync` | Requires every browser-stream start entrypoint—including viewport auto-start, recovery restart, and foreground restart—to pass the same lower-layer authority gate: the panel must still own the phone-visible browser surface and, on v2 hosts, its exact Mac focus must be acknowledged. The gate is checked both before and after the suspending `browserStreamWillStart`, so selection changes during that await cannot queue a stale start ahead of the stop. The fork gate follows upstream's `sshOwnsSurface(panelID)` early branch (`performStartSSHBrowserStream`) in `performStartMobileBrowserStream` — SSH browser streams have no Mac focus to wait for |
| 326 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SimulatorStream.swift` | `supermux-mobile-selection-sync` | Applies the same phone-visible plus Mac-focus-ready authority gate inside the serialized Simulator start operation. Stale activation tasks, view-dismissed tasks, and recovery restarts cannot start a stream for a panel that no longer owns the active phone surface |
| 327 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxStreamStartGateTests.swift` | `supermux-mobile-selection-sync` | **Whole-file fork test inside an upstream package.** Browser and Simulator behavior coverage proves stream startup is denied before phone activation, denied while optimistic Mac focus is unacknowledged, allowed only when both authorities match, and denied again after panel-scoped deactivation |
| 328 | `Sources/Panels/BrowserPanel.swift` | `mac-browser-stream-teardown-grace` | Adds the cancellable teardown-grace task and its configurable interval beside the other mobile-stream state. Rapid phone-side panel switching amplified a WebKit layer-tree commit segfault on macOS 26/27 betas (`RemoteLayerTreePropertyApplier` type confusion, no app frames); every immediate teardown reparented the live WKWebView and closed its WebKit-hosting window mid-commit |
| 329 | `Sources/Panels/BrowserPanel+MobileBrowserStreaming.swift` | `mac-browser-stream-teardown-grace` | Three fences: the last stream handler removal parks the offscreen render host behind a short cancellable grace instead of tearing it down synchronously; a restart inside the grace cancels the pending teardown and reuses the parked host with zero window/reparent churn; explicit `clearMobileStreamViewport` tears down immediately, while a web-view replacement during grace restores the captured desktop viewport before abandoning the dead web view's render host |
| 330 | `cmuxTests/MobileBrowserStreamTeardownGraceTests.swift` | `mac-browser-stream-teardown-grace` | **Whole-file fork test.** Behavior coverage: a stopped stream parks the render host and a rapid restart reuses it with the teardown cancelled; grace expiry with no restart fully tears down; web-view replacement restores the desktop viewport; panel close during the grace skips the wait. Since the 2026-09-30 upstream merge (upstream 89689616b3e removed `BrowserPanel.debugSimulateWebContentProcessTermination()` and defers the WebContent replacement until recovery) the replacement test drives it the upstream way: the navigation delegate's `webViewWebContentProcessDidTerminate`, then `recoverTerminatedWebContent(reason:)` |
| 331 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePushCoordinator.swift` | `ios-direct-apns-token` | Mirrors each successful APNs device token into fork-owned `SupermuxMobilePushRegistrationStore` before upstream's cloud registration runs. The store persists a stable installation id plus the current and last Mac-acknowledged tokens, drains changes made during an in-flight registration, and registers/removes the device when `supermux.phone_push.v1` is advertised. The fixed bundle guard keeps upstream/tagged identities on their original cloud-only path. The settings bridge also preserves whether Time Sensitive Notifications are unsupported versus user-disabled so the personal-team build does not advertise an impossible repair |
| 332 | `Sources/TerminalNotificationStore.swift` | `direct-phone-push` | Adds the topic-restricted personal APNs provider at the two existing notification chokepoints. Visible sends share the exact-pane focus decision from #453: the already-focused target is retained as read history with no phone push, while a non-focused target still forwards whenever phone forwarding is enabled, regardless of broad Mac activity/presence guesses. The phone's foreground delegate remains a final duplicate-presentation guard. Dismiss/badge synchronization runs beside the existing cold lane under the same forwarding preference; hide-content is inherited. Transport stays in fork-owned `SupermuxDirectPhonePush`/`SupermuxPhonePushService` |
| 333 | `ios/Config/supermux.entitlements` | `unfenced` | **Fork-owned build-stage signing entitlement** (`aps-environment = development`, used only by the xcodebuild pass with the Apple Development profile — workspace-wide distribution settings leak into SwiftPM targets, which cannot take profiles). `scripts/supermux-ios-release.sh` then RE-SIGNS the built app with `Apple Distribution` + the `Supermux iPhone Ad Hoc` profile, using the entitlements extracted from that profile (`aps-environment = production`), and rejects a profile or final signature that is not production. The Ad Hoc profile must also carry `com.apple.developer.usernotifications.time-sensitive` (the App ID's Time Sensitive Notifications capability — a free checkbox on a paid team, unlike Critical Alerts), because the payload sends `"interruption-level": "time-sensitive"` and iOS silently downgrades it to active when the entitlement is absent; the script verifies it in the profile and the final signature. Sign in with Apple is deliberately NOT required: nothing in the iOS sources uses it, production auth runs through the web flow, so this lane must not inherit upstream's paid-team requirement for it. Sandbox APNs accepted every send with 200 but silently dropped delivery to the backgrounded app |
| 334 | `Sources/Mobile/MobileHostV2Installation.swift` | `profileless-release-iroh-storage` | Widens the three `#if DEBUG` guards (`deviceID()`, `key(identity:)`, `debugDirectory()`) to `DEBUG || SUPERMUX_LOCAL_RELEASE` so the profileless Developer ID local release uses upstream's `0600` file-backed v2 endpoint key + installation id under `Application Support/<bundle-id>/cmux-iroh-v2/development-keys/` (inside a `0700` directory) instead of the Data Protection Keychain (`V2KeychainStore`), which fails with `errSecMissingEntitlement` and makes `MobileHostIrxRuntime.provision` throw so the host never activates. `MobileHostV2Configuration`'s DEBUG environment fallback is deliberately NOT widened (the local release must stay on production). Upstream deleted `MobileHostIrohRuntime(+Lifecycle).swift` in #12754; this file replaced them as the hook site at the 2026-09-30 upstream merge |
| 336 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePushReadiness.swift` | `ios-direct-apns-token` | Models Time Sensitive Notifications support separately from the user's enabled setting. Unsupported personal-team builds do not show an unfixable Time Sensitive warning, while a supported setting that the user disables remains actionable and Scheduled Summary remains a real warning whenever active-level delivery cannot bypass it |
| 337 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/MobilePushReadinessTests.swift` | `ios-direct-apns-token` | Regression coverage proving an unsupported Time Sensitive setting can reach `.ready`, while Scheduled Summary remains the sole limitation when enabled on that build; the upstream parameterized test still proves a supported-but-disabled setting reaches `.presentationLimited([.timeSensitiveDisabled])` |
| 338 | `scripts/reload.sh` | `reload-supermux-profile`, `reload-supermux-profile-parse`, `reload-supermux-profile-seed` | Adds `--supermux-profile` (implies `--prod-auth`): after the same-tag app is told to quit, calls the supermux-owned `scripts/supermux-seed-dev-profile.sh` to copy the main `com.supermux.app` release install's UserDefaults + Stack Auth `credentials.json` into the tag's isolated identity, so a user-facing Mac dogfood build launches already signed in to the production account with the user's settings. The seeder is supermux-owned (no touchpoint); the three fences are the flag var, the arg parse, and the post-quit seeding call. Since the 2026-09-30 upstream merge upstream moved the same-tag quit/kill earlier (before the staging swap, with `pkill -KILL` and `launchctl bootout`) and deleted the old post-build "Tag mode: always terminate" block, so the seed fence sits after the swap and prune block, just before upstream's `BUILD_ONLY`/socket-lock check; it is also guarded by `"$BUILD_ONLY" -ne 1` so upstream's `--build-only` never mutates the running tag's identity |
| 339 | `CLAUDE.md` | `mac-dogfood-supermux-profile` | Documents #338 in a self-contained `##` section ("Supermux: Mac dogfood builds…") right after the #459 section, which follows upstream's "Verification and isolation": user-facing Mac dogfood builds must pass `--supermux-profile` (plain `--tag` sign-in points at an unserved localhost origin), sign-out inside a seeded build is forbidden (shared Stack session — revoking it signs the main app out too), agent-only builds keep plain `--tag`. It also notes that agent-only plain `--tag` builds need `CMUX_DEV_BACKEND_MODE=local`, because upstream's `reload.sh` otherwise requires cmuxterm-hq's `scripts/dev-backend.sh` |
| 340 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Toolbar.swift` | `supermux-mobile-usage-button` | Two fences: `import SupermuxMobileUI`, and `SupermuxUsageToolbarButton(model: supermuxUsage)` as the FIRST entry of the iOS `.topBarTrailing` `ToolbarItemGroup`, before upstream's `viewOptionsButton()` / `newWorkspaceButton`. The phone twin of the Mac sidebar footer gauge (#146): a ring filled to the tightest Claude/Codex limit, opening the read-only `SupermuxUsageScreen` sheet. Purely additive — no upstream toolbar item is replaced or wrapped. Renders nothing without `supermux.usage.v1`, so a fork phone paired with an upstream cmux Mac shows exactly upstream's toolbar. **The button must stay stateless.** This whole `ToolbarItemGroup` sits inside `if showsNavigationToolbar`, which is false for the duration of every pushed workspace, so a session owned by the button's own `@State` is destroyed on push and rebuilt on pop — emptying the ring and restarting the poll after routine navigation. The session therefore lives in `@State supermuxUsage` on `WorkspaceListView` (#340b). Upstream now owns the identity-preserving shape: keep the condition inside the toolbar content and never branch around `content` |
| 340b | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-usage-button` | Two iOS-only fences: the internal (not private) `@State supermuxUsage = SupermuxUsageSectionModel()` beside the #97 projects model, guarded by `#if os(iOS)`, and a `.supermuxUsageDriver(model:connection:)` on the stable iOS `workspaceTable`. The driver owns the session `.task`, keyed on the connection identity, exactly like the #97 projects driver; cancellation (a navigation push) PAUSES the poll loop but keeps the store, so the gauge holds its last reading and a pop resumes instead of reloading. The macOS `List` branch deliberately has neither state nor driver because it renders no usage entry point; attaching one there creates a consumer-less poll loop. Must stay on the stable iOS view — never inside the toolbar branch or a table cell. See #340 |
| 341 | `Sources/Supermux/SupermuxMobileHost+Usage.swift` | `unfenced` | **Whole-file fork addition** (`Sources/Supermux/`, pbxproj ids `50BE0002…00E1`/`…00E2` under #95). Serves `mobile.supermux.usage.state` by projecting `SupermuxComposition.usageModel` — the SAME model the sidebar gauge and popover render — through the package-tested `SupermuxMobileUsagePayloadBuilder`. Awaits `usageModel.refresh()` first, because that poll loop is view-driven and a Mac with no sidebar mounted would otherwise report `loading` forever; the model's own hard floor applies to every caller, so a phone polling fast cannot add provider traffic. Read-only: no cswap switch/enable path is exposed to the phone |
| 352 | `Sources/TerminalNotification.swift` | `notification-project-identity` | Adds the optional `project: SupermuxNotificationProject?` snapshot (plus the `SupermuxMobileCore` import and the defaulted init parameter) so every notification carries the project it fired from. A frozen snapshot, never a live reference: history stays readable after a project is renamed, recolored, or unregistered. Defaulted `nil`, so no upstream construction site changes. The `project` init parameter stays LAST, after upstream's `soundContext`, the `agentKind`/`agentCategory`/`agentSessionId` trio (2026-10-01 upstream merge) and `origin` |
| 353 | `Sources/NotificationFeedHistoryRecord.swift` | `notification-project-identity` | Persists the project snapshot in the durable feed so a restored history still renders avatars. Carries an explicit `CodingKeys` + `init(from:)` with `decodeIfPresent` for `project` — records written before this field must keep decoding, or the entire durable history is lost on upgrade — plus a `historyProjectNameByteLimit` clamp applied in `boundedForHistory()` beside the existing title/subtitle/body bounds. The explicit `CodingKeys`/`init(from:)` must list EVERY stored property. It includes upstream's `origin` and, since the 2026-10-01 upstream merge, `isAgentEvent` (both `decodeIfPresent`; `project` follows `isAgentEvent` in the init and `boundedForHistory()`); a key missing there is silently dropped on encode (a remote-origin record would persist as local) |
| 354 | `Sources/TerminalNotificationStore.swift` | `notification-project-identity`, `notification-project-banner` | Two fences. `notification-project-identity` resolves the project ONCE at the single `applyNotification` construction site every notification passes through, and preserves that snapshot in duplicate-id repair plus live panel-rebind copies, so restore/move paths cannot silently blank provenance. The panel, macOS banner, phone feed and APNs push therefore all describe the same project. `notification-project-banner` resolves the tab name and project on the enclosing `@MainActor` method, then decorates the content IN PLACE inside the authorization closure via `SupermuxBannerProjectDecorator.decorate(content, project:, origin: notificationOrigin, tabName:)` — the origin picks where the logo comes from (`SupermuxNotificationIconSource`: a `.deviceMac` record's project id belongs to that other Mac, so its logo comes from `SupermuxComposition.remoteProjects`, never this Mac's icon store) — adding the provenance subtitle, the per-project `threadIdentifier` (Notification Center stacks a project's banners instead of interleaving every workspace) and the circular avatar attachment. **Deliberately synchronous:** an earlier async version made banner ordering depend on raster-completion order and needed `MainActor.assumeIsolated` inside a closure upstream does not guarantee is main-actor isolated — which TRAPS if that ever changes. The call site now guards on `Thread.isMainThread` instead of asserting, and a render failure yields an undecorated banner rather than a lost notification. Since the 2026-09-30 upstream merge upstream builds `UNMutableNotificationContent` inside `enqueueNotificationFeedback(ownerID: deliveryOwnerID) { @MainActor … }` within `handleAuthorization`: the banner setup fence sits right before `let handleAuthorization` (after the `notificationIdentifier`/`deliveryOwnerID`/`fallbackOwnerID` lets), and the `supermuxDecorateBanner(content)` call sits after the `clickActionUserInfo` loop, before `UNNotificationRequest`. The operation is statically `@MainActor`, so the `Thread.isMainThread` guard is now belt-and-braces At the 2026-10-01 upstream merge upstream passes `agentKind`/`agentCategory`/`agentSessionId`/`origin` at all three `TerminalNotification(...)` construction sites (duplicate-id repair gained `origin`); `project:` stays last, after `origin:` |
| 355 | `Sources/NotificationsPage.swift` | `notifications-panel-redesign` | The redesigned macOS notifications panel: a two-tier header (title + live unread pill over filter/grouping/actions), an All/Unread filter, project grouping behind a persisted `@AppStorage` toggle, the phone-forwarding block demoted to a collapsed `Delivery` disclosure with a one-line state summary, and a rebuilt row (unread rail, project avatar, provenance line, body/subtitle preview, hover-only clear, context menu with mark-read). `SupermuxNotificationSectionHeader` is a new fork-owned view in the same file. Icons resolve ABOVE the `LazyVStack` through the same `SupermuxNotificationProjectBridge.projectIcons` helper the popover uses and pass down as immutable values. Filter/unread-count changes reconcile focus through `SupermuxNotificationFocusPolicy`, preserving a still-visible row or reseating to the newest visible row so Return never targets a filtered-out notification. `NotificationRow`'s `==` includes the icon/avatar/focus snapshots — the issue #2586 / #5794 boundary rule. The fork row's single outer `.contextMenu` also carries upstream's **Copy** item (`TerminalNotificationClipboard.copy`, after Open); do NOT let a merge put upstream's row context menu on `rowContent` — a nested menu shadows Mark as Read. Accent reads go through `@Environment(\.cmuxAccentColor)` (upstream #14988 removed the global `cmuxAccentColor()`), and every `CmuxSystemSymbolImage` passes `tint:` (upstream #12145) |
| 356 | `Sources/Update/UpdateTitlebarAccessory.swift` | `notification-read-toggle-shared` | The titlebar popover row's inline read-toggle (which also had to clear a pane-scoped notification's focused-read indicator) moved into the shared `TerminalNotificationStore.toggleReadFromUserAction(_:)` so the notifications panel's identical menu item cannot drift from it. The pane-indicator clearing is precisely the part a second copy would have missed |
| 357 | `Sources/MobileNotificationFeedWireItem.swift` | `notification-feed-project-wire` | Carries the project snapshot to the phone as an additive `supermux_project` object using `SupermuxNotificationProject`'s own snake_case Codable keys, so the phone decodes it with the shared type rather than a parallel hand-rolled parser. Absent from an upstream cmux Mac, which renders upstream's project-less row. The `project` property follows upstream's `originKind`; memberwise init order is `…, originKind, project` |
| 358 | `Sources/TerminalController+MobileNotificationSync.swift` | `notification-feed-project-wire` | Populates the wire item's project from the persisted history record and clamps its name with the existing metadata byte bound — the feed response is trimmed to a frame budget, so one pathological project name must not push notifications out of the frame |
| 359 | `Packages/iOS/CmuxMobileRPC/Package.swift` | `notification-feed-project-wire` | Adds the `SupermuxMobileCore` dependency so the RPC layer can decode the shared notification-project type |
| 360 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileNotificationFeedListItem.swift` | `notification-feed-project-wire` | Adds the optional `project` field, its `supermux_project` coding key, the defaulted init parameter, and the tolerant `decodeIfPresent` |
| 361 | `Packages/iOS/CmuxMobileRPC/Sources/CmuxMobileRPC/MobileNotificationFeedListBoundedItem.swift` | `notification-feed-project-wire` | **THE production decode path** — a field added only to #360 decodes as `nil` in production while #360's own unit tests pass, because this type carries a DUPLICATE key set and is what actually runs. Adds the key plus the type-scoped `supermuxBoundedProject`, which bounds the name/color/etag/symbol and drops the project (never the whole row) on a malformed or over-long identifier: losing a notification over a bad avatar is the worse failure |
| 362 | `Packages/iOS/CmuxMobileShellModel/Package.swift` | `notification-feed-project-wire` | Adds the `SupermuxMobileCore` dependency to the target and its test target. At the 2026-10-01 upstream merge the fenced entries follow upstream's new `CmuxTerminalSizing` dependency in both the target and the test target (the test target's one-line array became multi-line) |
| 363 | `Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileNotificationFeedItem.swift` | `notification-feed-project-wire` | Adds the `project` field to the domain snapshot in all THREE required places: the stored property, the memberwise init, and `updating(isRead:connectionStatus:)` — that initializer re-lists every field, so omitting it there would silently blank the avatar on the first mark-read or reconnect |
| 364 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+NotificationFeed.swift` | `notification-feed-project-wire` | Threads the decoded project through `applyNotificationFeedSnapshot`'s wire→domain projection, normalizing the name with the same metadata bound as the other labels. A project whose name normalizes away keeps its id and accent so the avatar still renders |
| 365 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/NotificationFeedRowPresentation.swift` | `notification-feed-project-row` | Derives the project and its de-duplicated display name on the projection's BACKGROUND rebuild (never in `body` — the documented scroll constraint). The name is dropped when blank or when it restates upstream's `headline` (the workspace) or `sourceName`. The project name is folded into the redundant-content set, so a body that merely repeats it is not shown as a preview. The project is spoken right after the read state and before upstream's "From:" source field in the row's accessibility details. Since the 2026-09-30 upstream merge upstream's init assigns `sourceName` as a stored property, so the fence computes the redundant-name list (`[headline] + [sourceName]`) into a local `projectRedundantNames` BEFORE the `projectName = normalizedProject.flatMap { … }` closure; never reference stored properties inside a closure in this init (captures `self` before `projectName` is initialized) |
| 366 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/NotificationFeedRow.swift` | `notification-feed-project-row` | Renders `SupermuxNotificationAvatar` in the row label's leading slot, skipped for grouped-history children whose headline is inherited (`context.hidesHeadline`). Also renders the project in upstream's source/computer provenance line via the fenced `NotificationFeedProjectSource`: as `project · source` normally, and alone when there is no distinct source (title == workspace headline, or `hidesSource`). `NotificationFeedProvenance` takes a defaulted `projectName: String? = nil`, so upstream's history-header call site is untouched. Both shapes keep upstream's `ViewThatFits` horizontal→vertical fallback. Every added label stays a SINGLE interpolated `Text` and the avatar does no async work, honoring the file's documented rule that cell self-sizing dominates the scroll profile |
| 367 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires three new app-target files into the cmux target: `Sources/Supermux/SupermuxNotificationProjectBridge.swift` (ids `50BE0001…0105`/`…0106`), `Sources/Supermux/SupermuxBannerProjectDecorator.swift` (ids `…0107`/`…0108`), and `Sources/TerminalNotificationStore+ReadToggle.swift` (ids `…0109`/`…010A`). Twelve `50BE0001` occurrences total (4 per file: build file, file reference, group membership, sources phase) |
| 368 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | The app ships ONE notification service extension: upstream's `NotificationService` target (`D4E2A007…`, product `NotificationService.appex`, `Embed App Extensions`, package dependency `CmuxPhonePush`). The fork adds `ios/SupermuxNotificationService/SupermuxNotificationDecorator.swift` (file ref `SMX1…0001`, build file `SMX1…0002`, group `SMX1…000B`) to that target's Sources phase, and `PROVISIONING_PROFILE_SPECIFIER = "$(SUPERMUX_NSE_DEV_PROFILE_SPECIFIER)"` to both of its configurations (the release script signs manually). The fork's former separate `SupermuxNotificationService` target (`SMX1…0003`–`SMX1…0010`, its `Embed Foundation Extensions` phase and dependency) was removed when the two extensions were merged — iOS runs only one notification service extension per app. The app's `PRODUCT_BUNDLE_IDENTIFIER`/profile read `$(SUPERMUX_APP_*)` — see #369 for why that indirection is load-bearing |
| 369 | `ios/Config/Shared.xcconfig` | `ios-communication-notifications`, `ios-nse-supermux-decoration` | Declares `SUPERMUX_APP_BUNDLE_ID` and chains upstream's `CMUX_APP_BUNDLE_IDENTIFIER` off it (`PRODUCT_BUNDLE_IDENTIFIER` derives from the upstream variable). `SUPERMUX_NSE_BUNDLE_ID` derives from `CMUX_APP_BUNDLE_IDENTIFIER` (so it follows every channel/dogfood override of either variable and stays a CHILD of the app id — iOS refuses to load an extension whose id is not). `SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS` defaults to upstream's `$(CMUX_APP_CODE_SIGN_ENTITLEMENTS)` (so upstream's tagged-device no-app-group override still reaches the app target) and feeds `CODE_SIGN_ENTITLEMENTS`. Also keeps the empty `SUPERMUX_APP_DEV_PROFILE_SPECIFIER` / `SUPERMUX_NSE_DEV_PROFILE_SPECIFIER` / `SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS` defaults. **The indirection is the whole point:** an xcodebuild command-line build setting applies to EVERY target in the workspace, so the release script's bundle-id/profile/entitlements overrides would otherwise be stamped onto the extension too. `ios-nse-supermux-decoration` points upstream's `CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER` at `$(SUPERMUX_NSE_BUNDLE_ID)` and `CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS` at `$(SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS)`, so upstream's extension signs as the fork's registered `<app id>.notification-service` App ID with the fork's entitlements |
| 370 | `ios/Config/Release.xcconfig` | `ios-communication-notifications`, `ios-nse-supermux-decoration` | Sets `SUPERMUX_APP_BUNDLE_ID` and derives upstream's `CMUX_APP_BUNDLE_IDENTIFIER` from it (instead of upstream's literal `dev.cmux.app.beta`), so both extension ids follow the Release channel's id and a dogfood `SUPERMUX_APP_BUNDLE_ID` override. The app entitlements come from upstream's `CMUX_APP_CODE_SIGN_ENTITLEMENTS = Config/cmux-release.entitlements` through the #369 chain (the fork's own `SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS` line was dropped at the 2026-09-30 upstream merge as redundant). `ios-nse-supermux-decoration` re-points `CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER` at `$(SUPERMUX_NSE_BUNDLE_ID)` after upstream's literal `dev.cmux.app.beta.NotificationServiceV2` (upstream's TestFlight lanes still win with their command-line value) |
| 371 | `ios/Config/Info.plist` | `ios-communication-notifications` | Adds `NSUserActivityTypes = [INSendMessageIntent]`, required by the Communication Notifications capability. Its absence is the ITMS-90894 rejection and, at runtime, one of several SILENT failures where the push still arrives but renders as an ordinary banner with no avatar |
| 372 | `scripts/supermux-ios-release.sh` | `unfenced` | Fork-owned. Ships the nested extension: passes `SUPERMUX_APP_BUNDLE_ID` / the per-target profile+entitlement variables instead of the workspace-wide overrides (#369); generalizes `resolve_adhoc_profile` to take a profile name and resolves the extension's second Ad Hoc profile; signs strictly INSIDE-OUT (extension frameworks → extension → app frameworks → app — signing the .app first invalidates its own signature); embeds each bundle's own `embedded.mobileprovision` and signs each with ONLY its own profile's entitlements; and asserts the extension's bundle id/child-prefix/extension point/principal class, the app's `NSUserActivityTypes`, the Communication Notifications entitlement in both profile and final signature, the extension's team + application-identifier, and a `codesign --verify --deep` pass. It also rejects the release unless the app registers the exact `cmux-ios-com.supermux.ios` pairing scheme, preventing a shared-scheme or wrong-bundle QR regression. Every one of those failures is otherwise silent |
| 373 | `Sources/Update/NotificationPopoverRow.swift` | `notification-popover-redesign` | The popover row now renders the SHARED row body (`Sources/Supermux/SupermuxNotificationRowBody.swift`) instead of its own layout. The popover and the notifications panel list the same notifications from the same store; with two independent bodies the redesign landed only in the panel while the popover — the surface behind the bell button and ⌘I, which is what most people open — kept the old look. Takes an `NSImage` resolved above the popover's `LazyVStack` (#374) and adds identity compares for it and the avatar flag to `==` — a store reference below that boundary is the #2586 spin-loop. Keeps the `…workspaceTitle` accessibility identifier that `MultiWindowNotificationsWorkspaceHeadlineUITests` queries. The fork's clear button keeps `.padding(8)` (unfenced) ahead of upstream's `.safeHelp`/`.accessibilityLabel`; upstream's `@Environment(\.cmuxAccentColor)` property is unused under the fork body (harmless) |
| 374 | `Sources/Update/UpdateTitlebarAccessory.swift` | `notification-read-toggle-shared`, `notification-popover-redesign` | Two fences. The read-toggle one is #356. The redesign one brings the titlebar popover to parity with the notifications panel: a two-tier header (identity line + control row with the grouping toggle, Mark All Read, and Clear All), project sections via `SupermuxNotificationGrouping`, and every project icon resolved ONCE above the `LazyVStack` via the shared `SupermuxNotificationProjectBridge.projectIcons(for:)` helper, passing immutable `NSImage` values down — the same snapshot-boundary discipline as the existing per-render title index. Grouping reads the SAME `supermux.notifications.groupByProject` key the panel writes, so one behavior has one preference. The control row stays mounted with its actions disabled when empty, because `MultiWindowNotificationsUITests` asserts Clear All exists-and-is-disabled in the empty popover. The `row(...)` helper's `onClear` follows upstream #5764 (no `withAnimation` around `remove`). Upstream's inline flat list is replaced wholesale by the fork's grouped list, so future upstream edits to that list must be ported into `row(...)` by hand; the group toggle symbol passes `tint: .primary` |
| 375 | `Sources/AppDelegate.swift` | `notification-project-banner` | One line in `applicationDidFinishLaunching` calling `SupermuxBannerProjectDecorator.sweepOrphanedAvatars()`. Avatar PNGs are handed to `UNNotificationAttachment`, which MOVES them into its own store; a banner that failed to schedule leaves its copy in the temp directory. Background, best-effort, older-than-an-hour |
| 376 | `ios/scripts/reload.sh` | `ios-communication-notifications` | Two sites (simulator leg and device leg) pass `SUPERMUX_APP_BUNDLE_ID` instead of `PRODUCT_BUNDLE_IDENTIFIER`. A command-line build setting applies workspace-wide, so the tagged override would otherwise stamp the app's id onto the notification service extension — and iOS silently refuses to load an extension whose bundle id is not a child of its container. See #369. Since the 2026-09-30 upstream merge each site passes `SUPERMUX_APP_BUNDLE_ID` **and** upstream's own `CMUX_APP_BUNDLE_IDENTIFIER`/`CMUX_HOST_BUNDLE_IDENTIFIER` (upstream shipped its own NotificationService extension and identity chain); unused build settings are harmless, so either chain resolves correctly |
| 377 | `ios/scripts/upload-testflight.sh` | `ios-communication-notifications` | Same redirection at both archive sites (beta and App Store lanes). **Known remaining gap:** this script's manual export map and its re-sign path still assume a PlugIns-free app, so the TestFlight/App Store lanes are not yet extension-ready — the fork's dogfood lane (`scripts/supermux-ios-release.sh`, #372) is. Fix before the next TestFlight upload. Since the 2026-09-30 upstream merge both archive sites also pass upstream's `CMUX_APP_BUNDLE_IDENTIFIER`/`CMUX_HOST_BUNDLE_IDENTIFIER`/`CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER`. Upstream's lanes now carry a notification-service bundle id and profile for **its** `NotificationService` extension, but still not for the fork's `SupermuxNotificationService`, so the gap above stands |
| 378 | `ios/scripts/cloud-testflight.sh` | `ios-communication-notifications` | Same redirection for the cloud beta archive. Also passes upstream's `CMUX_*_BUNDLE_IDENTIFIER` chain (including `CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER`) since the 2026-09-30 upstream merge |
| 379 | `CLAUDE.md` | `no-handoff-notify` | Overrides upstream's handoff notification rule with the fork's: **don't** `cmux notify` at handoff or closeout. Upstream's text is now one sentence at the end of the "CI, review and merge" merge bullet ("Notify with `cmux notify` when a socket is available."); it stays **byte-identical**, and the fenced `##` section right after that list ("Supermux: no `cmux notify` at handoff") overrides it. The agent harness already notifies on response completion, so a handoff `cmux notify` is a second alert for the same event. Explicitly still allowed: user asks for a ping, a skill/script that sends one as part of its job (the iPhone install queue), or testing the notification path. The old mid-dogfood `re-notify` sentence no longer exists upstream (moved to `skills/cmux-review`) |
| 380 | `Sources/Supermux/SupermuxNotificationRowBody.swift` | `unfenced` | **Fork-owned new file.** The single rendered body every macOS notification row uses — unread rail, project avatar, headline, provenance, preview, relative timestamp. Exists because the panel and the titlebar popover each had their own, so they disagreed on fonts, timestamp format, and whether an avatar appeared at all, and the surface the user happened to open decided what the feature looked like. Takes immutable values only, so it is safe below a lazy-list boundary |
| 381 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationRowPresentation.swift` | `unfenced` | **Fork-owned new file.** Decides WHAT goes on each line (headline = workspace else title; provenance = project + title minus anything the headline said; preview = body else subtitle). Pure string logic in the package so it is unit-tested directly rather than only through a rendered view |
| 382 | `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxSharedProjectIconStore.swift` | `unfenced` | **Fork-owned new file.** Project icon PNGs on disk in the app-group container, so the notification service extension can paint the REAL project logo on a push banner. Exists because the extension's first design rendered a generated chip from payload metadata alone, which is all a payload *can* carry: APNs caps a notification at 4096 bytes and a real icon is an order of magnitude past that (a 15 KB favicon is ~20 KB base64), so the bytes must arrive out of band. The app group is the only sanctioned shared surface — keychain-group sharing with the main install is forbidden (the Iroh stores half-share and mutually wipe relay credentials). Atomic writes, pruning that removes deleted/explicitly-iconless projects while preserving optional-`nil` legacy-host state, and a graceful no-op when the entitlement is absent |
| 383 | `ios/SupermuxNotificationService/SupermuxNotificationDecorator.swift` | `unfenced` | Fork-owned (formerly the fork extension's `NotificationService.swift`). `SupermuxNotificationDecorator.decorated(_:)` turns a plaintext push carrying `cmux.project` into a communication notification; upstream's extension calls it (#516). Reads the mirrored PNG through a **re-declared** reader (`SharedProjectIconStore`), for the same reason `PushProject` and the accent palette are re-declared: an app extension links its own copy of every dependency, and the mobile package graph is too heavy for a process with an execution budget. The app-group id and `project-icons/<id>.png` path shape are therefore a hand-maintained contract with #382, pinned by `SupermuxSharedProjectIconStoreTests`. Circular-masks the logo, honors the payload's authoritative `hasIcon` bit before touching mirrored bytes, and falls back to the generated chip whenever the snapshot is icon-less or no icon is stored. Before any of that, on EVERY direct push (notify and dismiss, project or not), it files the push's `aps.badge` (the pushing build's own unread count) under `cmux.macDeviceId` + `cmux.macInstanceTag` in `SupermuxPhoneBadgeLedger` and delivers the total over every Mac as the badge (#554–#557); it edits the content in place, so the expiration handler's undecorated delivery carries the total too |
| 384 | `ios/Config/supermux-notification-service.entitlements` | `unfenced` | **Fork-owned new file.** The notification service extension's entitlements: the host keychain group `$(AppIdentifierPrefix)$(CMUX_HOST_BUNDLE_IDENTIFIER)` (upstream's decryption reads phone-push key material from it) plus `group.com.supermux.ios` (project icons) — never upstream's `group.dev.cmux.ios`, which the Supermux App IDs lack. Deliberately not the app's file: that claims `aps-environment` and Communication Notifications, which the extension's App ID does not carry |
| 385 | `ios/Config/supermux.entitlements` | `unfenced` | Adds the app group beside the build-stage `aps-environment`. Note the App Store/TestFlight file (`cmux-release.entitlements`) is deliberately NOT touched — that channel is a different team and does not ship this extension |
| 386 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobilePaneUnreadPresentation.swift` | `unfenced` | **Fork-owned new file.** Projects the Mac-authoritative `supermux_unread_panel_ids` field onto the exact visible phone pane. `nil` means the host lacks pane-state support; `[]` means supported with no unread pane. Visibility alone never mutates state |
| 387 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadPaneRingStyle.swift` | `unfenced` | **Fork-owned new file.** Pins the mobile ring to the existing Mac pane ring's 2pt inset, 6pt corner radius, 2.5pt stroke, 0.35 glow opacity, and 3pt glow radius without changing the Mac renderer |
| 388 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxMobileUnreadPaneRing.swift` | `unfenced` | **Fork-owned new file.** Draws the persistent, hit-test-transparent system-blue pane ring on iOS using #387's Mac-parity geometry and glow |
| 389 | `Packages/iOS/SupermuxMobileUI/Tests/SupermuxMobileUITests/SupermuxMobilePaneUnreadPresentationTests.swift` | `unfenced` | **Fork-owned package coverage.** Proves exact pane membership, unsupported (`nil`) versus supported-empty (`[]`) capability semantics, fail-closed missing pane identity, independence from the workspace boolean, legacy open-receipt gating, and parity with the Mac ring metrics |
| 390 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+Surfaces.swift` | `ios-pane-unread-acknowledgment` | Mounts #388 as a visual-only overlay over the exact active terminal/chat/browser-stream/Simulator pane when #386 sees that pane id. The phone-local browser has no Mac pane identity and never receives the ring; the overlay adds no gesture or hit-test path |
| 391 | `Sources/Supermux/Workspace+SupermuxMobileUnread.swift` | `unfenced` | **Fork-owned new app-target file.** Serializes pane ids in spatial order with the exact macOS predicate: visible notification/focused-read indicator, panel manual/restored indicator, or the representative pane for workspace-manual unread. Missing notification storage sends supported-empty rather than inventing state |
| 392 | `Sources/TerminalController.swift` | `ios-pane-unread-acknowledgment` | Routes accepted phone terminal mouse and text input through `TabManager.dismissNotificationOnTerminalInteraction(tabId:surfaceId:)`, the same `NotificationDismissalModel` path as Mac click/key input. The model's selected-target guard keeps acknowledgment pane-scoped and clears focused-read/restored/manual terminal indicators without changing local Mac behavior. Since the 2026-09-30 upstream merge the mouse and input handlers use upstream's `ControlTerminalSocketTarget` (`terminalTarget`, `resolved.surfaceID`): the fences pass `surfaceId: surfaceId` (the canonical `resolved.surfaceID`) and sit after the `mobileInputAdmissionAnswer` early return, before `mobileClick` and before `applyMobileViewportReport(params:terminalTarget:)` respectively |
| 393 | `Sources/TerminalController+MobileBrowser.swift` | `ios-pane-unread-acknowledgment` | After a mobile browser click replays successfully, routes that exact panel through `dismissNotificationOnDirectInteraction`; move/scroll/key traffic is untouched, and the original browser action continues unchanged |
| 394 | `Sources/TerminalController+MobileSimulator.swift` | `ios-pane-unread-acknowledgment` | Routes an accepted Simulator `.tap` through `dismissNotificationOnDirectInteraction` for the resolved workspace/panel before forwarding the tap. Touch movement and non-pointer actions remain unchanged |
| 395 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite.swift` | `ios-pane-unread-acknowledgment` | Disables the legacy workspace-wide open read receipt when `supermux_unread_panel_ids` is present, so opening/visibility never clears sibling panes. Older/upstream Macs omit the field and keep the pre-existing broad fallback. Upstream's open read receipt is now a demo / SSH / Mac `if` chain; the fence wraps only the final `else if` condition (`shouldUseLegacyWorkspaceReadReceipt`), and upstream's `let workspaceHadUnread` stays unfenced above it (its demo branch needs it) |
| 396 | `Packages/SupermuxKit/Sources/SupermuxKit/Mobile/SupermuxMobileWorkspaceFields.swift` | `unfenced` | Adds the shared `supermux_unread_panel_ids` wire-key constant used by the legacy sender. The key always travels on a supporting Supermux Mac, including an empty array, so absence remains an unambiguous old-host capability signal |
| 397 | `Sources/Workspace.swift` | `supermux-mobile-workspace-fields` | Exposes one type-erased subject-backed publisher for exact manual/restored pane-unread changes. Upstream moved manual unread state into the Observation-backed `WorkspacePanelUnreadModel`, so the two mutation sites now explicitly send instead of relying on a removed `$manualUnreadPanelIds` Combine projection. `MobileWorkspaceListObserver` still subscribes narrowly, and exact pane-id changes propagate even while the workspace-level unread boolean stays true |
| 398 | `Sources/SessionNotificationSnapshot.swift` | `notification-project-identity` | Persists the optional frozen project snapshot in workspace session JSON and restores it into `TerminalNotification`. Optional/defaulted for backward compatibility with snapshots written before project-aware notifications. `project` follows upstream's `agentSessionId` (after `soundContext`, `agentKind` and `agentCategory`, added at the 2026-10-01 upstream merge) in all four places |
| 399 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationFocusPolicy.swift` | `unfenced` | **Fork-owned new file.** Pure focus reconciliation for filtered notification lists: preserve a still-visible row, otherwise choose the newest visible id, otherwise clear focus. Keeps SwiftUI state writes out of `body` and package-tests the Return-key target decision |
| 400 | `Packages/SupermuxKit/Tests/SupermuxKitTests/SupermuxNotificationFocusPolicyTests.swift` | `unfenced` | **Fork-owned package coverage.** Verifies preserved visible focus, reseating after filtering, and empty-list clearing |
| 401 | `Sources/Supermux/SupermuxNotificationProjectBridge.swift` | `unfenced` | Adds the single app-target project-icon snapshot resolver used by both macOS notification lists. It deduplicates project ids, skips invalid UUIDs, reads the warm icon store once above each `LazyVStack`, and returns immutable `NSImage` values; an injectable lookup seam gives app-target coverage without an observable store below the list boundary |
| 402 | `Packages/SupermuxKit/Sources/SupermuxKit/Notifications/SupermuxNotificationGrouping.swift` | `unfenced` | Project grouping's pure shared implementation. Project sections keep newest-first order, while the project-less sentinel is explicitly appended last even when the newest notification is unregistered; both the panel and popover inherit the fix |
| 403 | `Sources/Supermux/SupermuxBannerProjectDecorator.swift` | `unfenced` | macOS banner provenance/thread/avatar decorator. The raster cache key includes the rendered `avatarLetter`, so renaming a letter-avatar project cannot keep serving its previous initial; icon/symbol identities remain memoized |
| 404 | `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxProjectsSectionModel.swift` | `unfenced` | Revalidates the live store, project presence, custom-icon flag, and icon etag after the async fetch before writing the app-group mirror. A stale response cannot resurrect a removed or replaced logo |
| 405 | `Packages/iOS/SupermuxMobileKit/Sources/SupermuxMobileKit/SupermuxMobileProjectsStore.swift` | `unfenced` | Prunes the shared push-avatar mirror against live projects unless `hasCustomIcon` is explicitly `false`: deleted and confirmed-iconless projects lose stale files, while optional `nil` from older hosts remains "unknown" and preserves bytes a banner cannot re-fetch |
| 406 | `scripts/supermux-ios-release.sh` | `unfenced` | Treats `group.com.supermux.ios` as the fixed entitlement/runtime-reader contract. A conflicting `SUPERMUX_IOS_APP_GROUP` now fails before `xcodebuild` instead of producing a signature that verifies while both readers silently open another container |
| 407 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileSimulatorStreamStore.swift` | `simulator-stream-presentation-lifecycle` | Tracks mounted Simulator presentations by stable view identity, lets overlapping old/new details share the same active panel, restores selection when the old view disappears first, and clears presentation registrations through every explicit deactivate/close/discovery-removal path |
| 408 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SimulatorStream.swift` | `simulator-stream-presentation-lifecycle` | Makes selection-driven Simulator stops yield when the exact workspace/panel is active again before the serialized stop runs; background teardown stays unconditional through the existing private stop path |
| 409 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/SimulatorStreamPresentationLifecycleModifier.swift` | `simulator-stream-presentation-lifecycle` | Whole-file fork addition giving each mounted Simulator view a stable UUID, registering it on appear, restarting when it restores a current selection, and stopping only when its disappearance removes the final presentation. The `@Environment(MobileSimulatorStreamStore.self)` read is OPTIONAL (`guard let` in onAppear/onDisappear): upstream's `SimulatorStreamSurfaceLifecycleTests.transientUnmountKeepsSelectedSimulatorActive` hosts the content without injecting the store and a non-optional read crashes the xctest process. The app always injects it, so production behavior is unchanged; keep the read optional |
| 410 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+Surfaces.swift` | `simulator-stream-presentation-lifecycle` | Adds the direct `CMUXMobileCore` import needed for the generic focused-panel value, then replaces the Simulator pane's unconditional `onDisappear` teardown with the presentation-lifecycle modifier gated on the exact authoritative workspace/panel selection. The `CMUXMobileCore` import is upstream's own (unfenced) since the 2026-09-30 upstream merge; only the lifecycle modifier fence remains |
| 411 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileSimulatorStreamStoreTests.swift` | `simulator-stream-presentation-lifecycle` | Behavior coverage for both SwiftUI lifecycle orders: replacement appears before old detail disappears, and old detail disappears before replacement appears and must request a restart |
| 412 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileShellCompositeSimulatorStreamTests.swift` | `simulator-stream-presentation-lifecycle` | Red/green regression proving a delayed presentation stop cannot remove a reactivated panel's live-session marker, while a genuinely inactive panel still stops |
| 413 | `Sources/ContentView.swift` | `pull-request-glyph-arrowhead` | Gives `PullRequestOpenIcon` its left-pointing arrowhead: upstream drew two branches joined by a bare connector, which is the `git-branch` glyph rather than `git-pull-request`. Rounds the 45° chamfer into an arc and detaches the two branch strokes, matching GitHub's octicon and SupermuxKit's `SupermuxPullRequestGlyph` |
| 413b | `Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowSlotViews.swift` | `pull-request-glyph-arrowhead` | The AppKit twin of #413 in `SidebarRowPullRequestIconView.draw`, so the AppKit sidebar list draws the same corrected glyph as the SwiftUI one (`NSBezierPath.appendArc(from:to:radius:)`; the view is `isFlipped`, so the y-down geometry ports unchanged) |
| 145 | `cmuxTests/PostHogAnalyticsPropertiesTests.swift` | `unfenced` | **KNOWN FORK DEBT — this file is NOT yet modified; the row is a placeholder so the debt is not lost.** Three upstream tests contradict touchpoint #130 and are red on the fork: `appKitSidebarFeatureFlagDefaultsOn` asserts `defaultWhenUnavailable` for `sidebar-appkit-list-experiment` against the fork's `false`; `featureFlagResolutionPrecedence` sets a remote `true` for that key and asserts it reaches `remoteValue(for:)`; `remoteControlledFlagsRejectNewLocalOverrideWrites` sets a remote `true` for that key and asserts it blocks `setOverride`. Verified byte-identical to pre-merge `HEAD`, so this is standing debt, **not** 0.64.21 merge damage. Needs either a retarget of the three tests onto a neutral flag key or fences around the three expectations — OPEN DECISION, see SUPERMUX.md "Known limitations" |
| 413 | `Sources/Panels/Panel.swift` | `claude-harness-panel-case`, `claude-harness-panel-decode` | Adds `case claudeHarness` to `PanelType` plus the case-insensitive decode fallback so old/foreign-cased snapshots restore the Claude harness pane |
| 414 | `Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Core/Values/SurfaceKind.swift` | `claude-harness-surface-kind` | Additive `SurfaceKind.claudeHarness` static with the frozen wire string `claudeHarness` |
| 415 | `Packages/macOS/CmuxWorkspaces/Tests/CmuxWorkspacesTests/Core/WorkspaceCoreValueTests.swift` | `claude-harness-surface-kind` | Pins the `claudeHarness` raw value in the frozen-wire-string test |
| 416 | `Sources/Panels/PanelContentView.swift` | `claude-harness-panel-render`, `claude-harness-drop-target` | Renders `SupermuxHarnessPanelView` for `.claudeHarness`, threads the pane-level pointer-input gate into its WKWebView, and installs the pane drop overlay for tab transfers while allowing file-only drags to reach the harness composer |
| 417 | `Sources/Canvas/WorkspaceCanvasHostView.swift` | `claude-harness-canvas-icon` | Default canvas icon (`sparkles`) for the harness pane |
| 418 | `Sources/ContentView+SidebarSurfaceKind.swift` | `claude-harness-sidebar-kind` | Maps `.claudeHarness` to `.unknown` for the sidebar-extension surface kind |
| 419 | `Sources/ContentView+CommandPaletteSurfaceMetadata.swift` | `claude-harness-palette-label`, `claude-harness-palette-keywords` | Command-palette label ("Claude", localized `supermux.harness.palette.kind`) and search keywords for the harness pane |
| 420 | `Sources/ClosedItemHistory+PanelTitle.swift` | `claude-harness-closed-title` | Recently-closed fallback title for the harness pane |
| 421 | `Sources/CmuxLifecycleEventPublishing.swift` | `claude-harness-lifecycle-kind` | Publishes surface kind `claude_harness` in cmux lifecycle events |
| 422 | `Sources/Workspace+SurfaceNavigation.swift` | `claude-harness-surface-navigation` | Maps `.claudeHarness` to `SurfaceKind.claudeHarness.rawValue` in workspace state snapshots |
| 423 | `Sources/PaneDropContainer.swift` | `claude-harness-file-drop` | Keeps `.claudeHarness` out of the generic file-drop text destination after upstream consolidated drop routing into `PaneDropContainer`; harness file drags continue through the dedicated composer path |
| 424 | `Sources/Search/GlobalSearchDocuments.swift` | `claude-harness-global-search` | Indexes harness panes with `kind = .title` in global search |
| 425 | `Sources/Workspace+LayoutCapture.swift` | `claude-harness-layout-capture` | Counts the harness pane as an unsupported surface in declarative layout capture (placeholder terminal) |
| 426 | `Sources/Workspace.swift` | `claude-harness-snapshot`, `claude-harness-snapshot-arm`, `claude-harness-snapshot-field`, `claude-harness-restore-arm`, `claude-harness-transfer-in`, `claude-harness-attach-rollback` | Session snapshot local + arm + `SessionPanelSnapshot` field wiring, restore arm delegating to `restoreSupermuxHarnessPanel` while suppressing untrusted saved remote cwd values, cross-workspace transfer re-install of the display-state subscription plus a destination-workspace Git metadata reprobe after remote-directory trust is restored, and rollback detach on failed attach. The factory/subscription bodies live in the supermux-owned `Sources/Supermux/Harness/Workspace+SupermuxHarness.swift` |
| 427 | `Sources/Workspace+PanelLifecycle.swift` | `claude-harness-discard-subscription` | One-line `discardSupermuxHarnessPanelSubscription` call on panel discard |
| 428 | `Sources/SessionPersistence.swift` | `claude-harness-persistence-field` | Optional `claudeHarness: SessionSupermuxHarnessPanelSnapshot?` field on `SessionPanelSnapshot` |
| 429 | `Sources/Workspace+SidebarDirectories.swift` | `claude-harness-legacy-remote-directory` | Treats a legacy remote snapshot carrying a harness pane like an agent-session one for directory-provenance restore |
| 430 | `Sources/cmuxApp.swift` | `claude-harness-debug-menu` | Mounts `SupermuxHarnessDebugMenuButtons()` in the DEBUG-only Debug menu |
| 431 | `cmuxTests/SupermuxHarnessTests.swift` | `unfenced` | **Fork-owned new test file.** Trusted-shell-URL checks, harness snapshot round-trip/empty decode, `PanelType` claudeHarness decode, and `SessionPanelSnapshot` field carriage. pbxproj ids `50BE0001…012E`/`…012F` |
| 432 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the Claude harness into the app target: 19 app files under `Sources/Supermux/Harness/` (ids `50BE0001…0112`–`…012B`, `…0130`/`…0131` for `SupermuxHarnessWebRendererCoordinator+Bridge.swift`, `…0132`/`…0133` for `SupermuxHarnessCommandPaletteIntegration.swift`, `…0134`/`…0135` for `SupermuxHarnessBinarySetting.swift`, `…0136`/`…0137` for `SupermuxHarnessProcessSessionProtocol.swift`, `…013A`/`…013B` for `SupermuxHarnessNativeEventTransport.swift`, and `…013C`/`…013D` for `SupermuxHarnessWebHostOwnership.swift`, 4 entries each; the two `+` paths quoted), the `Resources/supermux-harness` folder reference (ids `…012C`/`…012D`, `lastKnownFileType = folder`), and `cmuxTests/SupermuxHarnessTests.swift` (ids `…012E`/`…012F`) plus `cmuxTests/SupermuxHarnessNativeEventTransportTests.swift` (ids `…013E`/`…013F`). Eighty-eight `50BE0001` occurrences total |
| 433 | `Sources/CmuxSurfaceTabBarBuiltInAction.swift` | `claude-harness-builtin-action` | Adds `case newClaudeHarness = "cmux.newClaudeHarness"` (specific config aliases `claude-harness` and `claudeharness`; generic `claude`/`harness` remain available to extensions), palette metadata (`supermux.harness.command.newPane.title`), `sparkles` icon, and the nil `bonsplitAction` grouping — the shared action id every entrypoint (palette, File menu, shortcut, plus-button, tab bar) routes through. The fenced nil-group lists upstream's `.newCloudWorkspace, .newCloudMachine` plus the fork's `.newClaudeHarness`. Since the 2026-09-30 upstream merge upstream's `shortcutAction` switch maps each built-in to its shortcut; a fenced arm returns `.supermuxNewClaudeHarness` for `.newClaudeHarness`. At the 2026-10-01 upstream merge upstream added `.copyWorkingDirectory`/`.copyProjectRoot`/`.copyScreen`; the fenced nil `bonsplitAction` group now spans upstream's two-line case list plus `.newClaudeHarness`, and the `shortcutAction` arm follows upstream's copy-action nil group. Upstream's new `terminalCopyAction` switch needs its own arm (#600) |
| 434 | `Sources/Workspace.swift` | `claude-harness-executor-arm` | Surface-tab-bar built-in button executor arm: `.newClaudeHarness` calls `newSupermuxHarnessSurface(inPane:focus: true)` beside the Simulator arm. At the 2026-10-01 upstream merge the arm sits between upstream's `.newSimulator` arm and its new copy-actions arm |
| 435 | `Sources/AppDelegate.swift` | `claude-harness-configured-action`, `claude-harness-shortcut-dispatch` | `executeConfiguredCmuxAction` arm delegating to `performConfiguredNewClaudeHarnessAction` (fork-owned, in `SupermuxHarnessCommandPaletteIntegration.swift`), and the ⌃⌘A keyboard dispatch (`supermuxNewClaudeHarness`, non-repeat, beeps on failure) |
| 436 | `Sources/ContentView.swift` | `claude-harness-palette-contribution` | Registers the `palette.newClaudeHarnessPane` command (contribution beside the Simulator one + handler registration; always available, no feature flag) |
| 436b | `Sources/ContentView+AgentChatCommandPalette.swift` | `claude-harness-palette-id-map` | Maps `palette.newClaudeHarnessPane` to the `cmux.newClaudeHarness` config action id in `commandPaletteConfigActionID(for:)` |
| 437 | `Sources/cmuxApp.swift` | `claude-harness-file-menu` | File menu "New Claude Pane" item (`supermux.harness.menu.file.newPane`) with the live `supermuxNewClaudeHarness` shortcut, calling `performNewClaudeHarnessPaneFromMenu()` |
| 438 | `Sources/CmuxConfig.swift` | `claude-harness-config-action` | `CmuxSurfaceTabBarButton.newClaudeHarness` action reference so `cmux.json` surface-tab-bar/plus-button configs can reference the built-in by id |
| 439 | `Sources/KeyboardShortcutSettings.swift` | `claude-harness-shortcut-case`, `claude-harness-shortcut-label`, `claude-harness-shortcut-default` | App-target `supermuxNewClaudeHarness` action: case, label (`supermux.harness.shortcut.newPane.label`), default ⌃⌘A (unclaimed; verified against both default tables) |
| 440 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/Values/ShortcutAction.swift` | `claude-harness-shortcut-case` | Package mirror `case supermuxNewClaudeHarness` (defaults/display-name/group arms live inside the existing `supermux-shortcut-defaults`/`-display-names`/`-groups` fences of #62b/#62c/#63) |
| 441 | `Sources/TerminalControllerV2ParamParsingSupport.swift` | `claude-harness-socket-token` | Socket v2 panel-type token `claudeharness` (the normalizer folds `claude-harness`/`claude_harness`/`ClaudeHarness` into it), so `cmux new-surface --type claude-harness` resolves to `.claudeHarness` |
| 441b | `Sources/TerminalController+ControlSurfaceContext2.swift` | `claude-harness-socket-create-arm`, `claude-harness-socket-split-guard` | `surface.create` arm calling `newSupermuxHarnessSurface` (respects the `focus` param via `v2FocusAllowed`; workspace placement only — the Dock guard's terminal/browser-only check already rejects it) and the `surface.split` guard rejecting the type like agent-session. CLI `new-surface` help strings mention `claude-harness` (unfenced doc-string edits in `CLI/cmux.swift`) |
| 441c | `Sources/TerminalController+ControlPaneContext.swift` | `claude-harness-socket-split-guard` | `pane.create` (new-pane) guard rejecting `claudeHarness` splits like agent-session |
| 442 | `web/data/cmux-shortcuts.ts` | `claude-harness-shortcut-doc` | Documents the ⌃⌘A New Claude Pane shortcut in the surfaces section of the keyboard-shortcut registry (en + ja) |
| 443 | `Sources/TabManager.swift` | `claude-harness-restore-git-probe` | One-line `workspace.scheduleSupermuxHarnessGitMetadataProbes(reason:)` call inside the post-session-restore sweep, right after upstream's `TerminalPanel` probe loop. Without it a restored workspace whose only pane is a harness pane never gets a sidebar git probe scheduled and shows no branch in its workspace tab |
| 444 | `Sources/TabManager+SidebarGitHosting.swift` | `claude-harness-git-probe-eligible` | `hasTerminalPanel(workspaceId:panelId:)` also returns `true` for a `SupermuxHarnessPanel`. That `SidebarGitHosting` seam has exactly one caller — `SidebarGitMetadataService.restartWorkspaceGitMetadataWatching` — where it gates "may this panel be git-probed", so a harness-only workspace would lose its branch after the sidebar-git watch setting is toggled back on |
| 445 | `Sources/Panels/PanelContentView.swift` | `claude-harness-panel-render` | (Existing fence, widened.) The `.claudeHarness` arm passes both unread state and `allowsPointerInput` into `SupermuxHarnessPanelView`, matching the shared pane visibility/input gates while retaining the harness-specific top-edge unread treatment |
| 446 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the fork-owned `Sources/Supermux/Harness/SupermuxHarnessUnreadIndicator.swift` into the cmux target with reserved ids `50BE0001…0138` (file reference) / `…0139` (build file); 4 `50BE0001` occurrences (build file, file reference, group membership, sources phase) |
| 447 | `.github/workflows/ci.yml` | `harness-web-ci` | Adds the `harness_web` route output (`harness_web: ${{ steps.detect.outputs.harness_web || 'false' }}` — the detector emits `harness_web=true` only when routed, and `emit_all_areas` echoes it) and the pinned-Bun Linux `harness-web` job (frozen install, typecheck, full Bun suite, production bundle build, committed-resource freshness check; upstream's standard Linux `runs-on` expression, `permissions: contents: read`, `persist-credentials: false`), then makes that job a direct need of `linux-preflight`, the stable `tests` aggregate, `ci-status` **and `macos-admission-gate`** (upstream's `test_macos_admission_gate_needs_every_fast_linux_only_job` derives the gate's needs from every fast Linux-only job). The routed/unrouted checks in the `tests` gate and `linux-preflight` are standalone fenced blocks reading `needs.get("harness-web", …)` — a routed skip fails, an unrouted skip passes, a failure always fails — not entries in upstream's `allowed_routed`/`routed_outputs` dicts, so upstream's fixtures without the key keep passing. Since the 2026-09-30 upstream merge upstream skips product-area CI for router-only edits, so a pure `ci.yml`/router change no longer runs the lane. At the 2026-10-01 upstream merge upstream changed both aggregate jobs' `if: ${{ always() }}` to `if: ${{ !cancelled() }}`; the fenced `- harness-web` needs entries sit right above upstream's new comment and `if` |
| 448 | `scripts/ci/detect_ci_change_areas.py` | `harness-web-ci` | Adds the independent `harness_web` change area for `harness-web/**`, the committed `Resources/supermux-harness/**` bundle, its build script, and the root package script registry without widening the broad website area or changing existing macOS classification. `ChangeAreas.harness_web` defaults to `False` (upstream's many literals stay unchanged), `all()` and `__or__` carry it, `classify_files` sets it in the `forces_all_areas` branch (not the `WEB_WORKFLOW_PATH` branch git once auto-merged it into), and `as_output_lines()` appends `harness_web=true` only when true so every upstream exact-output assertion stays valid. `harness_web` is not in `_AREA_NAMES`, so a `scripts/ci` helper referenced from the harness job fails open to all areas |
| 449 | `tests/test_ci_change_areas.py` | `harness-web-ci` | Fenced `areas()` helper extension (passes `harness_web`), four fenced "all areas" expectation edits (`test_ci_workflow_areas_route_through_classify_files`, `test_workflow_diff_failure_runs_all_areas`, `test_cli_empty_diff_runs_all_areas`, `test_workflow_self_change_guard_runs_before_detector_imports` gain `harness_web`/`"harness_web=true"`), and one fenced block of 8 fork tests before `_run_named_test`: harness inputs route, website-only files do not, the emit-only-when-routed output contract, the detect step routes harness without web, the `tests` gate (routed skip and failure both fail), `linux-preflight` (routed skip fails, unrouted skip passes), `harness-web` is a need of all four gates, and the job's pinned Bun/validation commands. The tests use upstream's `run_tests_gate`/`tests_gate_needs`/`linux_preflight_needs` helpers (the old `run_required_tests_gate`/`required_tests_needs` names are gone) |
| 450 | `cmuxTests/SupermuxHarnessNativeEventTransportTests.swift` | `unfenced` | **Fork-owned new test file.** Executable transport contract coverage for acknowledgement retention, identical retry, stale-ack safety, navigation re-sequencing, count/byte batching, bounded backlog, and stale host generations. pbxproj ids `50BE0001…013E`/`…013F` |
| 451 | `cmuxTests/SupermuxFocusedPaneNotificationTests.swift` | `unfenced` | **Fork-owned new test file.** Exact regression coverage that a notification targeting the already-focused pane is retained only as read history: no unread count, badge state, pane indicator/flash, delivered alert, or sound; explicit custom-command automation remains enabled. pbxproj ids `50BE0001…0140`/`…0141` |
| 452 | `Sources/Supermux/SupermuxFocusedPaneNotificationPolicy.swift` | `unfenced` | **Fork-owned new app-target policy.** Defines the one exact-target decision (`surfaceID != nil` plus `exactPaneFocused`, the store's `isFocusedSurfaceArrival` — never the external-delivery gate, which with upstream's `notifications.suppressWhenAppFocused` on is just "cmux is frontmost") and resolves presentation effects: preserve record/custom-command automation, suppress unread/reorder/desktop/sound/pane-flash |
| 453 | `Sources/TerminalNotificationStore.swift` | `focused-pane-notification-suppression` | Applies #452 once at final live-owner admission, after async notification hooks and retargeting, so the already-focused exact pane is recorded read and every unread/badge/ring/flash/desktop/sound/reorder surface inherits one decision. The policy call passes `exactPaneFocused: isFocusedSurfaceArrival`, NOT `shouldSuppressExternalDelivery`: with `suppressWhenAppFocused` on that gate is merely "cmux is frontmost", which recorded every pane's notification read (and acknowledged mirror copies to the other Mac). The existing #332 direct APNs fence consumes the same policy, with the same argument, before forwarding. Since the 2026-09-30 upstream merge the fence also owns upstream's new `effects.keepingFocusedWorkspaceInPlace(isFocusedPane:)` shadow: upstream's `let effects = …` becomes `var effects = …` inside the fence and the fork's policy assigns `effects = focusedPanePolicy.resolvedEffects(…)` instead of redeclaring it |
| 454 | `cmuxTests/NotificationAndMenuBarTests.swift` | `focused-pane-notification-suppression-feedback-test`, `focused-pane-notification-suppression-indicator-test` | Updates the old focused-alert contract to require read/no-sound presentation while preserving custom-command automation, and seeds the legacy focused-read-indicator lifecycle explicitly rather than relying on a newly focused notification to create it |
| 455 | `cmuxTests/TerminalAndGhosttyTests.swift` | `focused-pane-notification-suppression-interaction-fixtures` | Keeps mouse/key direct-interaction dismissal coverage meaningful by seeding unread while app focus is false, then restoring active focus before the actual interaction; a notification created while already focused no longer supplies that fixture |
| 456 | `cmuxTests/WorkspaceUnitTests.swift` | `focused-pane-notification-suppression-navigation-fixture` | Keeps the competing-unread navigation-flash test valid by modeling attention that arrived while the app was not focused, then restoring active focus before pane navigation |
| 457 | `cmuxTests/AgentNotificationMoveRaceTests.swift` | `focused-pane-notification-suppression-move-test` | Updates the immediate source-confined relay assertion: a focused target is stored read with no focused-read indicator before the panel moves, while the test still proves it never rebinds across the authorized workspace boundary |
| 458 | `docs/notifications.md` | `focused-pane-notification-suppression-doc` | Documents the exact focused-pane behavior and its boundary: read history remains, user-facing alert surfaces and mobile push are suppressed, explicit command automation remains, and targetless workspace notifications keep existing behavior |
| 459 | `CLAUDE.md` | `dogfood-direct-launch-link` | A self-contained `##` section ("Supermux: tagged build handoff links") after upstream's "Verification and isolation". Replaces the localhost Tag Opener handoff with the tagged app's native `cmux-dev-<tag>://launch` Markdown link. Build-only handoffs register the printed app path through `lsregister -f`; `--launch` already registers it. The link launches directly through LaunchServices without a browser/server and reserves `auth-callback` for sign-in |
| 460 | `skills/cmux-dev-workflow/references/tagged-builds.md` | `dogfood-direct-launch-link-skill` | Mirrors #459 in the contributor workflow reference: direct custom-scheme handoff, build-only LaunchServices registration, normalized tag slug, inert `launch` host, and the same ban on raw app/DerivedData paths in chat. The fork section replaces upstream's one-line App-path paragraph at the end of "Compile-only checks", and notes that a `--build-only` run leaves nothing to link |
| 461 | `Sources/AppDelegate+DockSurfaceMove.swift` | `claude-harness-dock-admission` | Rejects workspace→Dock and Dock→Dock moves for Claude harness panels because Dock does not own their controller subscription, bridge routing, or persistence lifecycle |
| 462 | `tests/test_ios_appstore_lane_identity.py` | `ios-appstore-lane-identity` | Additive fork fences on top of upstream's own `CMUX_APP_BUNDLE_IDENTIFIER` fake-xcodebuild parsing and checks (which stay): `bundle_id = setting("SUPERMUX_APP_BUNDLE_ID=") or bundle_id` after upstream's line, fenced checks that `SUPERMUX_APP_BUNDLE_ID` is stamped for beta and App Store and that the retired `com.cmuxterm.app` is never stamped on the Supermux chain, plus the fake `otool` for embedded-framework inspection |
| 463 | `Packages/macOS/CmuxRemoteDaemon/Tests/CmuxRemoteDaemonTests/RemoteDaemonRPCClientTimeoutIsolationTests.swift` | `remote-daemon-timeout-isolation-event-queues` | Gives the timeout-isolation PTY callback a dedicated serial queue so unrelated global-queue contention cannot starve the test's synchronization path. Since the 2026-10-01 upstream merge only the first test (`existingPTYEventQueue`) carries the fence: upstream #15921 rewrote `timedOutPTYAttachBoundsCancellationWrite` around an idle transport with no PTY attach, so its `stalledAttachEventQueue` fence was dropped |
| 464 | `package.json` | `unfenced` | Registers the root `harness-web:build` command that invokes `scripts/supermux-build-harness-web.sh` for local and CI bundle freshness checks |
| 465 | `Sources/TerminalPaneDropTargetView.swift` | `claude-harness-file-drop-passthrough` | Adds a per-overlay file-drop capture policy: harness panes keep tab-transfer hit testing but pass file-only drags through to their WKWebView composer; existing terminal and preview overlays retain file-drop capture by default. `shouldCaptureHitTesting` carries upstream's `hasLiveTabTransfer`/`hasLiveFileDropPayload`, then the fenced `capturesFileDrops`. Upstream moved `PaneDropTargetRepresentable` out of this file at the 2026-09-30 upstream merge; its two fences are #499 |
| 466 | `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Pane/ControlCommandCoordinator+Pane.swift` | `claude-harness-socket-split-error` | Formats the rejected pane type into the `pane.create` error instead of always claiming the request was for `agent-session`, so a rejected `claudeHarness` split reports its actual type |
| 467 | `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Surface/ControlCommandCoordinator+Surface.swift` | `claude-harness-socket-split-error` | Formats the rejected surface type into the `surface.split` error instead of always claiming the request was for `agent-session`, so a rejected `claudeHarness` split reports its actual type |
| 468 | `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Pane/ControlPaneCreateResolution.swift` | `claude-harness-socket-split-error` | Broadens the rejection-case API documentation from agent-session-only wording to every surface kind that `pane.create` routes exclusively through `surface.create` |
| 469 | `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Surface/ControlSurfaceSplitResolution.swift` | `claude-harness-socket-split-error` | Broadens the rejection-case API documentation from agent-session-only wording to every surface kind that `surface.split` routes exclusively through `surface.create` |
| 471 | `Packages/macOS/CmuxControlSocket/Tests/CmuxControlSocketTests/ControlCommandCoordinatorSurfaceTests.swift` | `claude-harness-socket-split-error-test` | Verifies both `pane.create` and `surface.split` errors name `claudeHarness` rather than incorrectly reporting `agent-session`. The `splitResolution` seam it sets is upstream-owned since the 2026-09-30 upstream merge (#470 retired) |
| 472 | `Sources/FileDropOverlayViewHitTesting.swift` | `claude-harness-file-drop-passthrough` | Makes the window-level Finder drag overlay honor `PaneDropTargetView.capturesFileDrops`, so a harness overlay that passes file drags through cannot be rediscovered and invoked out-of-band while tab-transfer routing remains intact |
| 482 | `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/KimiConfigLocationResolver.swift` | `lint-allow-upstream-debt` | Fenced namespace allowance for upstream's stateless Kimi configuration layout resolver |
| 485 | `Sources/TerminalController+MobileSurfaces.swift` | `claude-harness-mobile-surface-kind` | Maps the fork's Claude harness panel to the open mobile surface wire string `claudeHarness`, so generic phone surface inventories stay exhaustive and render it through upstream's unknown-kind fallback card |
| 486 | `cmuxTests/MobileSurfaceKindMappingTests.swift` | `claude-harness-mobile-surface-kind` | Extends the canonical PanelType→mobile-wire mapping regression with the fork's `claudeHarness` case |
| 488 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MacSurfaceGalleryPreviewView.swift` | `ios-pane-actions` | Supplies an inert New Simulator closure to upstream's gallery preview fixture so the fork-extended `TerminalPickerMenuActions` memberwise initializer remains compilable without changing preview behavior |
| 489 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/CmxPairingURLSchemeTests.swift` | `supermux-release-mobile-identity` | Regression coverage requiring the fixed Supermux iOS release bundle to own an exact release-classified pairing URL scheme |
| 490 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/MobileMacBuildCompatibilityPolicyTests.swift` | `supermux-release-mobile-identity` | Regression coverage requiring the official iOS policy to admit the exact Supermux macOS release namespace over authenticated Tailscale host status |
| 491 | `cmuxTests/MobileHostIdentityTests.swift` | `supermux-release-mobile-identity` | Regression coverage requiring the Supermux Mac release to target the fixed `com.supermux.ios` app for pairing by default (available/selected namespace and pairing URL scheme). Push targeting moved server-side upstream in #13741 (baa24b68731, which removed `MobileIOSPairingTargetStore.pushTargetNamespace`), so the fence's former push assertion was dropped at the 2026-09-30 upstream merge |
| 492 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/CmxPairingURLScheme.swift` | `supermux-release-mobile-identity` | Classifies the fixed `cmux-ios-com.supermux.ios` exact-bundle scheme as a release lane instead of rejecting the Supermux iOS identity |
| 493 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileMacBuildCompatibilityPolicy.swift` | `supermux-release-mobile-identity` | Admits the exact `mac:com.supermux.app` namespace under the official Release compatibility policy while keeping unknown namespaces fail-closed |
| 494 | `Sources/Mobile/MobileIOSPairingTargetStore.swift` | `supermux-release-mobile-identity` | Makes the fixed Supermux Mac release target only `com.supermux.ios` for QR pairing; upstream cmux release and tagged DEV target selection remain unchanged. (Pushes are no longer chosen here: upstream #13741 removed `pushTargetNamespace`, `PhonePushClient` sends `targetBundleIdentifier: nil`, and the server fans out to every iOS build registered for the account) |
| 495 | `Sources/Mobile/Pairing/MobilePairingModel.swift` | `supermux-release-mobile-identity` | Gives the fixed Supermux iOS pairing target its localized product name in the Mac pairing window |
| 496 | `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/SocketControl/SocketControlSettingsTests.swift` | `socket-override-foreign-bundle-test` | Regression tests: a tagged dev build ignores a `CMUX_SOCKET_PATH` override inherited from a different cmux bundle even with `CMUX_ALLOW_SOCKET_OVERRIDE=1`, and still honors one that names its own bundle |
| 497 | `Packages/macOS/CmuxSettings/Sources/CmuxSettings/SocketControl/SocketControlSettings.swift` | `socket-override-foreign-bundle` | `shouldHonorSocketPathOverride` checks the inherited `CMUX_BUNDLE_ID` conflict before the allow flag, so a tagged build opened from inside the Supermux release app (whose LSEnvironment bakes `CMUX_ALLOW_SOCKET_OVERRIDE=1`) keeps its own socket instead of adopting `/tmp/supermux.sock` |
| 498 | `Sources/RightSidebarMode.swift` | `right-sidebar-changes-mode-*` | Upstream moved the `RightSidebarMode` enum (case, label, symbol, shortcutAction, paneModes) out of `RightSidebarPanelView.swift` into this file at the 2026-09-30 upstream merge; carries the four fences `-case`, `-label`, `-symbol` and `-shortcut` (returns nil). `case changes` is declared AFTER upstream's `case machines`: upstream's tab-order / ⌃1–9 positional shortcuts follow `allCases`, so Changes last keeps every upstream tab's digit, and Changes (no switch action) takes no digit |
| 499 | `Sources/PaneDropTargetRepresentable.swift` | `claude-harness-file-drop-passthrough` | Two fences: the `capturesFileDrops` property and `nsView.capturesFileDrops = …` in `updateNSView`. Upstream split `PaneDropTargetRepresentable` out of `TerminalPaneDropTargetView.swift` (#465) at the 2026-09-30 upstream merge; the fences moved with it |
| 500 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceTitleMenuValue.swift` | `ios-workspace-toolbar-persistent-actions` | Adds `var toolEntriesFingerprint: String = ""` after upstream's `canReconnect`/`canBrowseFiles` (before `labelToken`) so the equatable title menu re-accepts its closure when fork entry availability or run state changes. Memberwise order is `… canCloseWorkspace, canReconnect, canBrowseFiles, connectedDevices, toolEntriesFingerprint, labelToken, terminalTheme` (upstream's `connectedDevices` arrived at the 2026-10-01 upstream merge). Part of #228; registered separately at the 2026-09-30 upstream merge |
| 501 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceTitleMenuValueTests.swift` | `ios-workspace-toolbar-persistent-actions` | Three fences (previously unfenced): the `forkMenuFingerprintInvalidatesTheMenuValue` test and the helper's `toolEntriesFingerprint` param/argument. The test passes `connectionStatus: .connected` because upstream's `.standard(title:subtitle:)` now requires it |
| 502 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListRowModel.swift` | `supermux-mobile-projects-table-row` | Four fences: `import SupermuxMobileUI`; `WorkspaceListRowModel.supermuxProjects(SupermuxProjectsTableRowConfiguration)`; `WorkspaceListRowLayoutKey.supermuxProjects(String)` (height identity); and the `.chrome(.supermuxProjects)` case in `rowModel(for:)` (nil payload → `.missing`, zero height). Upstream's table-engine rewrite (c4dcf650783) moved the coordinator's diff/height inputs into this new file at the 2026-09-30 upstream merge. See #150 |
| 503 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListRowModel.swift` | `supermux-mobile-row-activity` | Two fences: `WorkspaceListWorkspaceRowModel.supermuxActivity` (defaulted nil) and the `supermuxActivity: workspace.supermuxActivity` argument in `rowModel(for:)`. Keeps the activity dot in the row model so a status-only change re-renders the cell (#294 reads it) |
| 504 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/Debug/WorkspaceListLayoutPreviewView.swift` | `supermux-mobile-compact-root-chrome` | Five fences: import; `@State fixtureRootChrome`; `SupermuxInteractivePopObserver` on the fixture destination; stack-level `onChange(of: fixtureRoute?.id)` + `.mobileToolbarVisibility(...)` (the iOS 17-safe wrapper); and a comment-only marker where the fork deletes upstream's destination tab-bar hide. Mirrors #259 so UI tests can observe pop timing without a Mac. Pre-existing fences, first registered at the 2026-09-30 upstream merge. Upstream moved the file under `Debug/` at the 2026-10-01 upstream merge (git rename detection carried the fences) |
| 505 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+Actions.swift` | `supermux-mobile-projects-section` | One fence: `supermuxRequestWorkspaceClose`, a `@MainActor`-typed wrapper over upstream's `requestWorkspaceClose` (which now routes through upstream's `workspaceCloseConfirmation(for:)`), so the Projects section driver's nested workspace rows close through the shell's confirmation instead of a second close path. Pre-existing fence, first registered at the 2026-09-30 upstream merge |
| 506 | `CLI/CMUXCLI+TaskHelp.swift` | `unfenced` | Upstream moved the top-level `usage()` out of `CLI/cmux.swift` into this file at the 2026-09-30 upstream merge. One unfenced string edit: the `new-surface [--type <…|claude-harness>]` help line lists `claude-harness` (keeping upstream's `[--command <text>]`). See #10 |
| 507 | `ios/cmux/Assets.xcassets/LaunchLogo.imageset` | `unfenced` | Upstream's iOS launch screen (`UILaunchScreen` in `ios/Config/Info.plist`, #10621/#10913) shows this imageset; the fork re-renders `LaunchLogo.png`/`@2x`/`@3x` (64/128/192 px) from the fork's `CmuxLogo` art so the phone does not flash the cmux glyph at launch. Re-apply after any upstream change: extract the base64 PNG from `CmuxLogo.imageset/cmux-logo.svg` and `sips -z 64 64` / `-z 128 128` / `-z 192 192`. `LaunchBackground.colorset` is upstream's |
| 508 | `Packages/iOS/CmuxMobileShellUI/Tests/CmuxMobileShellUITests/WorkspaceListCellIdentityTests.swift` | `unfenced` | Whole-file fork test inside the upstream package (the retired #251's regression test). It now pins behavior upstream's rebuilt engine provides — same cell after a height change, the height is re-queried, a native-action change commits geometry — adapted to `groupUnreadByID`, `unreadBadgeDiameter: 16` and `PayloadApplyRoute.geometryCommitted`. Its doc comment still says `reconfigureRows` (stale prose only) |
| 509 | `cmuxTests/FileDropOverlayViewTests.swift` | `unfenced` | Pre-existing registry gap surfaced at the 2026-09-30 upstream merge: the fork test `overlaySkipsPaneTargetsThatPassFileDropsThrough` (#465/#472 pass-through coverage) and its `import Bonsplit` are unfenced. Fence them under `claude-harness-file-drop-passthrough` when next touched |
| 510 | `Sources/AppDelegate+NewWorkspaceContextMenu.swift` | `claude-harness-builtin-action` | Upstream's exhaustive `isBuiltInActionAvailableInNewWorkspaceMenu` switch (the new-workspace context menu's availability gate, mirroring the command palette) gains a fenced `.newClaudeHarness` arm returning `true` — always available, like the palette command (#436). Added at the 2026-09-30 upstream merge, when upstream introduced this file |
| 511 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobilePinnedNavigationBar.swift` | `ios27-sdk-no-toolbar-minimize` | **Local-toolchain workaround.** Changes upstream's `#if compiler(>=6.4)` in `mobilePinnedNavigationBar()` to `#if compiler(>=6.4) && SUPERMUX_IOS27_TOOLBAR_MINIMIZE` (the flag is never defined), so the UIKit `PinnedNavigationBarApplier` stand-in is always used. Xcode 27.0 (27A266a, Swift 6.4) ships an iOS 27 SDK without `toolbarMinimizeBehavior(_:for:)`, so upstream's gate fails to compile here; upstream CI (Xcode 26, Swift < 6.4) never compiles that branch. RETIRE when the SDK exposes `toolbarMinimizeBehavior` or upstream fixes the gate: delete the fence and take upstream's line |
| 512 | `cmuxTests/DockPortalReconcileTests.swift` | `claude-harness-dock-admission-test` | Fork test `harnessSurfaceCannotMoveIntoDock` (fork commit 4224cc3a8ae) inside upstream's Dock test suite: a workspace-owned Claude harness surface is rejected by both `canMoveSurfaceIntoDock` and `moveSurfaceIntoDock` and stays with its workspace (regression coverage for #461). Was unfenced until the 2026-09-30 upstream merge, which also adapted it to upstream's Optional `workspace.dockSplit` (`workspace.requiredDockSplitForTesting`, matching the sibling tests) |
| 513 | `Sources/CmuxFeatureFlagOverrideCapability.swift` | `supermux-release-cloud-override` | Adds `isSupermuxRelease` (`bundleIdentifier == "com.supermux.app"`) and ORs it into `allowsCloudOverride`, so the fork's release identity gets the `.localFirst` override policy for `cloud-machines-enabled-release` that upstream grants only Nightly and Debug. Upstream's rollout does not include Supermux accounts, and Mac-to-Mac My Devices (`DevicesFeature`) is gated on the same Cloud flag |
| 514 | `Sources/FeatureFlags.swift` | `supermux-release-cloud-override` | In `CmuxFeatureFlags.init`, seeds the Cloud override to `true` once for the Supermux release identity (only when no override value is stored, so a later explicit choice in the Feature Flags window sticks). The Beta Features Cloud Machines toggle is still required. Server-side entitlements are unchanged: Cloud VM creation may still be refused; My Devices is the intended use |
| 515 | `Sources/GhosttyTerminalView.swift` | `release-clear-selection-seam` | **Release-build compiler-crash workaround.** `sendSyntheticGhosttyMouseRelease` calls `GhosttyRuntimeCInterop.clearSelection(surface)` instead of the header-imported `ghostty_surface_clear_selection`. The ghostty pin now exports that symbol in `ghostty.h` as `(ghostty_surface_t)` (Optional pointer) while `CmuxTerminalCore` still binds it via `@_silgen_name` with a non-optional pointer; with both in the Release SIL link, swift-frontend 6.2.4 aborts with `SILFunction type mismatch for 'ghostty_surface_clear_selection'` (DESERIALIZATION FAILURE) and `scripts/supermux-release.sh` fails |
| 516 | `ios/NotificationService/NotificationService.swift` | `ios-nse-supermux-decoration` | Upstream's extension is the app's only notification service extension. When a push carries no `encryptedPayloads` (the fork's direct Mac→APNs push, #332), it delivers `SupermuxNotificationDecorator.decorated(content)` (#383) instead of the raw content; the decorator also turns the pushing Mac's `aps.badge` into the total over every Mac (#554–#557). Encrypted relay pushes keep upstream's decrypt path untouched, and the expiration handler still delivers the undecorated content (whose badge the decorator already totalled in place) |
| 517 | `Sources/Devices/DeviceLink.swift` | `device-link-supermux-events` | Remote Macs as first-class workspaces (plans/supermux-remote-workspaces). Four small fenced sites: (1) `static let eventTopics` wraps upstream's literal in `Set<String>(…)` and unions `SupermuxDeviceLinkEvents.topics` (the four `SupermuxMobileTopic` values `supermux.projects/worktrees/changes/run.updated`; the host accepts any topic set); (2) in `handle(_:)`, a `case let topic where SupermuxDeviceLinkEvents.topics.contains(topic)` arm before `default` forwards the envelope to `SupermuxDeviceLinkEvents.receive(instance:topic:payload:)`; (3) in `startConnect`, after the post-connect fetch and `onNotificationFeedChange`, `SupermuxDeviceLinkEvents.linkConnected(instance:)`; (4) in `tearDownClient(notify:)`, `if notify { SupermuxDeviceLinkEvents.linkLost(instance:) }`. All land on `SupermuxComposition.devices` (`Sources/Supermux/Devices/`), which tracks "records fetched since the last connect", refetch-on-reconnect and host-capability cache resets |
| 518 | `Sources/Mobile/MobileStateSync.swift` | `device-mirror-export-filter` | Loop guard: `buildRows` skips a workspace for which `SupermuxDeviceWorkspaceIndex.isDeviceMirror(_:)` is true (bound by the fork's mirror binding store, or every pane projects a device terminal, live or pending restore), so state sync v2 never re-exports another Mac's workspace to the phone or to other Macs (no mirror-of-mirror chains, no phone duplicates). One `continue` line at the top of the per-workspace loop body |
| 519 | `Sources/TerminalController+MobileWorkspaceList.swift` | `device-mirror-export-filter` | The same loop guard for the legacy `mobile.workspace.list`: the all-windows branch `continue`s past device mirrors, and the single-window branch's whole-window listing (`} ?? tabManager.tabs`) filters them out (an explicit `workspace_id` lookup still resolves). The notification feed already excludes `.deviceMac` rows upstream (`TerminalController+MobileNotificationSync.swift`, `isMirroredFromDevice`), so no fence is needed there |
| 520 | `Sources/FeatureFlags.swift` | `supermux-release-devices-defaults` | Right after #514's fence in `CmuxFeatureFlags.init`, calls `SupermuxDevicesDefaults.seedReleaseDefaultsIfNeeded(isSupermuxRelease:defaults:)`, which for `com.supermux.app` seeds `cloud.beta.machines.enabled`, `devices.discovery.enabled` and `devices.incomingAccess.enabled` to `true` ONCE (marker `supermux.devices.releaseDefaultsSeeded.v1`), and only where no value is stored — a later user choice (on or off) is never overwritten. Direct writes skip upstream's discoverability consent sheet by design (DESIGN.md decision 11) |
| 521 | `Sources/TerminalController+ControlSocketAsync.swift` | `supermux-devices-socket` | In `processV2CommandUsingSocketExecutionPolicyAsync`, inside the `withSocketCommandPolicyAsync` body and before the native-browser-keys branch, routes every `supermux.devices.*` v2 method to `SupermuxDevicesSocketCommands.handle(method:params:)` (awaited on the async socket lane, encoded with `Self.v2Encoder.response`). Methods: `list`, `bindings`, `local_projects`, `open`, `create_workspace`, `await_open`, and DEBUG-only `request`/`bind`/`unbind` — E2E introspection of devices, records and local mirror bindings (`cmux rpc supermux.devices.list '{}'`) |
| 522 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 14 device-foundation files under `Sources/Supermux/Devices/` (`Devices/…` paths inside the Supermux group; ids `50BE00040000000000000001`–`…001C`, odd = file reference, even = build file) into the cmux target: `SupermuxDevice`, `SupermuxDeviceEvent`, `SupermuxDeviceError`, `SupermuxDevices` (+`+Events`, `+RPC`), `SupermuxDeviceLinkEvents`, `SupermuxRemoteWorkspaceRef+Surface`, `SupermuxDeviceWorkspaceIndex`, `SupermuxDeviceWorkspaceOpener`, `SupermuxComposition+Devices`, `SupermuxDevicesDefaults`, `SupermuxDevicesSocketPayloads`, `SupermuxDevicesSocketCommands` |
| 525 | `Sources/Devices/DeviceLinkRuntime.swift` | `loopback-device-runtime` | **DEBUG-only.** Appends `#if DEBUG extension DeviceLinkRuntime { func supermuxReplacingTransportFactory(_:) }`, which returns a copy of the runtime whose `transportFactory` is the given factory and whose `independentEventByteStreamProvider` is nil. It has to live in this file because `transportFactory` is `private(set)`. The DEBUG loopback device harness (`Sources/Supermux/Devices/SupermuxDeviceLoopbackHarness.swift`) uses it to plug an in-process byte pipe into a real `DeviceLink`, so one tagged build acts as both the viewer Mac and the host Mac (`plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md`). Release builds compile none of it |
| 526 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the six DEBUG loopback-harness files in `Sources/Supermux/Devices/` into the cmux target. Each file gets the usual four entries: `PBXFileReference` with `path = Devices/<name>` inside the `Supermux` group, `PBXBuildFile`, a `Supermux` group child, and a line in the cmux target's Sources phase. The files are `SupermuxDeviceLoopbackPipe`, `…Transport`, `…TransportFactory`, `…HostAcceptor`, `…Identity` and `…Harness` (`.swift`). File refs are `50BE0008000000000000000{1,3,5,7,9,B}` and build files are `…{2,4,6,8,A,C}`, in that order. `grep -c 50BE0008 cmux.xcodeproj/project.pbxproj` prints 24. The code is `#if DEBUG`, so these compile to nothing in Release |
| 530 | `Sources/TabManager.swift` | `device-mirror-close` | Device-mirror close semantics (plans/supermux-remote-workspaces, workstream Ma; a mirror closes like a local workspace since round 4). Two fenced sites calling `SupermuxDeviceMirrorCloseGate` (`Sources/Supermux/Devices/SupermuxDeviceMirrorCloser.swift`): (1) in `closeWorkspace(_:recordHistory:allowEmptyingWindow:)`, right after the `guard tabs.contains` line, `SupermuxDeviceMirrorCloseGate.workspaceWillClose(workspace, recordHistory: recordHistory)` — a programmatic close (`recordHistory` true: socket, AppleScript) of a mirror hides its remote workspace ("Hide Here"), every close drops the mirror's binding, window close / app quit / restore never reach it or are ignored; (2) in `closeWorkspaceIfRunningProcess`, right after upstream's `if showsCloseConfirmation, !confirmClose(…) { return false }` and before the `keep-window-on-last-close` close, `if SupermuxDeviceMirrorCloseGate.closeOnItsMac(workspace, in: self) { return true }` — every user close of a mirror (sidebar ×, context menu Close / Close Others / Below / Above, ⌘⇧W, last-tab close, Ghostty close action, each member of a multi-close) meets only upstream's pinned / running-process / settings / batch "Close workspaces?" confirmations, then closes the mirror here and sends `workspace.close {force: true}` to its Mac (pending while that Mac is offline) |
| 531 | `Sources/Devices/DeviceWorkspaceLayoutCoordinator.swift` | `device-layout-non-terminal-panels` | Layout-sync stall fix: in `reconcile()`, `sourceIDs` excludes the surfaces `SupermuxDeviceLayoutSurfaceFilter.nonTerminalSurfaceIDs` reports (record `surfaces` kind ≠ terminal, or a catalog `.browser` resource), and a `supermuxTerminalLayout = snapshot.layout.removingSurfaceIDs(…)` replaces `snapshot.layout` for `layoutLocations` and `remappingSurfaceIDs`. Upstream mapped every layout surface to a `.terminal` resource and `continue`d forever on a remote workspace holding a browser/markdown panel. Three fenced sites; ids without positive non-terminal evidence stay (upstream's wait-for-metadata behavior). Viewer→host writes for such workspaces remain upstream's no-op (id-set mismatch) |
| 532 | `Sources/SidebarWorkspaceSnapshotFactory.swift` | `device-mirror-flatrow-status` | Flat-row branch/PR for device mirrors (git never probes mirror panes): the inline branch summary falls back to `SupermuxDeviceMirrorSidebar.branch(for:)`, the vertical `if let cloud` branch line uses it instead of `nil` (when `showsGitBranch`), and `pullRequestRows` appends `SupermuxDeviceMirrorSidebar.pullRequestDisplays(for:)`. Values come from the remote record via `SupermuxDeviceStatusProjector`; empty for local workspaces. The directory line of a mirror (the inline `compactDirectoryCandidates` and the vertical `if let cloud` line) comes from `SupermuxDeviceMirrorSidebar.directoryCandidates(for:orderedPanelIds:usesLastSegmentPath:)` — the panes' remote directories without upstream's "<Mac> · " prefix, which the row's Mac icon names in its tooltip (remote paths are never abbreviated with this Mac's home); nil for non-mirrors, so upstream's `cloud?.directoryCandidates` still serves every other workspace |
| 533 | `Sources/ContentView.swift` | `device-mirror-flatrow-refresh` | After `.sidebarWorkspaceObservations(…)` in the sidebar scroll area, `.onReceive(SupermuxWorkspaceLifecycleRelay.lifecycleDidChange) { … scheduleWorkspaceSnapshotRefresh(workspaceId:) }` (guarded by `isPresented` and the window's workspace ids). A mirror's activity/branch/PR are fork overlays with no workspace publisher; the projector announces their changes on this relay, so the flat row's snapshot cache refreshes |
| 534 | `Sources/ContentView.swift` | `device-mirror-unhide-palette` | Two lines beside the `claude-harness-palette-contribution` fences: `contributions.append(.supermuxUnhideRemoteWorkspaces)` and `registry.registerSupermuxDeviceMirrorCommands()` — the "Show Hidden Remote Workspaces" palette command (`Sources/Supermux/Devices/SupermuxDeviceMirrorPalette.swift`) that unhides every "Hide Here" workspace |
| 535 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileStateSyncRecords.swift` | `supermux-mobile-workspace-fields` | Inside the existing fences (#139/#271): additive `supermux_status_entries` (`[SupermuxStatusEntry{key,value,icon?,color?,priority?}]`), `supermux_progress` (`{value,label?}`) and `supermux_log` (`{message,level?}`) on `WorkspaceSyncRecord` — nested types, stored properties, defaulted init params, lenient decoding (malformed → nil), CodingKeys. Mac-to-Mac mirrors render them; the phone ignores them |
| 536 | `Sources/Mobile/MobileStateSync.swift` | `supermux-mobile-workspace-fields` | Inside the existing `workspaceRow` fence (#140/#272): fills `supermuxStatusEntries/Progress/Log` from `SupermuxMobileWorkspaceStatusFields` (the host row's pills minus the agent-lifecycle pills its indicator duplicates, progress, latest log; bounded), and falls back to `SupermuxMobileWorkspaceStatusFields.branch/pullRequest` for workspaces no project owns (the augmenter is association-gated; the phone reads branch/PR only on project rows, so its UI is unchanged). Freshness: `SupermuxMobileSidebarStatusObserver` pokes the v2 host on sidebar-metadata changes |
| 537 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 14 workstream-Ma files into the cmux target (four entries each: `PBXFileReference` inside the `Supermux` group, `PBXBuildFile`, group child, Sources phase), right after the loopback harness entries. File refs `50BE0005000000000000000{1,3,…}` odd, build files even, in this order: `Devices/SupermuxDeviceMirrorStatus`, `Devices/SupermuxMobileWorkspaceStatusFields`, `SupermuxMobileSidebarStatusObserver`, `Devices/SupermuxDeviceStatusProjector`, `Devices/SupermuxDeviceMirrorStatusWriter`, `Devices/SupermuxDeviceMirrorCoordinator`, `Devices/SupermuxDeviceMirrorWindowPicker`, `Devices/SupermuxDeviceMirrorCloser`, `Devices/SupermuxComposition+DeviceMirrors`, `Devices/SupermuxDeviceMirrorSidebar`, `Devices/SupermuxDeviceLayoutSurfaceFilter`, `Devices/SupermuxDeviceMirrorPalette`, `Devices/SupermuxDeviceMirrorSocketCommands`, `Devices/SupermuxDevicesSocketPayloads+MirrorStatus` (`.swift`; paths with `+` quoted). `grep -c 50BE0005 cmux.xcodeproj/project.pbxproj` prints 56 (`…11/12`, `Devices/SupermuxDeviceMirrorClosePrompt`, were removed when mirrors started closing like local workspaces) |
| 538 | `Sources/GhosttyTerminalView.swift` | `backdrop-cutout-after-first-frame` | **Upstream bug fix: terminals that stay blank when shown.** `GhosttySurfaceScrollView.synchronizeSharedBackdropCutout(visible:)` returns before building upstream's Core Image shared-backdrop cutout (the pane-local OSC 11 fill) while the pane is detached (`window == nil`) or its surface has not presented a frame (`TerminalSurface.hasPresentedFrame`). A cutout built then leaves the whole terminal blank once the pane is shown (the buffer holds the text, the window draws only the fill): every auto-mirror opened in the background, every mirror restored at launch (the other Mac's replay carries its OSC 11 colors), and any background local terminal that sets OSC 11. The next fill change builds the cutout as upstream does. Retire when upstream replaces the cutout (open PR #9103, persistent root backdrop) or fixes early creation. Since #651 a mirror's replay no longer carries the other Mac's colors, so a mirror reaches the cutout only when a program there sets a background. E2E: `tests/supermux/loopback_mirror_render_e2e.py` |
| 545 | `Sources/TerminalNotificationStore.swift` | `device-mac-phone-forward` | Remote Macs, notification parity (workstream Mb; DESIGN.md decision 8: the Mac that runs the agent pushes). Four small fenced sites, all calling `Sources/Supermux/SupermuxPhoneForwardGate.swift`: (1) first line of `emitNotificationsDismissed(ids:)` shadows `ids` with `SupermuxPhoneForwardGate.phoneFacingDismissIDs(ids, in: notifications)` (dismissals of records mirrored from another Mac never reach a phone that never got them from this Mac); (2) in the same method `let unreadCount = indexes.unreadCount` becomes `supermuxPhoneBadgeCount`; (3) `emitUnreadBadgeEventIfChanged` uses `supermuxPhoneBadgeCount`; (4) in `deliverNotificationSideEffects`, upstream's `if shouldAttemptPhone { PhonePushClient.shared.forward(notification, badgeCount: indexes.unreadCount) }` becomes `let supermuxRelayAttempted = shouldAttemptPhone && SupermuxPhoneForwardGate.allowsUpstreamRelay(for: notification)` plus the same forward with `badgeCount: supermuxPhoneBadgeCount`. `supermuxPhoneBadgeCount` (store extension in the gate file) is the unread count minus unread `.deviceMac` records: THIS Mac's share of the phone badge. Every Mac sends only its own share, and the phone badges the total over every Mac (`SupermuxPhoneBadgeLedger`, #554–#557); do not put mirrored records back into this count, or the phone counts them once per Mac. Local banner, sound, sidebar and Dock handling of `.deviceMac` records is untouched |
| 546 | `Sources/TerminalNotificationStore.swift` | `direct-phone-push` | Changes the body of #332's visible-forward fence: after computing `focusedPaneAlreadyVisible` (the #452 policy with `exactPaneFocused: isFocusedSurfaceArrival`, never `shouldSuppressExternalDelivery`) it calls `SupermuxComposition.directPhonePush.deliver(notification:focusedPaneAlreadyVisible:upstreamRelayAttempted: supermuxRelayAttempted, badgeCount: supermuxPhoneBadgeCount)` instead of `forward` behind `configuration().forwardingEnabled`. `deliver` (fork `SupermuxDirectPhonePush`) skips `.deviceMac` records, applies upstream's `PhonePushClient.currentAdmission()` (enabled plus `onlyWhenAway`, which the direct lane used to ignore), records the DEBUG decision log (`supermux.devices.push_decisions`), and stamps `macInstanceTag` (`MobileHostIdentity.instanceTag()`) into the payload so iPhone tap routing matches rows tagged `default`. The dismiss fence is unchanged (it now receives the #545 phone badge); the fork's `SupermuxDirectPhonePush.forwardDismissed` stamps `macDeviceId`/`macInstanceTag` and `SupermuxPhonePushService` sends every notify push with `mutable-content` and the dismiss push with an empty alert plus `mutable-content`, so the phone's extension sees each one and can total the badge per Mac |
| 547 | `Sources/TerminalController+MobileNotificationSync.swift` | `device-mac-phone-badge` | In `v2MobileNotificationReconcile`, `"unread_count": store.unreadNotificationCount` becomes `store.supermuxPhoneBadgeCount` (#545): this Mac's own share, which the phone files under this Mac and adds to every other Mac's share (#554–#557) |
| 548 | `Sources/Devices/DeviceSurfaceProvider+Notifications.swift` | `device-notification-parity` | Two fences. (1) In `installNotificationSync`, the `CloudNotificationSync` `deliver:` closure calls `SupermuxDeviceNotificationDelivery.deliver(row, to: target, via: self)`, which calls upstream's unchanged `deliverNotification(_:to:)` and then: remembers the row's remote project (#549) under its correlation key before the record is built; turns `.delivered` into `.suppressed` when the store created the record already read (a focused mirror pane seen by a present user), so the sync acknowledges it to the host with `notification.feed.mark_read`; and schedules `SupermuxDeviceNotificationRetry` (1.2 s refold, 12 attempts without progress) for `.declined` rate-limited rows. (2) In `fetchNotificationFeed`, right after `notificationSync.apply(rows:)`, `SupermuxDeviceNotificationReadMirror.mirrorHostReads(of: self)` marks local copies read when the host's row TURNED read since that machine's previous feed (read, cleared or superseded there); a row that was already read is left alone, so a local Mark as Unread survives the host's next feed. No echo: the resulting local read is skipped by `CloudNotificationSyncReducer.recordRead` because the row is already read by `mac` |
| 549 | `Sources/Devices/DeviceNotificationFeed.swift` | `device-notification-project` | Keeps the feed's `supermux_project`, which upstream dropped: a fenced `import SupermuxMobileCore`, a `var supermuxProjects: [String: SupermuxNotificationProject] = [:]` property (row id to project) and, as the last line of `init(response:)`, `supermuxProjects = SupermuxDeviceNotificationProjects.projects(inFeedResponse: response)` |
| 550 | `Sources/TerminalNotificationStore.swift` | `notification-project-identity` | Inside the #354 `applyNotification` construction-site fence, `SupermuxNotificationProjectBridge.project(forWorkspace: request.tabId)` becomes `SupermuxNotificationProjectBridge.project(for: request)`: a `.deviceMac` record takes the other Mac's project remembered by #548 (never a local-path guess on the mirror pane); every other origin resolves exactly as before |
| 551 | `Sources/TerminalController.swift` | `mobile-supermux-dispatch` | Inside the #91 fence, the call passes the caller's trust context: `v2MobileSupermuxDispatch(method:params:executionContext: executionContext)`. Only `mobile.supermux.phone_push.share` reads it: accepted only from `.irohAdmission` peers whose `platform == .mac`; phones, platform-less peers, the Stack-bearer path and in-process callers are refused |
| 552 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 11 notification and push parity files into the cmux target (four entries each; file refs `50BE0009…01` to `…15` odd, build files `…02` to `…16` even, in this order): `SupermuxMacPresence`, `SupermuxPhoneForwardGate`, `SupermuxPhonePushDecisionLog`, `SupermuxMobileHost+PhonePushShare` (Supermux group root) and `Devices/SupermuxDeviceNotificationProjects`, `…Delivery`, `…ReadMirror`, `…Retry`, `Devices/SupermuxPhonePushShareCoordinator`, `Devices/SupermuxComposition+DeviceNotifications`, `Devices/SupermuxDeviceNotificationSocketCommands`. `grep -c 50BE0009 cmux.xcodeproj/project.pbxproj` prints 44 |
| 553 | `docs/notifications.md` | `focused-pane-notification-suppression-doc` | Inside the #458 fence, two paragraphs: focused-pane suppression applies only while someone is at the Mac (locked, display asleep or two minutes without input keeps the notification unread and pushes it), and notifications from other Macs keep the remote project, are never forwarded to the phone by the viewing Mac, and read on both Macs together |
| 554 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SupermuxPhoneBadge.swift` | `supermux-phone-badge-total` | Whole new file (fenced top to bottom). `supermuxPhoneBadgeTotal(foregroundCount:)` files the foreground build's own unread count under `foregroundMacDeviceID` + `activeMacInstanceTag` in `SupermuxPhoneBadgeLedger` (SupermuxMobileCore; one slot per Mac build a Release phone can pair with) and returns the total over every build; `supermuxForgetPhoneBadge(macDeviceID:instanceTag:)` drops a forgotten build's count and re-applies the badge. Without a foreground Mac identity or the shared app group (a build signed without it, or any non-iOS host such as `swift test`) both pass the Mac's own count through, as before |
| 555 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+NotificationDismissSync.swift` | `supermux-phone-badge-total` | First line of `applyAuthoritativeUnreadBadge(_:)` shadows `count` with `supermuxPhoneBadgeTotal(foregroundCount: count)` (#554). Every caller (`notification.reconcile`, the `notification.badge` and `notification.dismissed` events) hands it the FOREGROUND Mac's own count, so the badge the app sets becomes the total over every Mac instead of whichever Mac spoke last |
| 556 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+HiddenMacs.swift` | `supermux-phone-badge-total` | In `forgetHiddenComputer(_:)`, first statement of the `if deletion.cleaned {` success branch: `supermuxForgetPhoneBadge(macDeviceID: computer.macDeviceID, instanceTag: computer.instanceTag)` (#554), so a forgotten build's unread count cannot hold the badge up forever |
| 557 | `ios/cmux-ios.xcodeproj/project.pbxproj` | `unfenced` | Compiles `Packages/Shared/SupermuxMobileCore/Sources/SupermuxMobileCore/SupermuxPhoneBadgeLedger.swift` straight into upstream's `NotificationService` target (file ref `50BE000E0000000000000001`, `sourceTree = SOURCE_ROOT`, `path = ../Packages/Shared/…/SupermuxPhoneBadgeLedger.swift`, listed in the `SupermuxNotificationService` group; build file `50BE000E0000000000000002` in `NotificationService Sources`). One source file in two modules instead of a re-declared copy: the extension links no package graph (#383), and the app (via SupermuxMobileCore) and the extension must run the identical per-Mac ledger |
| 560 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Projects across Macs (P1, `plans/supermux-remote-workspaces/PROJECTS-API.md`): wires the 14 files under `Sources/Supermux/Projects/` (`Projects/…` paths inside the Supermux group) into the cmux target — `SupermuxDeviceProjects`, `SupermuxRemoteProjectsModel`, `SupermuxUnifiedProjectsModel`, `SupermuxMirrorOwnership`, `SupermuxMirrorRowSnapshot`, `SupermuxRemoteProjectCommands`, `SupermuxRemoteProjectActionsFactory`, `SupermuxRemoteProjectsPresenter`, `SupermuxMobileHost+ProjectSetup`, `SupermuxProjectSyncCoordinator`, `SupermuxComposition+Projects`, `SupermuxProjectsSocketPayloads`, `SupermuxProjectsSocketCommands`, `SupermuxFlatRowDeviceChip` (`.swift`), in that order. File refs are `50BE0006000000000000000{1,3,…}` (odd, `…01`–`…1B`) and build files the next even id (`…02`–`…1C`). `grep -c 50BE0006 cmux.xcodeproj/project.pbxproj` prints 56 |
| 561 | `Sources/ContentView.swift` | `sidebar-flatrow-device-chip` | Four fences in `TabItemView`. (1) In the title-line `HStack`, upstream's `SidebarCloudWorkspaceBadgeView(label: detailVisibility.showsBranchDirectory ? … : nil, …)` (before the title) gains `&& workspaceSnapshot.deviceWorkspaceLabel == nil` in its label condition (device mirrors no longer show the icon-only badge), followed by the title-line fallback `if let deviceWorkspaceLabel = workspaceSnapshot.deviceWorkspaceLabel, !SupermuxFlatRowDeviceChip.drawsOnBranchLine(workspaceSnapshot, settings: settings) { SupermuxFlatRowDeviceChip(deviceWorkspaceLabel:pointSize:tint:) }` (the badge's 10·scale magnified size and `activeSecondaryColor(0.7)`). (2)–(4) The first child of each branch/directory-line `HStack` (vertical, stacked-compact and inline layouts, right before upstream's optional `arrow.triangle.branch` glyph): `if let deviceWorkspaceLabel = workspaceSnapshot.deviceWorkspaceLabel { SupermuxFlatRowDeviceChip(…, pointSize: GlobalFontMagnification.scaledSize(scaledFontSize(9), percent: globalFontMagnificationPercent), tint: activeSecondaryColor(0.6)) }`. So a flat row that mirrors another Mac's workspace always shows the small Mac + cloud icon (`SupermuxRemoteMacIcon`, the Mac's name in its tooltip) immediately before its branch, or before the title when the row draws no branch/directory line (detail hidden, compact agent status); `drawsOnBranchLine` mirrors the row's own branch-line conditions. Uses only existing snapshot fields (no new `Snapshot` field, so #49/#128 are untouched); the icon recovers the Mac name from upstream's "Workspace on %@" label with the same localized format |
| 570 | `Sources/AppDelegate+NewWorkspaceContextMenu.swift` | `device-new-workspace-menu` | Remote Macs as first-class workspaces, workstream W. `makeNewWorkspaceContextMenu` returns `SupermuxNewWorkspaceDeviceMenu.appending(to: renderNewWorkspaceContextMenu(…), windowId: context.windowId, devices: SupermuxComposition.devices)` instead of upstream's bare `renderNewWorkspaceContextMenu(…)`: every `+` menu entry point (titlebar split button, minimal-mode sidebar controls, update titlebar accessory) gains a "New Workspace on ▸ <Mac>" submenu: This Mac first (a local workspace even while a mirror is selected, #591), then one row per known Mac, offline Macs disabled with an "Offline"/"Connecting…" badge; the row a plain `+` would use right now is checked (This Mac whenever a device mirror is selected, #571). A Mac row creates a global workspace on that Mac through `SupermuxDeviceWorkspaceOpener.createWorkspace` into the clicking window (`Sources/Supermux/Mirrors/SupermuxNewWorkspaceDeviceMenu.swift`, `SupermuxDeviceNewWorkspaceAction.swift`). With no known Mac the menu is returned unchanged. Lives next to #510's fence in the same file |
| 571 | `Sources/AppDelegate.swift` | `device-new-workspace-opener` | In `performNewWorkspaceAction`, inside upstream's `deviceMachineForNewWorkspace` branch and before its `deviceWorkspaceCreationCoordinator?.start(on:in:)`, `if SupermuxComposition.deviceNewWorkspace.handles(machine) { return performNewWorkspaceCreationAction(initialSurface: .terminal, preferredTabManager: manager, event: event, placementOverride: placementOverride, debugSource: debugSource) }`: with a device mirror (or any workspace upstream routes to a Mac the fork's device facade knows) selected, `+`, ⌘N, File > New Workspace and Ghostty's new-tab action create on THIS Mac exactly like the plain path below (configured `ui.newWorkspace.action`, placement), as on origin/main before device mirrors existed. A selected mirror is context, not a target: creating on another Mac is the explicit "New Workspace on ▸ <Mac>" choice (#570, #622). Upstream's own device routing (commit 0222ededd73) never runs for those Macs; a machine the fork does not know still falls through to upstream's coordinator, and remote-tmux and Cloud VM routing are untouched |
| 572 | `Sources/FileExplorerWorkspaceRootResolver.swift` | `mirror-file-explorer-hint` | At the top of `resolve(_:)`'s `usesRemoteDirectoryProvenance` branch, `if let mirrorRoot = SupermuxMirrorFileExplorerRoot.root(for: workspace) { return mirrorRoot }`: a device mirror's Files root. When its Mac serves `supermux.files_read.v1` this is `.supermuxDevice` (#675: the other Mac's folder over the device link, with the fork's file operations); otherwise the unavailable root naming the Mac (`displayTarget` = Mac name; detail: not connected, loading, "Update Supermux on <Mac> to browse its files here.", or no folder reported yet) instead of an anonymous "Remote files unavailable" |
| 573 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 18 workstream-W files into the cmux target (19 originally; `SupermuxMirrorRemoteState` — ids `…05`/`…06` — was folded into P1's `SupermuxRemoteProjectsModel` by workstream X and removed): 17 under `Sources/Supermux/Mirrors/` (`Mirrors/…` paths inside the `Supermux` group: `SupermuxMirrorTarget`, `…Resolver`, `…RunController`, `…Alerts`, `…PresetLauncher`, `…ProjectActions`, `SupermuxDeviceChangesTransport`, `SupermuxMirrorChangesSource`, `…ChangesPanel`, `…ChangesPanels`, `SupermuxComposition+Mirrors`, `SupermuxDeviceNewWorkspaceAction`, `SupermuxNewWorkspaceDeviceMenu`, `SupermuxMirrorFileExplorerRoot`, `SupermuxMirrorSocketCommands`, `SupermuxMirrorLocalPathActions`, `SupermuxMirrorChangesSocket`) plus `SupermuxMobileHost+RunWorkspace.swift` in the `Supermux` group root. Ids `50BE000A0000000000000001`–`…0026` (odd = file reference, even = build file, in that order); `grep -c 50BE000A cmux.xcodeproj/project.pbxproj` prints 72 |
| 574 | `Sources/TabItemView+WorkspaceContextMenu.swift` | `device-mirror-row-menu` | Sidebar polish (A3): right after upstream's Close Workspace item(s), `if !isMulti, workspaceSnapshot.deviceWorkspaceLabel != nil { SupermuxMirrorRowMenuItems(workspaceId: workspaceId) }`: a flat device-mirror row's menu gains **Hide Here** (the closer's `hideHere(workspaceID:)`, no prompt), the item the nested project rows offer too (`Sources/Supermux/Mirrors/SupermuxMirrorRowMenuItems.swift`). Upstream's Close Workspace above it closes a mirror on its Mac (#530), so there is no "Close on <Mac>…" item. Upstream's disabled Show in Finder is untouched |
| 575 | `Sources/ContentView.swift` | `sidebar-footer-clearance` | Sidebar polish (A3): upstream draws the sidebar footer (account, usage, help, Upgrade; plus the DEBUG dev-build line) over the bottom of the scrolling workspace list, whose own bottom fade is shorter than the footer, so rows scrolled on under it and their text collided with the buttons (not caused by the fork's Projects-section height fences; mirrors just make the list overflow sooner). Three fences in `VerticalTabsSidebar`: an `@State supermuxSidebarFooterHeight` after the #2 `sidebar-projects-empty-area` state; `.supermuxReportsSidebarFooterHeight($supermuxSidebarFooterHeight)` on the `SidebarFooter` in the body's `ZStack(alignment: .bottomLeading)`; and `.supermuxClearsSidebarFooter(height: isPresented ? supermuxSidebarFooterHeight : 0)` on the `workspaceScrollArea(renderContext:)` branch of that `ZStack` — the list is masked out behind the footer and fades in over 12pt above it (`Packages/SupermuxKit/…/UI/SupermuxSidebarFooterClearance.swift`), keeping the sidebar's own backdrop behind the footer |
| 576 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the sidebar-polish (A3) files into the cmux target, four entries each: `Projects/SupermuxNestedWorkspaceRows.swift` (the Projects mount's row builder, shared with the `supermux.devices.sidebar_rows` socket method; file ref `50BE00130000000000000001`, build file `…02`) and `Mirrors/SupermuxMirrorRowMenuItems.swift` (#574; `…03` / `…04`), in the `Supermux` group's `Projects/` and `Mirrors/` paths; `grep -c 50BE0013 cmux.xcodeproj/project.pbxproj` prints 8 |
| 577 | `Sources/TabManager.swift` | `device-mirror-no-cwd-inherit` | First statement after the `guard let workspace` in `preferredWorkingDirectoryForNewTab(workspace:)`: `if SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) { return nil }`. A device mirror's directory is a path on the other Mac, so a local workspace created while a mirror is selected (This Mac in New Workspace on ▸, socket `workspace.create` without `working_directory`, detached creation) falls back to the normal default (the Ghostty working directory, or home with `app.workspaceInheritWorkingDirectory` off, #80) instead of inheriting it. Every new-workspace inheritance path reads this helper (`addWorkspaceIfActive`, `workspaceCreationSnapshot`, `implicitWorkingDirectoryForNewWorkspace`) |
| 580 | `Packages/iOS/CmuxMobileShell/Package.swift` | `supermux-mobile-mac-seams` | Two fences: the package + target dependency on the fork's `SupermuxMobileKit`, which defines the `SupermuxMacSeam` value type the shell publishes (#581). No cycle: `SupermuxMobileKit` depends only on `SupermuxMobileCore`, `CMUXMobileCore` and `CmuxMobileRPC` |
| 581 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+SupermuxMacSeams.swift` | `supermux-mobile-mac-seams` | Whole new file (fenced top to bottom). Public `supermuxConnectionSeams: [SupermuxMacSeam]` — one seam per live Mac pairing: the foreground (`remoteClient` + `supportedHostCapabilities`, only while `.connected`, exactly like #96) plus every control subscription (`client` + `supportedHostCapabilities`), with pairing id, display name, color slot, custom color, status (from `workspacesByMac`) and `isForeground`; mirrors `captureTaskModelRequestContext`. Also public `supermuxConnectionSeam(forMacDeviceID:instanceTag:)`, the owning Mac's `(client, capabilities)` for a workspace row (exact pairing, else the only seam on that device whose tag or the row's is missing — a legacy untagged pairing; never a sibling build with a different explicit tag, whose workspace and pane ids mean nothing to the row's build; unowned rows → foreground). Pinned by #587. The #96 single seam is unchanged |
| 582 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView+SupermuxMacSeams.swift` | `supermux-mobile-mac-seams` | Whole new file. `supermuxResolveWorkspace`, a `SupermuxWorkspaceResolver` over upstream's public `store.workspaceID(matchingRemoteWorkspaceID:macDeviceID:instanceTag:)`, so the Projects section maps the Mac-local ids Supermux RPCs answer with to the owning Mac's (scoped) row id. A property, not an inline closure, because `WorkspaceListView.body` is at the type checker's limit |
| 583 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift` | `supermux-mobile-projects-section` | Inside #97's two driver fences (iOS `workspaceTable` arm and macOS `List` arm): the driver call is `.supermuxProjectsSectionDriver(model: supermuxProjects, seams: store?.supermuxConnectionSeams ?? [], workspaces: workspaces, selectedWorkspaceID: selectedWorkspaceID, selectWorkspace: { selectWorkspace($0) }, resolveWorkspace: supermuxResolveWorkspace, closeWorkspace: supermuxRequestWorkspaceClose)` — every Mac's seam (#581) instead of the #96 foreground seam, plus the #582 resolver. `selectedWorkspaceID` (the list's own upstream `let`) lets a selection made outside the Projects section (flat list, notification, search) drop a navigation still parked for a slow create, so the late row never yanks the user back. The #103 hide filter needs no edit: `supermuxShownProjectIDs` reads `snapshot.rows.map(\.id)`, which are now per-Mac row keys, and `supermuxFlatRows(hidingProjectIDs:)` matches `(pairing, supermux_project_id)` |
| 584 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+SupermuxMacSeam.swift` | `supermux-mobile-workspace-mac-seam` | Whole new file. `WorkspaceDetailView.supermuxWorkspaceSeam`: `store.supermuxConnectionSeam(forMacDeviceID: workspace.macDeviceID, instanceTag: workspace.macInstanceTag)` (#581), so the workspace tools, title-menu entries and pane actions talk to the Mac that owns the workspace — before (and without) `openWorkspace`'s asynchronous foreground switch |
| 585 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` | `supermux-mobile-workspace-tools, ios-workspace-toolbar-persistent-actions` | Four reads inside existing fences swap `store.supermuxConnectionSeam` for `supermuxWorkspaceSeam` (#584): the #108 `.supermuxWorkspaceTools(connection:)` argument, and the #228 `SupermuxWorkspaceToolsMenuEntries(hostCapabilities:)`, `workspaceTitleToolEntriesFingerprint` and `isEnabled` capability reads |
| 586 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView+SupermuxPaneActions.swift` | `ios-pane-actions` | `supermuxPaneActions` builds `SupermuxWorkspacePaneActions(connection: supermuxWorkspaceSeam)` (#584) instead of the foreground seam, so Close Pane / New Simulator target the workspace's own Mac |
| 587 | `Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxMacSeamResolutionTests.swift` | `supermux-mobile-mac-seams` | **Whole-file fork test inside an upstream package.** Pins #581's row → seam resolution: a Stable row whose link is down never borrows a live Nightly seam on the same physical Mac (explicit tags differ), while a legacy untagged pairing still serves its tagged rows. Uses upstream's shared `makeRoutingConnectedStore` / `installSecondaryClient` test builders |
| 590 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Device picker in the New Worktree sheet (workstream P2, `plans/supermux-remote-workspaces/PROJECTS-API.md` § New Worktree on any Mac): wires the 2 files under `Sources/Supermux/Projects/` (`Projects/…` paths inside the Supermux group) into the cmux target — `SupermuxRemoteWorktreeCreationTarget`, `SupermuxNewWorktreeSocketCommands` (`.swift`), in that order. File refs are `50BE000B0000000000000001` / `…03`, build files `…02` / `…04`; `grep -c 50BE000B cmux.xcodeproj/project.pbxproj` prints 8. P2 needed nothing else (everything else is fork-owned); #591–#593 went to the New Workspace target polish |
| 591 | `Sources/AppDelegate.swift` | `device-new-workspace-this-mac` | Right after `performNewWorkspaceAction(…)`, a new internal method `supermuxPerformLocalNewWorkspaceAction(tabManager:placementOverride:)` (`placementOverride: WorkspacePlacement? = nil`) that calls upstream's private `performNewWorkspaceCreationAction(initialSurface: .terminal, preferredTabManager: tabManager, event: nil, placementOverride: placementOverride, debugSource: "supermux.newWorkspace.thisMac")`: the plain local New Workspace (configured `ui.newWorkspace.action`, group placement and all), skipping `performNewWorkspaceAction`'s routing to the selected workspace's Mac or VM. Only "New Workspace on ▸ This Mac" calls it: the `+` menu's row (`SupermuxNewWorkspaceDeviceMenuTarget`, no override) and the sidebar empty area's row (`SupermuxEmptyAreaNewWorkspaceMenu`, `.end`, #622) while a plain New Workspace targets a Cloud VM or a Mac only upstream handles. So a local workspace can be made while such a workspace is selected (with a device mirror selected a plain `+` / ⌘N is local anyway, #571) |
| 592 | `Sources/Update/TitlebarNewWorkspaceSplitButton.swift` | `new-workspace-target-help` | On the primary `+` segment, upstream's `.safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))` becomes `.supermuxNewWorkspaceButtonHelp(<the same string>)` (`Sources/Supermux/Mirrors/SupermuxNewWorkspaceButtonHelp.swift`): the same tooltip, or "New Workspace on <Mac> (⌘N)" while the window's selected workspace makes `+` create on another Mac (`SupermuxNewWorkspaceTarget`, which follows `performNewWorkspaceAction`'s routing). **Inert since #571 keeps `+` / ⌘N on this Mac for device mirrors:** the target never names another Mac, so the tooltip is always upstream's (a retire candidate together with `SupermuxNewWorkspaceButtonHelp.swift` and its #593 entries) |
| 593 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 3 polish files into the cmux target: `Sources/Supermux/Mirrors/SupermuxNewWorkspaceTarget.swift`, `Mirrors/SupermuxNewWorkspaceButtonHelp.swift` (#591/#592) and `Devices/SupermuxRestoredMirrorNotifications.swift` (#594), `Mirrors/…` / `Devices/…` paths inside the Supermux group. File refs `50BE00140000000000000001` / `…03` / `…05`, build files `…02` / `…04` / `…06`; `grep -c 50BE0014 cmux.xcodeproj/project.pbxproj` prints 12 |
| 594 | `Sources/Devices/DeviceSurfaceProvider.swift` | `device-restored-pane-notifications` | In `reconnectRestoredPanes`, between `catalog.replaceProjection(projection, withPanel: created.panelID, …)` and `SurfacePaneFactory.close(panelID: projection.panelID, …)`: `SupermuxRestoredMirrorNotifications.carry(fromPanel: projection.panelID, toPanel: created.panelID, inWorkspace: projection.workspaceID)`. Closing the restored placeholder pane cleared its notifications, which the device sync then acknowledged to the owning Mac as read, so a relaunch dropped every mirrored notification (and a Mark as Unread) and read it on the other Mac; they now move to the live pane with their read state, and get back the `.deviceMac` origin session restore does not keep (from the correlation key), so the viewer never counts them as its own or forwards them to the phone |
| 595 | `Sources/Devices/DeviceWorkspaceLayoutHost.swift` | `device-layout-tab-changes` | Remote Macs, workstream X: the owning Mac announces BACKGROUND tab changes to mirrors. Upstream re-captured a workspace's layout only on `.workspacePaneGeometryDidChange`, which a workspace posts only while on screen, so a tab added/closed/reordered in a workspace nobody is looking at (an agent's terminal, the phone's `mobile.terminal.create`, a preset, a CLI `new-surface`) never reached another Mac's mirror. Two fenced sites: (1) a `private lazy var supermuxTabChanges = SupermuxDeviceLayoutChangeObserver { [weak self] id in … _ = self.snapshot(for: id) }` after `receiptOrder`; (2) in `snapshot(for:)` upstream's first `guard let layout = capture(workspaceID), …` becomes `guard let layout = supermuxTabChanges.capture(workspaceID, { capture(workspaceID) }), …` (observation-tracked capture; the observer asks for a re-capture after any change to what it read, coalesced 40 ms per workspace; upstream's unchanged-arrangement check still decides whether to publish) |
| 596 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxRemoteMacsSettingsCard.swift` | `unfenced` | Whole fork-owned file inside the upstream `CmuxSettingsUI` package (the #143 precedent: the section stack has no app injection seam and the package cannot import `SupermuxKit`): the Settings "Remote Macs" card (auto-mirror / project sync / push-sharing toggles, discoverable + discovery status with Turn On through upstream's `ComputersSettingsActions`, known Macs with link state, Show Hidden Workspaces), plus its private Mac row view. Mounted inside the #18 `ai-settings` body fence in `AutomationSection.swift` |
| 597 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Environment/SupermuxRemoteMacsSettingsActions.swift` | `unfenced` | Whole fork-owned file in the upstream package: `SupermuxRemoteMacsSettingsActions` (the card's app services) and the `SupermuxRemoteMacsSettingsHosting` protocol the app's `HostSettingsActions` adopts in the fork file `Sources/Supermux/Devices/HostSettingsActions+SupermuxRemoteMacs.swift`; the card finds it with a dynamic cast, so upstream's `SettingsHostActions` gains no requirement |
| 598 | `Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Environment/SupermuxRemoteMacsSettingsSnapshot.swift` | `unfenced` | Whole fork-owned file in the upstream package: `SupermuxRemoteMacsSettingsSnapshot`, the value the Remote Macs card renders (built app-side by `SupermuxRemoteMacsSettingsFeed`) |
| 599 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the 4 workstream-X files under `Sources/Supermux/Devices/` into the cmux target (four entries each, `Devices/…` paths inside the `Supermux` group; the `+` path is quoted): `SupermuxDeviceLayoutChangeObserver`, `SupermuxRemoteMacsSettingsFeed`, `HostSettingsActions+SupermuxRemoteMacs`, `SupermuxRemoteMacsSocketCommands`. Ids `50BE000C0000000000000001`–`…0008` (odd = file reference, even = build file, in that order); `grep -c 50BE000C cmux.xcodeproj/project.pbxproj` prints 16 |
| 600 | `Sources/TerminalCopyAction.swift` | `claude-harness-builtin-action` | Adds a `.newClaudeHarness` arm returning `nil` to upstream's exhaustive `terminalCopyAction` switch (a harness pane is not a copy action). Added at the 2026-10-01 upstream merge, when upstream introduced the copy built-ins; part of the #433–442 family |
| 601 | `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/MobileDisplaySettings.swift` | `ios-notifications-tab-default` | Flips the absent-key default of upstream's `feedReplacesNotifications` from `true` to `false`, so the phone keeps the Notifications tab (where the fork's project-aware rows render, #365/#366) beside upstream's new agent Feed tab. An explicit choice under Settings → Legacy Notifications Tab still wins. Open decision recorded in SUPERMUX-UPGRADES.md (2026-10-01) |
| 620 | `Sources/AppDelegate.swift` | `sidebar-empty-area-local` | Wraps the body of `sidebarEmptyAreaUsesRemoteNewWorkspaceRouting(tabManager:)` (upstream's bare `selectedTab?.isRemoteTmuxMirror == true || selectedWorkspace?.deviceMachineForNewWorkspace != nil`, now with `return`) and puts `if SupermuxNewWorkspaceTarget.isForkDeviceWorkspace(tabManager.selectedWorkspace) { return false }` before it: a double-click on the sidebar's empty area (SwiftUI `SidebarEmptyArea` and the AppKit list's `createWorkspaceAtEndFromSidebar`, which share this helper) with a device mirror selected creates what origin/main did — `addWorkspaceIfActive(placementOverride: .end)`: a local workspace after every row, standalone at the root (#41), in the home / Ghostty-default directory (#80, #577); a configured `ui.newWorkspace.action` still applies with `.end` placement (through #571, local) |
| 621 | `Sources/TerminalController+WorkspaceCreate.swift` | `device-root-workspace-create` | In `v2MobileWorkspaceCreate`, right after `createParams["auto_refresh_metadata"] = false`: `SupermuxDeviceWorkspaceOpener.applyRootDirectoryRequest(to: &createParams)`. Another Mac's "New Workspace on ▸ <this Mac>" (`SupermuxDeviceWorkspaceOpener.createWorkspace` without a directory) sends the fork-only flag `supermux_root_directory: true`; with it and neither `working_directory` nor `cwd`, the helper sets `working_directory` to this Mac's home folder, so the workspace starts there instead of inheriting the directory of whatever this Mac has selected (usually a worktree). Every other create (the phone's, explicit directories, New Worktree) is untouched; a Mac without the fork ignores the flag and inherits as before. The viewer cannot send `~` itself: the mobile directory check accepts absolute paths only |
| 622 | `Sources/VerticalTabsSidebar+EmptyAreasAndFooter.swift` | `sidebar-empty-area-device-menu` | In `sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager:)`, after upstream's "New Empty Workspace Group" button: `SupermuxEmptyAreaNewWorkspaceMenu(tabManager: tabManager)`. Right-clicking the sidebar's empty area offers, below that item, a "New Workspace on ▸" submenu: This Mac (a local workspace after every row: what the double-click does, #620, while that creates here; while a Cloud VM workspace or one of a Mac only upstream handles is selected, #591 with `.end`, since the double-click follows those) then every known Mac, a Mac that is not connected disabled with "(Offline)" / "(Connecting…)" after its name; a Mac row creates a global workspace there, in that Mac's home folder (#621), and opens its mirror in this window (`SupermuxDeviceNewWorkspaceAction`). Renders nothing when no other Mac is known. The view lives in `Sources/Supermux/Mirrors/SupermuxNewWorkspaceDeviceMenu.swift` and reuses the `+` menu's rows. Not mirrored into the AppKit list's `emptyAreaMenu()` (that list is pinned off by #130) |
| 630 | `Sources/Devices/DeviceTerminalInputRouter.swift` | `device-mirror-input-batch` | Remote Macs input fidelity. The router queues a `SupermuxTerminalInputBatch` (ordered bytes and forwarded key presses) instead of `Data`: `import SupermuxKit`; the `pending` property; a designated `init(sendBatch:onFailure:)` plus upstream's `init(send:onFailure:)` kept as a convenience init that sends the batch's bytes only (upstream tests construct it); `enqueue` keeps `.namedKey` frames that decode as `SupermuxForwardedKeyEvent` and drops the mirror's own terminal replies (`SupermuxDeviceTerminalInput.batchItem`); `takePending` returns the batch |
| 631 | `Sources/Devices/DeviceTerminalMirrorSession.swift` | `device-mirror-input-batch`, `device-mirror-hidden-counts` | Input: `import SupermuxKit`, a defaulted `supportsSupermuxInput` init parameter (the convenience init passes the link's `supermux.terminal_input.v1` capability), and the router's send closure builds its params with `SupermuxDeviceTerminalInput.inputParams` (the ordered batch as `supermux_input` when the host takes it, else upstream's text). Sizing: `supermuxHidden` / `supermuxHostHoldsHiddenCounts` (a computed property over `SupermuxDeviceViewportGenerations.holdsHiddenCounts`, per client id and terminal, because the host keeps one counts override per client id that every pane of the terminal on the link shares), `supermuxSetHidden(_:)` (a pane going off screen calls `supermuxHandOverToShownPane()`, #643) and its reconcile (also run right after an attach sticks; it lifts the automatic false unless the host shows an override of `true`, and sends each automatic counts change one generation above the link's floor, `SupermuxDeviceViewportGenerations.bump`, so the host applies the panes' separate sends in order), tracking in `bind`/`stop`, a visibility re-check in `paneGridChanged`, `counts_override` on the replay while the pane is off screen, and `supermuxUserChoseCounts()` in `sharingSetCountsOverride`/`sharingReattach` so a user's own counts choice is never replaced (`SupermuxTerminalSizingVisibility`). The upstream `viewer:` argument/parameter lines sit inside the input fences because they gained trailing commas |
| 632 | `Sources/TerminalController.swift` | `device-mirror-input-host` | Two fences in `v2MobileTerminalInput`: the `text` guard accepts an empty text when the request carries a `supermux_input` batch, and the delivery closure hands the batch to `SupermuxDeviceTerminalInput.deliver` (bytes exactly via a Ghostty `text:` binding, keys through `ghostty_surface_key` with this Mac's terminal state) instead of `sendInputResult(text)` |
| 633 | `Sources/TerminalController+SharedSizing.swift` | `sizing-hidden-mac-pane` | Two fences. In `localSizingHost(surfaceID:create:)`, the new host is `var` and `SupermuxTerminalSizingVisibility.shared.prepareHost(&host, surface:)` marks an off-screen Mac pane `counts_override: false` before the first grid applies, so a never-shown tab does not hold the shared grid at its default size. At the top of `localSizingMacViewportChanged(surfaceID:)`, `surfaceGeometryChanged(_:)` re-checks visibility (a pane laid out for the first time posts no visibility change) |
| 634 | `Sources/Devices/DeviceSurfaceProvider.swift` | `device-mirror-key-resolver` | `makeCloudManualMirrorPane(… keyNameResolver: nil …)` → `SupermuxDeviceTerminalInput.keyResolver(for: machine)`, so a device-mirror pane forwards key presses to a Mac that takes them |
| 635 | `Sources/Surfaces/Workspace+CloudTerminalReservation.swift` | `device-mirror-key-resolver` | `reservationKeyNameResolver(for:)` returns `SupermuxDeviceTerminalInput.keyResolver(for:)` for a device instead of nil (the resolver returns nil per key until that Mac advertises `supermux.terminal_input.v1`) |
| 636 | `cmuxTests/CloudTerminalPaneReservationTests.swift` | `device-mirror-key-resolver` | `import GhosttyKit` and upstream's `devicePaneReservationsLeaveNamedKeysToGhostty` rewritten as `…UnlessTheMacTakesThem`: the device resolver exists and leaves Enter to Ghostty while the Mac's capabilities are unknown |
| 637 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Devices/SupermuxDeviceTerminalInput.swift` and `SupermuxTerminalSizingVisibility.swift` into the cmux target (ids `50BE0016…01`–`…04`, four entries each, `Devices/…` paths in the Supermux group) |
| 638 | `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+SupermuxInput.swift` | `unfenced` | Whole fork-owned file in the upstream package: `supermuxDeferInputDuringClipboardRead(estimatedBytes:replay:)`, a public door to the internal `deferInputDuringRuntimeClipboardRead`, so a device mirror's input batch waits behind a paste's clipboard read on this Mac as local typing does. Re-apply: keep it calling whatever upstream names the runtime clipboard-read input deferral |
| 639 | `Sources/GhosttyTerminalView.swift` | `device-mirror-key-sequence` | In `sendGhosttyKey`, the named-key branch's `if let keyName = terminalSurface?.manualInputKeyName(for:)` also requires `keySequence.isEmpty, keyTables.isEmpty`: while a Ghostty key sequence (leader) or key table is pending, the key stays with this Ghostty, which flushes the leader or matches the binding, instead of being forwarded and leaving the leader stuck. Also fixes the same gap for remote-tmux named keys |
| 640 | `Sources/TerminalController+MobileTerminalLifecycle.swift` | `mobile-terminal-close-force` | Remote Macs: a busy mirror tab could not be closed. Three fences in `v2MobileTerminalClose`: `let supermuxForce = v2Bool(params, "force") == true`; `controlSurfaceClose(… hasSurfaceIDParam: true, force: supermuxForce)` (upstream's last argument gains a trailing comma); and after the `.lastSurface` check, `.confirmationRequired` answers `confirmation_required` (upstream's `controlSurfaceCloseStrings().confirmationRequired`, `data.surface_id`) instead of falling through to the sanitized `internal_error`. Upstream #15613 added the guard to `controlSurfaceClose` but never updated this caller. Mac viewers always send `force` now (#641); the mapping still serves callers that do not |
| 641 | `Sources/Devices/DeviceWorkspaceLayoutCoordinator.swift` | `device-terminal-close-force`, `device-terminal-close-deferred` | Force: `performClose` sends `mobile.terminal.close` with `force: true` for every close (a mirror tab's close, Kill Terminal…, `vm.terminal_close`, a workspace deletion, a held close sent on reconnect), so another Mac's terminal ends like a local tab (this Mac already ran its own close confirmation); upstream sent no `force`, so the other Mac refused a busy terminal. Deferred: a `supermuxOfflineDeliveries` property (the deliveries from before the link dropped) set in `connectionChanged`, restored at the top of `projectionDidEnd` for an offline `.paneClosed`; `enqueueClose` offline, `cancelPendingCloses` and the `performClose` catch (link down) hold a mirror-tab close in `SupermuxDeviceHeldCloses` and fail it with `CancellationError`; `connectionChanged(connected)` sends the held closes first through a fenced `supermuxSendHeldClose` before `scheduleReconcile()` |
| 642 | `Packages/macOS/CmuxTerminalSharing/Sources/CmuxTerminalSharing/RemoteMacTerminalViewer.swift` | `remote-mac-viewer-generation-floor` | Adds `public mutating func advanceGeneration(atLeast:)` (`generation` is `private(set)` in the package) so a device mirror viewer starts above the host's viewport fence for its link's client id |
| 643 | `Sources/Devices/DeviceTerminalMirrorSession.swift` | `device-mirror-viewport-generations` | `measurePaneGrid` raises the viewer to `SupermuxDeviceViewportGenerations`' floor before `paneResized` and records the generation after it, marking this pane as the one whose grid the host holds when it produced a report (upstream: `return viewer?.paneResized(…)`); a fenced `supermuxReportsGrid()` (false while another pane of the terminal on this link reported later, else raises to the floor) gates the replay's viewport fields in `attach` (upstream: `if let viewer, viewer.detachment == nil {`), the dedicated re-report in `receiveReplaySizing` (upstream: `if let report = viewer?.viewportParams() {`) and, inside the #631 hidden-counts fence, `supermuxReconcileHiddenCounts`; a fenced `supermuxTakeOverGrid()`, called from `supermuxSetHidden(false)` (#631 fence), makes a pane that comes on screen the one that speaks (unless it already does) and re-reports its grid when attached, one generation above the floor (`bump`); `supermuxSpeakNow()` (take over, then settle the counts) and `supermuxHandOverToShownPane()`: a speaking pane that goes off screen while another pane of the terminal on the link is on screen (`SupermuxTerminalSizingVisibility.sibling(of:shown:)`) hands the role over instead of sending `counts_override: false`; `measurePaneGrid` does not make an off-screen pane the speaker (nor send its report) while a pane of the terminal is on screen; `sharingSetCountsOverride` and `sharingReattach` raise before their guard; `leaveSharing`: a speaking pane hands over to another open pane of the terminal (one on screen first), which reports its grid, and only the last pane sends and records the clear (`generation + 1`) and resets the shared counts flag; a following pane sends nothing (upstream: `if viewer.viewport != nil, isConnected() { sendSizing(…clearParams()) }`); the `viewport_transition` retry branch sleeps 50/100/200 ms before returning. A re-projected, reopened or second pane of a terminal reported below another pane's report or clear and stayed "Mac disconnected" until the link reconnected; two live panes of different sizes must not take the size from each other in turn; a hidden speaker must not stop this Mac counting while another pane is on screen, and a closing speaker must not drop this Mac from the terminal while another pane stays |
| 644 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Devices/SupermuxDeviceTerminalCloseSocketCommands.swift` (DEBUG drivers), `SupermuxDeviceViewportGenerations.swift` and `SupermuxDeviceHeldCloses.swift` into the cmux target (file refs `50BE00170100000000000001/7/9`, build files `…02/8/0A`, four entries each, `Devices/…` paths in the Supermux group). `…03–06` (`SupermuxDeviceTerminalClose.swift`, `SupermuxDeviceTerminalClosePrompt.swift`) were removed when every mirror-tab close started forcing |
| 650 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridReplay.swift` | `replay-theme-portable` | `public var includesColorState = true` plus a fenced `init(_:includesColorState:)`, and the full snapshot's OSC 10/11/12 + `appendPaletteRestore` wrapped in `if includesColorState { … }`. Default true, so phone, iOS and remote-tmux callers are unchanged; device mirrors pass false (`SupermuxDeviceMirrorColors.themePortableBytes`) so this Mac's theme stands for every color the other Mac's program did not set. E2E: `tests/supermux/loopback_mirror_appearance_e2e.py` |
| 651 | `Sources/Devices/DeviceTerminalMirrorSession.swift` | `device-mirror-viewer-colors` | `import CmuxCloudTui`; `private(set) var supermuxColors = SupermuxDeviceMirrorColorState()`; `Replay` gains `var colors: CloudTuiRemoteColors?`; `decodeReplay`'s render-grid branch returns `SupermuxDeviceMirrorColors.themePortableBytes(frame)` and `authored(in: frame)` (the program-authored colors, sparse); `attach()` feeds `supermuxColors.bytes(applying:colors:)` (the replay, then `settlingBytes`: OSC 110/111/112 for each special color the program did not set, OSC 104, then OSC 10/11/12/4 for the authored ones) instead of `replay.bytes`. Device mirrors look like local panes with this Mac's appearance, translucency included |
| 652 | `Sources/GhosttyTerminalView.swift` | `osc-default-bg-clears-override` | In `GHOSTTY_ACTION_COLOR_CHANGE`'s background branch, `surfaceView.backgroundColor = newColor` becomes `SupermuxDeviceMirrorColors.surfaceBackgroundOverride(for:defaultColor:isMirror:)`: on a manual-mirror surface a change back to this Mac's default background (Ghostty reports OSC 111 that way) clears the pane override instead of pinning a pane-local fill, so a program's reset gives the mirror its translucency back. Local panes unchanged |
| 653 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Mirrors/SupermuxMirrorAppearanceSocket.swift` (ids `50BE0017020…01`/`…02`, DEBUG driver `supermux.devices.mirror.terminal_background`) and `Sources/Supermux/Devices/SupermuxDeviceMirrorColors.swift` (ids `…03`/`…04`) into the cmux target, four entries each |
| 660 | `Sources/Workspace.swift` | `new-tab-at-end`, `mirror-terminal-to-right` | Two fences. (1) In `Workspace.init`'s `BonsplitConfiguration(...)`, `newTabPosition: .end` (upstream `.current`): every new tab appends, so a tab opened from a mirror (created unfocused on the owning Mac, whose pane stays on its first tab) no longer lands second on both Macs; explicit placements (to the right, duplicate, fork, restore) still reorder themselves. (2) At the top of `createTerminalToRight(of:inPane:)`: `if SupermuxMirrorTerminalPlacement.createTerminalToRight(of:inPane:in: self, focus: true) != nil { return }`, so a device mirror's tab routes to its Mac with the index right of the anchor |
| 660b | `Sources/TerminalController+ControlSystemContext2.swift` | `mirror-terminal-to-right` | The `tab.action` twin of #660 (2): in the `new_terminal_right` arm, after the anchor/pane guard, `SupermuxMirrorTerminalPlacement.createTerminalToRight(… focus: focus)`; accepted → `finish(.routedToRemote)`, rejected → `.createFailed` |
| 661 | `Sources/DockSplitStore+Appearance.swift` | `new-tab-at-end` | `makeConfiguration()`: `newTabPosition: .end` (upstream `.current`), the Dock's tab strip follows the same rule as workspaces |
| 662 | `Sources/Surfaces/Workspace+CloudTerminalCreation.swift` | `mirror-terminal-to-right` | In `routeCloudPaneTerminalCreate`, right after `let request = CloudTerminalCreationRequest(…)` (before the pane is reserved): `SupermuxMirrorTerminalPlacement.remember(request, destination:, source:, in: self)` notes the device terminal left of an explicit `.tab(index:)` for that request |
| 663 | `Sources/Devices/DeviceSurfaceProvider+TerminalLayout.swift` | `mirror-terminal-to-right` | In `createTerminal(nearTabID:splitDirection:request:)`, after upstream's `direction` param: a tab create adds `after_surface_id` from `SupermuxMirrorTerminalPlacement.afterSurfaceID(for:remoteWorkspaceID:on:catalog:)` (only when the request remembered one in the same remote workspace and the host advertises `supermux.terminal_placement.v1`). DEBUG only: when `SupermuxTabOrderDebug.takeLostReply()` is armed, the request is sent, its reply dropped and `DeviceLinkError.notConnected` thrown (the E2E's lost-reply fault) |
| 663b | `Sources/Devices/DeviceWorkspaceLayoutHost.swift` | `mirror-terminal-to-right` | Three fences in `handle(_:)`'s `device.workspace.terminal.create` path: the allowed-params set also takes `after_surface_id`; before `createTerminal`, `SupermuxMirrorTerminalPlacement.hostAnchor(…)` rejects (`invalid_params`) an anchor that is not a terminal of this workspace or comes with a split direction; after it, `place(terminalID, at:, inWorkspace:)` moves the new tab right of the anchor (selection untouched) before the reply's snapshot is captured |
| 664 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Mirrors/SupermuxTabOrderSocketCommands.swift` (DEBUG E2E drivers) and `SupermuxMirrorTerminalPlacement.swift` into the cmux target (ids `50BE00170300…01`–`…04`, four entries each, `Mirrors/…` paths in the Supermux group) |
| 665 | `Sources/TerminalController+SharedSizing.swift` | `sizing-default-policy` | In `localSizingHost(surfaceID:create:)`, right after #633's fence: `SupermuxTerminalSizingDefaults.shared.prepareHost(&host)` sets this Mac's size preference (default Priority with the Mac pane first, instead of upstream's Fit everyone) before the first grid applies |
| 666 | `Sources/Devices/DeviceTerminalMirrorSession.swift` | `device-mirror-sizing-claim` | Three fences: the stored `supermuxSizingClaim` (`SupermuxTerminalSizingClaim`), `SupermuxTerminalSizingDefaults.shared.mirrorAttached(self)` right after an attach sticks (after #631's reconcile), and `connectionDropped(self)` at the end of `linkDropped()`. Also, inside #631's fences: the convenience init's viewer identity is `SupermuxTerminalSizingDefaults.viewerIdentity(for: link.instance)` (this Mac's identity; DEBUG gives the loopback's mirrors a distinct device id) and `supermuxSetHidden(_:)` calls `mirrorVisibilityChanged(self)` after its counts reconcile (counts before the claim, as on attach). A shown mirror claims its terminal and pushes this Mac's preference once per connection |
| 667 | `Sources/TerminalSizePanelView.swift` | `sizing-sticky-preference` | Four fences: the mode picker's `set:`, `applyFixedSize` and `movePriority` call `SupermuxTerminalSizingDefaults.shared.userChoseMode/userChoseFixedSize/userChosePriority(…, surfaceID:, store:)` instead of `store.setMode/setFixedSize/setPriority` (the choice becomes this Mac's preference for every terminal; Cloud terminals fall through to the store); under the mode row, `SupermuxTerminalSizingScopeNote()` ("Applies to all terminals on this Mac.") unless `snapshot.isCloud` |
| 668 | `Sources/Workspace+TerminalSharing.swift` | `sizing-sticky-preference` | In `handleTerminalSharingContextAction`, the tab menu's size modes call `SupermuxTerminalSizingDefaults.shared.userChoseMode(mode, surfaceID: panelId, store: store)` instead of `store.setMode` (same beep on `false`) |
| 669 | `Sources/TerminalController.swift` | `device-mirror-viewport-limit` | In `applyMobileViewportReport`, upstream's `min(…, 300)` / `min(…, 120)` viewport clamp takes its limit from `SupermuxTerminalSizingDefaults.viewportLimit(deviceKind:)` (the report's `device_kind`, else the stored report's): 500x200 (`TerminalSizingPolicy.maximumFixedSize`) for a viewing Mac, upstream's 300x120 otherwise |
| 670 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Devices/SupermuxTerminalSizingDefaults.swift` and `SupermuxTerminalSizingSocketCommands.swift` (DEBUG drivers) into the cmux target (ids `50BE00170400000000000001`–`…04`, four entries each, `Devices/…` paths in the Supermux group) |
| 675 | `Sources/FileExplorerStore.swift` | `mirror-file-explorer-device` | Remote Macs Files panel. Three blocks: (a) `case supermuxDevice(SupermuxMirrorFileRoot)` in `FileExplorerWorkspaceRoot`; (b) its `applyWorkspaceRoot` arm, `applySupermuxDeviceWorkspaceRoot(root)` (`Sources/Supermux/Mirrors/FileExplorerStore+SupermuxDevice.swift`: identity, a new `SupermuxDeviceFileExplorerProvider` per folder, root, live refresh); (c) at the top of `refreshGitStatus`, a device provider's colors come from `provider.gitStatus()` (the owning Mac's `files.git_status`) under the same generation/context guard, because `gitStatusByPath` and `gitStatusGeneration` are private |
| 676 | `Sources/FileExplorerWorkspaceObservation.swift` | `mirror-file-explorer-follow` | Last line of `init`: `SupermuxMirrorFileExplorerRoot.followDeviceChanges(for: self)`. For a workspace with remote directory provenance (local workspaces start nothing), re-runs `refresh()` while it is a device mirror on every `SupermuxDevices.revision` bump (the other Mac's `cd`, link edges, capabilities arriving); the equal-root dedupe keeps it free when nothing changed. Ends when `stop()` clears `workspace` |
| 677 | `Sources/FileSearchScope.swift` | `mirror-file-search-scope` | `case supermuxDevice(SupermuxDeviceFileExplorerProvider)`, its `init(provider:)` branch, `==` arm (identity) and `debugName` (`supermuxDevice`): Files/Find search a mirror's folder on the owning Mac instead of reporting search as unsupported |
| 678 | `Sources/FileExplorerSearchController.swift` | `mirror-file-search-scope` | In `search(query:rootPath:scope:contentRevision:)`, after upstream's `.remoteCloud` dispatch: `if case .supermuxDevice(let provider) = scope { startSupermuxDeviceSearch(...); return }` (`FileSearchController+SupermuxDevice.swift`, a copy of `startRemoteSearch` that reuses `finishRemoteSearch`) |
| 679 | `Sources/FileExplorerPreviewCoordinator.swift` | `mirror-file-preview-error` | The failed-open alert's text falls back to `SupermuxDeviceFileError.previewAlertText(for:)` before upstream's generic sentence, so a mirror's refusal names the Mac ("Previews of files on <Mac> are limited to 8 MB.") instead of Cloud's "limited to 1 MB" |
| 680 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the Remote Macs Files panel files into the cmux target, four entries each, ids `50BE00170500000000000001`–`…14` (hex): `Mirrors/SupermuxMirrorFilesSocket.swift` (`…01`/`…02`), `SupermuxMobileHost+FilesRead.swift` (`…03`/`…04`), `SupermuxHostFileSearch.swift` (`…05`/`…06`), `Mirrors/SupermuxMirrorFileRoot.swift` (`…07`/`…08`), `Mirrors/SupermuxDeviceFileError.swift` (`…09`/`…0A`), `Mirrors/SupermuxDeviceFileTransport.swift` (`…0B`/`…0C`), `Mirrors/SupermuxDeviceFileExplorerProvider.swift` (`…0D`/`…0E`), `Mirrors/FileExplorerStore+SupermuxDevice.swift` (`…0F`/`…10`), `Mirrors/SupermuxMirrorFileExplorerLiveRefresh.swift` (`…11`/`…12`), `Mirrors/FileSearchController+SupermuxDevice.swift` (`…13`/`…14`), all in the Supermux group |
| 681 | `cmuxTests/SupermuxMobileAuthorizationTests.swift` | `mirror-file-explorer-authz` | `classificationCoversWorkspacePaneAndMacWideMethods` expects `files.read`, `files.search` and `files.git_status` to be workspace-scoped (like `files.list`), so the scoped-ticket matrix covers them |
| 682 | `Sources/FileExplorerPreviewCoordinator.swift` | `preview-error-alert-nonblocking` | `present(_:window:)` shows the failed-open alert with `SupermuxAlertPresentation.show(alert, preferring: window)` instead of `_ = alert.runCmuxModal(presentingWindow: window)`. It is called from the open's main-actor task, where `runCmuxModal`'s nested modal session starved the main queue: every socket call, mirror and main-actor task waited for OK (the files E2E hung the whole app). Now a sheet on the main window (or an app-modal alert run from a run-loop block outside the job) that nothing waits for |
| 683 | `Sources/CloudFilePreviewCache.swift` | `preview-refresh-readonly-replace` | In `refresh(_:provider:)`, the new copy replaces the preview's with `rename(2)` (throwing `POSIXError` on failure) instead of `replaceItemAt` / `moveItem`. The preview copy is `0o400` and `replaceItemAt` needs a writable original, so every refresh (reopening an open remote preview, its Refresh button) failed with "permission denied" and raised "Unable to open remote file" — Cloud and device previews alike |
| 684 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/SupermuxAlertPresentation.swift` (the non-blocking alert presenter for #682 and the busy mirror-tab close prompt) into the cmux target (ids `50BE00170600000000000001`/`…02`, four entries, in the Supermux group) |
| 685 | `Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/MobileTerminalRenderGridReplay.swift` | `replay-mouse-modes-last` | In `fullSnapshotBytes()`, the frame's modes are re-applied disabled first, then enabled, and the enabled mouse formats last in preference order 1005, 1015, 1006, 1016, instead of everything in the frame's code order. Ghostty keeps one mouse event mode (?9/?1000/?1002/?1003) and one mouse format (?1005/?1006/?1015/?1016): the last one set wins and resetting any of them clears whichever is on, so `?1003l` after `?1002h` (and `?1015l`/`?1016l` after `?1006h`) left every replayed view (a device mirror after any grid change or reattach, a phone) without mouse reporting, and crossterm's `?1015h ?1006h` replayed as urxvt. Known limit: the frame carries one flag per code, not Ghostty's single event/format value, so a program that turned tracking off with a different code than it set (`?1000h` then only `?1002l`) still has 1000 on in the frame and gets tracking back on replay; with several event modes on, the highest code wins. The real fix is exporting `flags.mouse_event`/`flags.mouse_format` from the ghostty fork's render-grid frame |
| 686 | `Packages/Shared/CMUXMobileCore/Tests/CMUXMobileCoreTests/SupermuxReplayMouseModeTests.swift` | `replay-mouse-modes-last` | Fork-only test file (the whole body fenced): runs the full snapshot's mode sequences through a model of Ghostty's single mouse event / format state and expects the program's modes to survive, crossterm's `?1015h ?1006h` (SGR wins) included |
| 687 | `Sources/Workspace.swift` | `device-reserved-pane-not-saved` | In `sessionSnapshot`, after `allPanelIds` is built: `allPanelIds.removeAll { cloudPendingCreations[$0]?.machine.isDevice == true }`. A mirror tab still waiting for (or failed to get) its terminal on another Mac is a reserved pane with no projection; saved like any terminal pane, a relaunch restored it as a LOCAL shell inside the mirror, placed first and looking like the other Mac's tabs. The layout is already pruned to the saved panels (`layoutCodec.pruned`) |
| 688 | `Sources/Surfaces/Workspace+CloudTerminalReservation.swift` | `device-pane-failure-mac-wording` | In `failReservedCloudTerminalPane`, a device machine's reserved pane gets `SupermuxDevicePaneFailureText.detail(machine:)` ("<Mac> couldn’t complete this. Check that it is online and try again.", `Sources/Supermux/Devices/SupermuxDeviceError.swift`) and no reference, instead of `failure.errorText`/`failure.copyableText` (upstream's Cloud wording: "The Cloud operation failed. Copy the diagnostic reference…") |
| 695 | `Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell/MobileShellComposite+WorkspaceActions.swift` | `ios-workspace-close-force` | In `closeWorkspace(id:)`, the `workspace.close` mutation sends `workspaceMutationParams(id:)` plus `force: true` (`supermuxCloseParams`): every phone close first asks "Delete Workspace?", so a workspace running a program closes like on the Mac instead of the host answering `confirmation_required` (shown as "<Mac> rejected the request."). Upstream sends no `force` |
| 696 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires `Sources/Supermux/Devices/SupermuxDeviceMirrorCloseSocketCommands.swift` (DEBUG `supermux.devices.user_close` driver of `tests/supermux/loopback_mirror_workspace_close_e2e.py`) into the cmux target: file ref `50BE00180200000000000001`, build file `50BE00180200000000000002`, four entries (`Devices/…` path in the Supermux group) |

## How to re-apply

### 2026-09-30 upstream merge — RETIRED rows

Removed from the registry at this merge; nothing to re-apply. Do not reuse the numbers.

- **#82** (`Packages/macOS/CmuxSettingsUI/.../Sections/AppSection.swift`, `new-workspace-home-dir`)
  and **#83** (`cmuxUITests/SettingsAppBehaviorUITests.swift`): upstream `0def9e1d7f9` (#14883,
  "Show one fixed subtitle for each Settings row") replaced the toggle-dependent ON/OFF subtitle pair
  with one fixed key, `settings.app.workspaceInheritWorkingDirectory.subtitle` ("Starts new
  workspaces in the working directory of the current workspace."), deleted `…subtitleOn`/`…subtitleOff`
  from the catalog, and replaced the subtitle-swap UI test with
  `testInheritWorkingDirectoryToggleKeepsFixedSubtitle`. The new text no longer promises the Ghostty
  fallback that #80 removes, so both files are byte-identical to upstream. The fork's orphaned
  `…subtitleOff` catalog entry was removed in the same merge (see #4b). If the owner wants the OFF behavior
  described ("…otherwise your home directory"), that means overriding the en+ja values of the fixed
  `…subtitle` key — a user decision against upstream's fixed-subtitle policy. #84/#85 (search
  keyword `home`) are unaffected.
- **#220** (`WorkspaceDetailView+Surfaces.swift`, `ios-pane-actions`): upstream #14149
  (3d8bd6ffea6, "iOS: direct SSH to any computer") removed the phone-local browser's ×
  (`MobileBrowserPane(onClose:)`). The workspace-title Close Pane item (#228 entries →
  `requestClosePane`) is the remaining fork close entrypoint. Knock-on handled in the same merge:
  `ios/cmuxUITests/cmuxUITests.swift` `testWorkspaceSurfacePickerClosesTheLocalBrowserThroughSharedPaneAction`
  (#226) no longer taps `MobileBrowserCloseButton`; it probes the web view and keeps only the
  title-menu Close Pane → Confirm leg.
- **#251** (`WorkspaceListTableCoordinator.swift`, `supermux-mobile-list-reconfigure-rows`): upstream's
  rebuilt table engine (c4dcf650783) does the same thing natively — height changes go through
  `performBatchUpdates` with no reload, content-only changes reconfigure live cells in place, and
  `reloadRows` runs only for `nativeActionChangedIDs`. The `reloadRows(...)` block the fence replaced
  no longer exists. Its regression test stays as #508.
- **#335** (`Sources/Mobile/MobileHostIrohRuntime+Lifecycle.swift`, `profileless-release-iroh-storage`):
  upstream deleted `MobileHostIrohRuntime(+Lifecycle).swift` in #12754 (on top of #12326 IROH v2); the
  storage choice now lives only in `Sources/Mobile/MobileHostV2Installation.swift` (#334).
- **#470** (`FakeSurfaceControlCommandContext.swift`, `claude-harness-socket-split-error-test`):
  upstream now ships the identical seam (`var splitResolution` + `controlSurfaceSplit` returning it,
  plus `splitInputs`/`paneCreateInputs`); keeping the fence would duplicate the method. #471 still
  uses the (now upstream) property.
- **#473–481, #483, #484** (`lint-allow-upstream-debt`): upstream fixed or justified the debt itself,
  and each fork diff was only the fence. `DiagnosticBuildStamp` became
  `extension DiagnosticReport { static func buildStamp(infoDictionary:fallbackName:) }`;
  `MacSurfaceTextDecoder`, `SimStreamTouchMapping`, `SimStreamProtocol`, `SimStreamWireCodec` and
  `MacSurfaceGalleryFixtureBytes` became `Sendable` structs with instance members; `PanelFileSurfaceView`
  lost `MacSurfaceFileContext`/`MacSurfaceHeader` entirely (f9fffa658fc); `MobileKeychainAccessGroupPolicy`
  became `extension String { static func cmuxKeychainAccessGroup(from:) }`; and the pixel-scroll lock
  (`GhosttySurfaceView` / `+LocalPixelScroll`) and Tailscale callback locks got upstream's own
  `// Carve-out:` / `// lint:allow` justifications. #482 (`KimiConfigLocationResolver`) survives.
- **#487** (`Sources/Workspace.swift`, `remote-tab-context-disconnect`): upstream now handles
  `.disconnectRemote` itself with the identical `disconnectRemoteConnection(clearConfiguration: false)`.

### 379. `CLAUDE.md` — `no-handoff-notify`

Upstream's CLAUDE.md is now a short index. Its handoff rule is one sentence at the end of the "CI,
review and merge" list's merge bullet: "Notify with `cmux notify` when a socket is available."
**Leave that sentence byte-identical.** The fenced fork rule is a self-contained `##` section
("Supermux: no `cmux notify` at handoff") right after that list, and explicitly overrides it: do not
notify at handoff or closeout, because this harness already notifies the user when a response
finishes — the `cmux notify` is a duplicate alert for the same event, and the user is about to read
the summary anyway. The handoff fields (was / now / the concrete check / the PR URL) belong in the
final response. (Before the 2026-09-30 merge the fence replaced an upstream paragraph in "First pass,
then dogfood" and also dropped `and re-notify` from a mid-dogfood sentence; upstream has since
removed that sentence and moved it into `skills/cmux-review`, so there is nothing left to edit
in-line.)

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

**Since the 2026-09-30 upstream merge, upstream has its own identity chain and its own extension.**
Upstream introduced `CMUX_APP_BUNDLE_IDENTIFIER` (→ `PRODUCT_BUNDLE_IDENTIFIER`),
`CMUX_HOST_BUNDLE_IDENTIFIER`, `CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER`,
`CMUX_APP_CODE_SIGN_ENTITLEMENTS` and `CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS` in
`ios/Config/*.xcconfig` (plus `ios/scripts/notification-service-bundle-id.sh`). Those `CMUX_*`
variables are now the **base layer** and the `SUPERMUX_*` ones chain into them:
`CMUX_APP_BUNDLE_IDENTIFIER = $(SUPERMUX_APP_BUNDLE_ID)` (fenced, Shared and Release),
`SUPERMUX_NSE_BUNDLE_ID = $(CMUX_APP_BUNDLE_IDENTIFIER).notification-service`, and
`SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS = $(CMUX_APP_CODE_SIGN_ENTITLEMENTS)` →
`CODE_SIGN_ENTITLEMENTS`, so an override of either family reaches every target. The build scripts
(#376–#378) pass both families. Upstream also added its own `NotificationService` app extension
(`ios/NotificationService/`, target `D4E2A007…`, `CmuxPhonePush`, decrypts
`userInfo.cmux.encryptedPayloads`, `group.dev.cmux.ios` + a keychain group; #12384/#12935/#14265).
**Resolved (option A): one extension.** iOS runs only one notification service extension per app,
so the fork's separate `SupermuxNotificationService` target was removed and its avatar decoration
now runs inside upstream's `NotificationService`: a push without `encryptedPayloads` (the fork's
direct Mac→APNs push) is delivered as `SupermuxNotificationDecorator.decorated(content)` (#516,
#383); relay pushes keep upstream's decryption. The extension signs as the fork's registered
`<app id>.notification-service` App ID (#369/#370 `ios-nse-supermux-decoration`) with
`Config/supermux-notification-service.entitlements` (#384: host keychain group +
`group.com.supermux.ios`), so the existing "Supermux Notification Service" Development/Ad Hoc
profiles (wildcard `TEAM.*` keychain groups, app group) sign it unchanged, and
`scripts/supermux-ios-release.sh` (#372) now expects `PlugIns/NotificationService.appex`.
**Known remaining gap:** the CLAUDE.md dogfood command (#244) still passes
`SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements`, which upstream changed to claim
`group.dev.cmux.ios`; the dogfood extension id has no App ID with that group, so the dogfood
command needs a keychain-only extension entitlements file before it signs again.

**Related, from the same merge — push targeting is now server-side.** Upstream #13741
(baa24b68731) removed the Mac-side `MobileIOSPairingTargetStore.pushTargetNamespace`: the Mac no
longer names `com.supermux.ios` as the push target (`PhonePushClient` sends
`targetBundleIdentifier: nil`). Supermux phone pushes therefore rely on the server's account-wide
fan-out reaching `com.supermux.ios` device tokens, or on the fork's direct push path (#332). Confirm
a push reaches the Supermux iPhone app when dogfooding, and weigh this when choosing A/B/C: the
extension that runs decides whether a relay (`encryptedPayloads`) push or a direct-APNs push renders.

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
  rebind) must forward the snapshot rather than taking the initializer's default `nil`. The
  `project` init parameter stays LAST (after upstream's `soundContext`/`origin`), and #353's
  explicit `CodingKeys`/`init(from:)` must list EVERY stored property — the 2026-09-30 merge had to
  add upstream's new `origin` there, or a remote-origin record would silently persist as local.
- **#354 (store):** banner decoration must stay SYNCHRONOUS and in place. Deferring the schedule
  behind an async raster reorders banners, and reaching for `MainActor.assumeIsolated` inside the
  authorization closure traps the process if that closure ever runs off the main actor. Resolve
  main-actor values before the closure; guard, never assert, inside it. Since the 2026-09-30 merge
  upstream builds the content inside `enqueueNotificationFeedback(ownerID:) { @MainActor … }`: the
  setup fence sits right before `let handleAuthorization`, the `supermuxDecorateBanner(content)` call
  after the `clickActionUserInfo` loop and before `UNNotificationRequest`.
- **#355/#374/#401 (Mac lists):** both surfaces call ONE project-icon snapshot helper above their
  `LazyVStack` and pass immutable `NSImage` values down. `NotificationRow.==` compares the icon by
  identity plus the avatar flag. A view below that boundary must never hold `SupermuxComposition` or
  the icon store (issue #2586 / #5794). The panel's All/Unread filter is panel-only; #399 preserves a
  still-visible focus or reseats to the newest visible row so Return never targets a filtered-out id.
  The panel row has ONE outer `.contextMenu` (Open, upstream's Copy, Mark as Read/Unread, Dismiss);
  a merge that puts upstream's row menu on the inner `rowContent` nests a second menu that shadows
  Mark as Read. Accent colors come from `@Environment(\.cmuxAccentColor)` (upstream #14988 removed
  the global `cmuxAccentColor()`), and `CmuxSystemSymbolImage` needs an explicit `tint:` (upstream
  #12145) — `.foregroundStyle` no longer tints it. Both rules also apply to the fork-owned
  `SupermuxNotificationRowBody.swift` and `SupermuxAppGlue.swift`.
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
  Inside the init, hoist anything the project-name closure reads (`headline`, `sourceName`) into a
  local first: a closure touching a stored property before `projectName` is set is a compile error.
  Since the upstream headline redesign (#11067/#11997), the workspace is the row headline and the
  provenance line is source + computer. The project attaches to the source label (the fenced
  `NotificationFeedProjectSource`), not a workspace label. Do not resurrect `NotificationFeedWorkspace`.
- **#404/#405 (phone icon mirror):** after every async fetch, revalidate the current store, project,
  custom-icon flag, and etag before writing. Pruning removes deleted ids and explicit `false`, but
  preserves optional `nil` because older hosts use it as "unknown" and a banner cannot re-fetch. This
  pair prevents an old response from resurrecting a removed icon without evicting legacy-host bytes.
- **#406 (release app group):** `group.com.supermux.ios` is one fixed contract shared by entitlements
  and both runtime readers. Reject a conflicting environment override before building; do not let
  verification and runtime silently point at different containers.
- **#373/#374 (popover):** the popover resolves icons above its list and hands down values only;
  its row `==` must keep comparing the icon by identity, or a decoded icon never repaints. The fork's
  grouped list replaces upstream's inline flat list wholesale, so upstream edits to that list must be
  ported into the `row(...)` helper by hand (the 2026-09-30 merge ported #5764: no `withAnimation`
  around `remove`).
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

A notification delivered while its exact target pane is already focused is admitted as read history by #453, so it creates no Mac or phone pane ring. Existing unread state that arrived before the pane was focused still clears only after the normal focus/direct-interaction acknowledgment path; the phone must not auto-clear that pre-existing state merely because the pane is visible. `Workspace.supermuxMobileUnreadPanelIDs(notificationStore:)` is the Mac-authoritative projection and must continue to call the same `Workspace.shouldShowUnreadIndicator(...)` predicate as `WorkspaceContentView`: visible notification/focused-read state, manual/restored panel state, and the representative pane for workspace-manual unread. Both mobile transports send `supermux_unread_panel_ids` for every workspace; `[]` means a supporting host with no indicated pane, while absence means an older/upstream host.

The mobile ring copies the Mac renderer's current geometry and presentation values exactly: 2pt inset, 6pt corner radius, 2.5pt system-blue stroke, 0.35 glow opacity, and 3pt glow radius. It is a visual-only overlay with hit testing disabled. `SupermuxMobilePaneUnreadPresentation` only tests whether the active remote panel id is in the transported array; it never reads the notification feed and never mutates unread state.

Acknowledgment stays Mac-side and reuses the existing input RPCs. `mobile.terminal.mouse` and `mobile.terminal.input` call `dismissNotificationOnTerminalInteraction`; browser `.click` and Simulator `.tap` call `dismissNotificationOnDirectInteraction`. These are the same `NotificationDismissalModel` entrypoints used by local Mac input, so the selected-target guard, exact surface scope, focused-read cleanup, restored/manual semantics, and sibling-pane preservation remain centralized. Do not replace them with workspace-wide `mark_read`, and do not add a competing SwiftUI gesture over terminal/browser/Simulator input.

When the pane-id field is present, `openWorkspace` must skip its legacy workspace-wide read receipt: navigation or continued visibility is not acknowledgment. Preserve that broad receipt only when the host omits the field, so upstream/older Macs keep their prior iOS behavior. Keep pane ids folded into `MobileWorkspaceListObserver`'s notification signature so a pane-only indicator change cannot be suppressed as a no-op. #397 must continue merging the workspace's manual and restored pane publishers, and #283 must subscribe to it; otherwise A → A+B changes never reach the hash while the workspace boolean stays true. Preserve the field through both legacy list decoding and state-sync-v2 projection.

Since the 2026-09-30 upstream merge: upstream's open read receipt is a demo / SSH / Mac `if` chain, and
#395's fence wraps only the final `else if` condition (`shouldUseLegacyWorkspaceReadReceipt`) with
upstream's `let workspaceHadUnread` unfenced above it — SSH and demo rows never send the Mac receipt.
Upstream moved the mobile mouse/input handlers onto `ControlTerminalSocketTarget`, so #392's fences
pass `surfaceId: surfaceId` (the canonical `resolved.surfaceID`) after the
`mobileInputAdmissionAnswer` early return, before `mobileClick` / `applyMobileViewportReport(params:terminalTarget:)`.

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

In `TerminalNotificationStore`, preserve both `direct-phone-push` fences. Visible forwarding stays
outside the upstream `shouldAttemptPhone` branch because a non-focused target must still use the
direct lane whenever phone forwarding is enabled, regardless of broad Mac activity/presence guesses.
It now shares #453's narrower exact-pane rule: if the notification has a pane id and that exact pane is
already focused in the active app, retain read history but send no phone push. The phone's foreground
delegate remains a final duplicate-presentation guard for any delivery that races phone-side
navigation. Dismiss forwarding stays beside `PhonePushClient.forwardDismissed` under the same
preference. Do not reintroduce a Mac-side presence/away heuristic — one was tried
(`SupermuxMacAwayPolicy`) and removed because broad guesses lose notifications for the
remote-control workflow.

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

### 334 (335 retired). Profileless local Release mobile host — `profileless-release-iroh-storage`

The installed `/Applications/Supermux.app` is Developer ID-signed without an embedded provisioning
profile. That signature can use the normal login Keychain but has no application-identifier entitlement,
so the data-protection Keychain fails with `errSecMissingEntitlement`; when identity creation fails, the
Mac never publishes a mobile route and the phone cannot mirror its APNs token.

Since the 2026-09-30 upstream merge the hook lives in `Sources/Mobile/MobileHostV2Installation.swift`.
Upstream deleted `MobileHostIrohRuntime.swift` and `MobileHostIrohRuntime+Lifecycle.swift` (#12754, on
top of #12326 IROH v2) and replaced them with `MobileHostIrxRuntime`, whose `provision` gets the endpoint
key and installation id from `MobileHostV2Installation`. In Release that uses `V2IdentityKeyStore` /
`V2InstallationIDStore` → `V2KeychainStore` (`kSecUseDataProtectionKeychain: true`), which fails on the
profileless build and makes `provision` throw. Widen exactly three guards from `#if DEBUG` to
`#if DEBUG || SUPERMUX_LOCAL_RELEASE` — in `deviceID()`, in `key(identity:)` and around
`debugDirectory()` — so the local release reuses upstream's own DEBUG file-backed store: a `0600` file
in `~/Library/Application Support/<bundle-id>/cmux-iroh-v2/development-keys/` inside a `0700`
directory, bundle-scoped through `configuration.stateDirectory`. Leave the `#if DEBUG` in
`MobileHostV2Configuration.current()` alone (it selects the "development" environment; the local
release must stay on production), and leave `hostReleaseTrack` alone. The fork-owned
`scripts/supermux-release.sh` must pass `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited)
SUPERMUX_LOCAL_RELEASE`. Do not define `DEBUG` for Release and do not alter upstream production Release
behavior.

Residual risk: the legacy-compatibility broker (`LegacyCompatibilityService` → `IrxBrokerService` →
`IrxBrokerCacheFactory`, Shared package `CmuxIrxTransport`) also uses a Data Protection Keychain cache
(`IrxKeychainJSONCache`) in non-DEBUG builds. It degrades rather than throws (`load` returns nil, `save`
returns false), so it should not block v2 activation, but legacy (older-iOS) discovery caching may not
persist on the local release. Not fenced: it is an SPM package target and it is unclear whether
`SUPERMUX_LOCAL_RELEASE` reaches package targets.

Re-verify with `tests/test_supermux_release_stale_artifact.sh`, a real local Release build, and macOS logs:
there must be no `V2ControlFailure.persistenceFailed` (nor keychain errors), the phone must reconnect,
`Application Support/com.supermux.app/cmux-iroh-v2/development-keys/` must be populated, and
`supermux-apns-devices.json` must appear after the APNs-enabled phone app launches.

### 261–284, 291, 297–298. Cross-platform workspace unread badge

Keep one badge design, not platform-matched copies. `SupermuxUnreadBadgeStyle` owns count formatting, proportions, rim, gradient, and shadow values; `SupermuxUnreadBadgeContent` is the single SwiftUI body used by the Mac and phone wrappers. The pure-AppKit sidebar may keep its native Core Graphics renderer for pooled-row performance, but it must measure and paint from those shared values. Keep the package `Resources` declaration and `supermux.unreadBadge.overflow` catalog entry together so the visible `99+` marker remains localized on both apps.

On macOS, preserve custom unread colors, the leading/trailing badge-position setting, global font magnification, and hover-independent wrapped-row geometry. A wide count capsule must be measured rather than clipped into the old square slot. The AppKit layer shadow needs a capsule `shadowPath`; otherwise every visible row pays for an inferred offscreen shadow.

Carry `supermux_unread_count` through BOTH mobile transports: legacy `mobile.workspace.list` and state-sync v2. Absence means an upstream cmux Mac whose count is unknown, so the phone renders the shared countless-dot form; zero is a known Supermux count. Hash the count in `MobileWorkspaceListObserver.previewSignatures`, then still assign `signatures[workspace.id] = hasher.finalize()` after the fenced combine. The narrow count override exists only so the behavior test can reproduce a 2 → 1 count-only transition while holding the latest notification and unread boolean fixed. Upstream #10791 now does `hasher.combine(summary.unreadCount)` itself; the fence stays after it for the test seam and the pane ids.

**Since the 2026-09-30 upstream merge upstream ships its own count** (`MobileWorkspaceUnreadState`, from its `unread_count` wire field, with group headers summing members). The phone's workspace-row and group-header badges (#278–#280) now read upstream's `unreadState`; `supermux_unread_count` stays on the wire only for the fork-owned project rows (`SupermuxProjectWorkspaceRowSnapshot`) and pre-merge Macs — a phone paired with a pre-merge Supermux Mac (which sent only `supermux_unread_count`) shows the countless dot on flat rows until the Mac updates. Upstream still draws its indicator in a leading gutter (debug `leftShift`/`diameter` sliders, nil count shows "1"); the fork keeps its inline capsule, and those DEBUG controls are inert on fork rows. **OPEN DECISION:** (a) keep this; (b) adopt upstream's gutter badge and drop #278–#280/#284; (c) also retire `supermux_unread_count` in favor of `unread_count` (a cross-package change: model, Mac, SupermuxMobileUI project rows).

On iOS, render no unread view at all for a read workspace. The color rail begins at x=0, the badge trails the workspace/group title, and the wrapped-row height cache includes the exact rendered badge text (`nil`, `""`, numeral, or `99+`) — since the 2026-09-30 merge as `supermuxUnreadBadgeText` on upstream's `WorkspaceListWorkspaceLayoutKey` in `WorkspaceListRowModel.swift` (#284). Project-nested rows and project detail rows use the same phone wrapper. Keep its headline-relative `@ScaledMetric` so Dynamic Type scales the badge with the row.

Re-apply the wire, observer, cache, and renderer changes as one unit. Verify with `swift test --package-path Packages/Shared/SupermuxMobileCore`, `swift test --package-path Packages/Shared/CMUXMobileCore`, `swift test --package-path Packages/iOS/SupermuxMobileUI`, and the `MobileWorkspaceListFidelityTests` suite under the `cmux-unit` scheme.

### 245–249. iOS terminal default zoom — `ios-terminal-default-zoom`

Keep `MobileTerminalFontPreference.defaultSize` at 12 pt and make every defaulted `GhosttySurfaceView` initializer reference that constant rather than duplicating a number. `MobileTerminalZoomPreference.resolvedFontSize` must return the explicitly saved size when present and the built-in 12 pt size otherwise. The production terminal mount in `WorkspaceDetailView+TerminalArtifacts.swift` must pass that resolved value into `GhosttySurfaceRepresentable`; passing the built-in constant directly recreates the bug where tapping the floating "Set as default" button persists a value that no newly selected terminal ever reads. The floating Reset action continues to apply the resolved value, while Restore built-in clears the explicit preference and applies 12 pt. Keep `MobileTerminalZoomControlTests` in the package test target to cover persistence/clearing and dispatch from all three floating buttons.

### 252–258. RETIRED (2026-08-24 upstream merge)

Upstream removed the iOS Agent Chat GUI, so Supermux retired the dependent Focus Mode feature,
settings, localization, package dependencies, and tests. The artifact/event/RPC infrastructure
upstream retained is not part of these retired UI touchpoints.

### 250. RETIRED (2026-08-24 upstream merge)

Upstream independently adopted the identity-preserving workspace-list toolbar structure, so the
fork fence and registry row were removed.

### 251. RETIRED (2026-09-30 upstream merge) — `supermux-mobile-list-reconfigure-rows`

Upstream's rebuilt workspace-list table engine (c4dcf650783) reconfigures instead of reloading on
its own: height changes go through `performBatchUpdates` with no reload, content-only changes are
written into live cells in place, and `reloadRows` runs only for `nativeActionChangedIDs` (UIKit
caches swipe-derived accessibility actions on the cell). The `reloadRows(...)` block the fence
replaced no longer exists. The regression test stays registered as #508
(`WorkspaceListCellIdentityTests.swift`) and now pins upstream's behavior. Nothing to re-apply —
but if a future upstream engine goes back to a blanket `reloadRows` on height changes, project
avatars will again blank whenever an unrelated row changes height.

### 228. iOS workspace title-menu tools — `ios-workspace-toolbar-persistent-actions`

Upstream now owns the chat-less workspace toolbar structure. Supermux appends its associated-project
Run action, capability-gated Changes and Files rows, and destructive Close Pane action after
`WorkspaceTitleMenuContent`. The detail view owns one stable `SupermuxWorkspaceRunSession`; its
fork-owned modifier follows `projects.list` plus `run.state`, so command availability and start/stop
state come from the same authoritative stores as the Projects list. The title menu extends
`isEnabled` and fingerprints Changes/Files availability, pane-close availability, and run state
through `WorkspaceTitleMenuValue.toolEntriesFingerprint`, preventing `.equatable()` from pinning a
stale menu closure (the field is #500, its test #501; both fenced since the 2026-09-30 merge). The
two sheet bindings remain above the UIKit branch because their shared mount spans every detail
surface, and presentation uses the same keyboard-dismiss chrome policy as upstream actions. Since the
2026-09-30 merge `isEnabled` is upstream's `hasTitleMenuActions || canReconnect ||
sshFilesTerminalID != nil` plus the fenced fork disjuncts, and `toolEntriesFingerprint` follows
upstream's new `canReconnect`/`canBrowseFiles` in the memberwise order.

### 229 and 237. RETIRED (2026-08-24 upstream merge)

Upstream removed the iOS Agent Chat button and its chat-dependent toolbar previews. Supermux took
that UI removal instead of restoring its former fixed chat-button cluster or override tests.

### 213–214. RETIRED (2026-08-24 upstream merge)

Upstream replaced the old `GhosttySurfaceView` keyboard workaround with
`GhosttySurfaceHostView`/`KeyboardDockGeometrySource` and host-driven keyboard transitions. The
fork implementation and its now-incompatible UITest assertions were removed.

### 217–227. iOS pane close + Simulator creation — `ios-pane-actions`

Keep the Mac mutation surface in the existing fork namespace rather than adding more upstream dispatch cases: `SupermuxMobileMethod.paneClose` / `.simulatorCreate`, `SupermuxMobileCapability.panesV1`, the matching authorization classifications, and the handlers in `Sources/Supermux/TerminalController+SupermuxMobile.swift`. Close must resolve an explicit `workspace_id` + `panel_id`, verify the panel belongs to that workspace, mark it history-eligible, and call the single generic `Workspace.closePanel(force: true)` path — never branch by terminal/browser/Simulator type. Simulator creation must reuse `Workspace.newSimulatorSurface(inPane:focus: false)`, remain gated by the upstream Simulator feature/capability, and return the normal `MobileSimulatorPanelDescriptor`. Phone requests add `focus: true`; the Mac then routes the created panel through the shared control-focus action before replying and closes it if that focus phase fails. A missing flag retains the older background-create behavior.

On iOS, keep one captured-target confirmation path. `WorkspaceActiveSurface.paneCloseTarget` maps a terminal to the selected terminal id, a generic Mac surface to its own id, the phone-local browser to local close, and streamed browser/Simulator surfaces to their panel ids. `WorkspaceDetailView+SupermuxPaneActions.swift` owns the action: the local fallback closes through `BrowserSurfaceStore`; remote panes call the capability-gated fork client and wait for authoritative workspace/browser/Simulator events instead of mutating optimistic copies. The workspace-title Close Pane item calls `requestClosePane` (upstream #14149 removed the phone-local browser's × at the 2026-09-30 merge, retiring #220; do not reintroduce it). New Simulator uses a request UUID exactly like New Browser so a late response cannot override a newer user selection; install the returned descriptor into `MobileSimulatorStreamStore` before selecting it.

The native surface picker carries only Simulator-create availability plus its closure. Since the 2026-09-30 merge upstream builds that picker as a presentation-time `UIMenu` in `TerminalPickerMenuContent.swift` (#221), so `SupermuxPaneMenuControls` is a UIKit factory (`makeMenuElement() -> UIMenuElement?`, nil when unavailable), not a SwiftUI view; Close Pane's localized destructive row moved to fork-owned `SupermuxWorkspaceToolsMenuEntries` in the title menu and retains the shared confirmation (`supermux.panes.*`, en + ja). Any upstream preview that constructs `TerminalPickerMenuActions` supplies only an inert Simulator-create closure (#488); since the 2026-09-30 merge the field itself is defaulted (`var createSimulator: () -> Void = {}`, #223) so upstream call sites and tests that omit it keep compiling. Against an upstream Mac or an older fork host without `supermux.panes.v1`, remote close and New Simulator stay hidden; the phone-local browser remains closable from the title menu. Re-run the headless SupermuxMobileCore/Kit/UI package tests, compile the app-hosted suites, and preserve the focused coverage in #224–227.

### 230–236. ccx-specific Claude session restore — `ccx-resume-launcher`

`ccx` ends with `exec ... claude`, so process capture sees the real Claude binary and expanded ccx-generated flags but loses the launcher identity, proxy-key discovery, current model fleet, and system-prompt construction. Keep the contract explicit and narrow: `~/.local/bin/ccx` exports `CMUX_CLAUDE_RESUME_LAUNCHER` with its absolute path before `exec`; `AgentLaunchEnvironmentPolicy` retains that non-secret marker only when it standardizes to the current user's exact `~/.local/bin/ccx`, and only for kind `claude`. Never allowlist `ANTHROPIC_AUTH_TOKEN` or accept raw shell commands/arbitrary executable paths.

Thread the captured environment through all three resume-argv entrypoints: `AgentRestorePlanner`, app-side `AgentResumeCommandBuilder` in `RestorableAgentSession.swift`, and hook-side `agentSurfaceResumeCommand` in `CLI/cmux.swift`. `AgentResumeArgv` must return only `[ccxPath, "--resume", sessionID]` for a valid marker so ccx dynamically rediscovers credentials and rebuilds its generated settings/agents/prompt; do not replay the expanded captured ccx arguments into ccx because that duplicates its own flags. With no valid marker, retain upstream's bare `claude --resume ...` wrapper route unchanged.

For structured restore, `AgentRestorePlanner.routeManagedWrapper` leaves the validated ccx path direct but still adds `CMUX_AGENT_RESTORE_LAUNCH=claude:<session-id>`, which ccx passes through to the cmux Claude wrapper it invokes. For inline fallback commands, `AgentRestoreLaunch.applying(toStoredCommand:)` likewise recognizes the validated ccx executable and adds authorization without replacing it with the ordinary Claude wrapper token. Since the 2026-09-30 merge `routeManagedWrapper` first runs upstream's `restoreLaunch` guard, Subrouter Codex/Claude routes and `managedWrapperCustomExecutableEnvironment`; the fence replaces only the final first/executable-name guard, so upstream's Subrouter Claude route runs before the ccx check. Upstream's generic user-declared external launchers (`AgentExternalLauncher*`, #10494) may cover part of what ccx does — migrating ccx onto them is an open user decision. Keep `SupermuxCCXResumeLauncherTests` as a whole-file package test and run `swift test --package-path Packages/macOS/CMUXAgentLaunch`; the suite must cover direct ccx argv, authorization, marker persistence without token persistence, kind isolation, and invalid-marker fallback.

### 215–216 (including 215a–b). Deferred arrowless-popover presentation and dynamic reanchoring — `popover-dynamic-height-reanchor`

`ArrowlessPopoverAnchor` manually sizes and presents an `NSPopover` from `NSViewRepresentable.updateNSView`. The initial implementation updated the hosted SwiftUI root, forced layout, and called `show(relativeTo:of:preferredEdge:)` synchronously inside that representable update. On macOS 27, opening Token Usage hit AppKit's child-window ordering while SwiftUI was still rendering, logged `Publishing changes from within view updates` plus reentrant `NSHostingView` layout, and then crashed in `ObservationTracking._AccessList` when a deferred focus notification read `WorkspacesModel.tabs`.

Keep all popover lifecycle mutations outside the representable update turn and the originating AppKit layout cycle. A main-actor `Task` is insufficient on macOS 27: dogfood showed it could close the child window in the same cycle and still emit `NSHostingView is being laid out reentrantly` for every dismissal. `CmuxPopoverVisibleUpdateScheduler` therefore coalesces on the next common-mode main-run-loop turn with generation-based cancellation. A hidden requested popover installs/layouts the latest root view and then presents it there. A dismissal cancels a pending initial show; if a popover is already present, close it through the same scheduler. Re-opening before that close runs cancels the stale dismissal. The coordinator's injectable `showPopover` seam exists so the package test can prove no presentation occurs synchronously and that open→close cancellation suppresses the show without opening a real window.

Installing a new `NSHostingController.rootView` and forcing its layout must also be separate run-loop phases: the root update invalidates intrinsic size, then a second scheduled turn measures and presents or resizes/reanchors. This prevents live scan-progress and animation updates from laying out the hosting view while SwiftUI is still rendering the newly installed root. For an already-visible popover, keep the latest `preferredEdge` and `detachedGap`; when the rounded fitting size differs from `popover.contentSize`, set the new size and call `show(relativeTo:of:preferredEdge:)` again on the SAME popover, inside the no-implicit-animation scope. AppKit documents that re-showing an already-visible popover updates its positioning view and rect. Do nothing for dismissed/hidden popovers, invalid fitting sizes, or unchanged rounded sizes. The focused package tests in #216 pin the deferral, cancellation, and mutation plan. Re-apply all four files together, then run `swift test --package-path Packages/macOS/CmuxAppKitSupportUI`. Since the 2026-09-30 merge the base is upstream's rewritten anchor (`presentationAnimation`, `CmuxPopoverGroup` registration after show, `closingPopovers` teardown ownership, `dismiss(resetPresentation:)`, `popoverWillClose`, `dismantleNSView`, #13442's no-binding-write dismiss): the deferred `updateNSView` switch maps `.deferredPresentation`/`.deferredVisible`/`.none` onto it, `deferDismissal` schedules `dismiss(resetPresentation: false)`, `present` captures edge/gap, `dismiss`/`popoverDidClose` call `cancelDeferredPresentationUpdate()`, and a fenced convenience `init(isPresented:showPopover:)` keeps #216's tests compiling.

### 208–211. Alternate-screen whole-line quantization — `ios-terminal-alt-scroll-quantize`

Physical trace at 0.25× speed: two slow drags emitted 101 fractional scroll packets of 0.03–0.11 lines (totaling 0.70 and 1.30 lines), yet the TUI scrolled dramatically — the Mac's wheel handling rounds each delivery to a minimum magnitude of one line, so speed was proportional to PACKET COUNT and both the scroll-speed preference and finger travel were irrelevant. Keep `TerminalAlternateScrollLineQuantizer` (signed carry, trunc-toward-zero emit, non-finite ignored) and run budget-admitted alt-screen lines through the per-surface quantizer in `scrollTerminal`, forwarding only whole lines. This is interpreted identically by discrete and precise-pixel hosts, makes delivered lines proportional to finger travel × speed preference, and cuts RPC volume. Primary-screen scrolling is untouched (it needs fractional precision for the 1:1 local mirror). Tests: `TerminalAlternateScrollLineQuantizerTests`.

### 203–207. Alternate-screen gesture direct apply — `ios-terminal-alt-scroll-direct-apply`

Dogfood after the momentum fixes: TUI scrolling was "fast and kinda janky and delayed, not smooth". Cause: every alt-screen repaint delta went through the verified pipeline's serial freeze/apply/present/GPU-read-back/verify fence, which cannot drain gesture-rate repaints — motion arrived in clumps. Keep `TerminalAltScrollDirectApplyPolicy` (window 0.8 s, full frames always verified, backwards clock fails closed). `scrollTerminal` stamps `terminalAlternateScrollLastInputAtBySurfaceID` when the budget admits alt-screen lines; `requiresVerifiedReplayApplication` returns `false` for alt-screen delta frames inside the window so they take the ordered legacy VT-patch path (the consumer's `terminalOutputApplicationPath` keys purely off the chunk flag — no consumer change needed; this is the same direct path screen-anchored primary deltas already use). Correctness is deferred, not lost: the first verified delta after the window performs the exact-pixel comparison, and any drift triggers the standard full-replay recovery. Tests: `TerminalAltScrollDirectApplyPolicyTests`. Since the 2026-09-30 merge upstream's `requiresVerifiedReplayApplication` is a chain of early-return guards (any non-primary frame returns `true`) with a revision-continuity gate for direct application: the fork block sits right after `guard let frame = delivery.sourceRenderGridFrame else { return true }`, before the primary-only guard, and additionally requires `MobileTerminalRenderGridRevisionContinuity.admits(frame, delivered:)`, so a stale-base/resize delta is never VT-patched directly (slightly stricter than before).

### 196–202. Terminal scroll speed setting — `ios-terminal-scroll-speed`

User-tunable wheel sensitivity, added after dogfood found alt-screen scrolling "too fast" once the backlog fixes landed. Keep the shared `MobileTerminalScrollSpeedPreference` (key `cmux.mobile.terminalScrollSpeed`, range 0.25–1.5, default 1.0) in CMUXMobileCore. `GhosttySurfaceView.scrollSpeedMultiplier` multiplies the point→line conversion in `enqueueScrollMechanicsDelta` ONLY — never scale `TerminalNativeScrollGeometry` samples, which map bounded primary history 1:1 to the finger. CRITICAL: the alt-screen budget (#189/#191) must admit in unscaled gesture units via `admit(lines:speed:at:)` — dogfood proved that with an absolute cap, fast drags saturate at the same delivered count at every speed and the slider is imperceptible on TUIs. `MobileDisplaySettings.terminalScrollSpeed` persists it beside `terminalScrollbackRows`; `MobileSettingsView` renders a Display-section slider (`MobileSettingsTerminalScrollSpeed`); the detail view threads it into `GhosttySurfaceRepresentable`, which applies it in `makeUIView` and `updateUIView` for live effect. Localization keys `mobile.settings.terminalScrollSpeed` and `.footer` need en + ja. Tests: `MobileTerminalScrollSpeedPreferenceTests`, the scroll-speed cases in `MobileDisplaySettingsTests`, the multiplier-validation case in `GhosttySurfaceNativeScrollTests`, and the speed-proportional budget case in `TerminalAlternateScrollBudgetTests`.

### 193–195. Output backlog coalesce — `ios-terminal-output-backlog-coalesce`

The decisive physical trace: during a fast alt-screen scroll gesture the phone's per-surface `TerminalOutputDeliveryQueue` reached 90–101 pending frames (alt-screen dirty-row deltas are nonreplaceable), then drained one verified apply at a time for up to 4 s after touch-up. That drain IS the user-visible "momentum"; the UIScrollView and the input-side budget were already clean. In `deliverTerminalOutput`, after enqueueing, when `pendingCount >= maxTerminalOutputPendingBeforeReplayCoalesce` (24, declared in `MobileShellComposite.swift`), the delivery is a render-grid frame, and no replay barrier bypass is active: replace the queue with a fresh `TerminalOutputDeliveryQueue`, rotate the stream token, remove stale barrier-ack bookkeeping, log `terminal.output.backlog_coalesce`, and call `terminalOutputNeedsReplay(surfaceID:)` so one authoritative replay supersedes the entire backlog. Do not drop individual deltas (stateful patches) and do not coalesce raw-byte chunks. Regression: `TerminalOutputBacklogCoalesceTests.swift`. Upstream added its own 128-entry hard overflow cap (`TerminalOutputDeliveryQueue.maxPendingDeliveries`, `takeOverflowed()` → replay `.droppedFrame`) at the 2026-09-30 merge; the two caps are complementary (upstream's bounds memory, the fork's fixes gesture latency), and the fork block sits right after upstream's overflow check.

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

Re-apply the production coordinator from upstream PR #9762 head `1420c2c972`, plus the fork's authority and release-behavior hardening. Track authoritative screen/boundary, raw/effective UIKit offsets, and presentation translation. Primary screen uses `TerminalNativeScrollGeometry` for bounded content size, edge rubber band, fractional row deltas, and at-most-two-row layer compensation **only when** `scrollPresentationAuthority.appliesLocally`; Mac-authoritative `.verifiedRenderGrid` sessions must keep the unbounded wheel path so gestures still reach the Mac even when the local mirror has no history. Reconfigure when authority changes. Set `decelerationRate` to `UIScrollView.DecelerationRate(rawValue: 0)`. In `scrollViewWillEndDragging`, always pin `targetContentOffset` to the current offset regardless of release velocity. In `scrollViewDidEndDragging`, unconditionally disable/re-enable the pan recognizer to clear UIKit's physics state, then set the current content offset non-animated before flushing and settling. All three layers are required: physical iOS 26 was observed resuming deceleration after target-offset and same-offset cancellation alone. A locally-owned confirmed primary screen with no boundary fails closed to zero range; alternate/unknown screen retains the recentered unbounded wheel surrogate. Store scrollbar boundaries regardless of frame/action arrival order, flush pending deltas at drag/deceleration end, settle only after interaction and local applies drain, clear all state on surface replacement, and reset translation before typed-input bottom snap. Apply translation to live renderer layers, the frozen verified container, and fallback view—never the frozen content child. Keep the DEBUG probe fields used by #181. Since the 2026-09-30 merge upstream has its own line path in `flushPendingScrollIfNeeded` (#10592: whole-line quantization with a fraction carry "for TUI feel") that the bounded primary path's fractional `rowDelta` with `pixels: 0` would otherwise land in; a fence sets `dispatchLines = lines` and zeroes `linePathFractionCarry` when `usesBoundedNativeScroll`, preserving fractional/precise-pixel delivery for bounded primary history (alt-screen/unbounded keep upstream's quantization, so #209 now receives whole lines, harmlessly). Upstream also has its own pixel-precise local scroll path with UIKit momentum; the fork's zero-deceleration bounded geometry wins whenever the render-grid screen is known primary — whether to keep the #9762 port or adopt upstream's path is an open user decision needing physical-iPhone dogfood. Upstream's #15491 `TerminalScrollGestureRoute` was reverted by #15686; the fork never had it.

### 177. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplayFrozenPresentation.swift` — `ios-terminal-native-scroll`

Initialize the frozen presentation container's transform from `nativeScrollContentTranslationY`. Deliberately omit upstream's `copy.transform = renderer.transform` when copying renderer contents: the container alone owns translation, otherwise a verified freeze offsets the snapshot twice.

### 176. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+VerifiedReplay.swift` — `ios-terminal-native-scroll`

In frozen-presentation layout, do not assign `frozenLayer.frame` while the layer may have a translation transform. Set `bounds = layer.bounds` and center `position` explicitly, then continue laying out background/content as upstream.

### 175. `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttySurfaceView+LocalScrollbackScroll.swift` — `ios-terminal-native-scroll`

On the serial output queue, compute cell-center mouse position as before, then convert logical lines to backing-pixel distance and set Ghostty's precise-scroll flag. After each batch, pump any accumulated follow-up; when the pump is drained, call `settleBoundedScrollMechanicsIfPossible()` so an idle authoritative boundary can resynchronize after the in-flight flag had deferred it. The work closure uses upstream's `workQueue.asyncPriority` (upstream's duplicate `let scale` is dropped).

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

Keep a pure policy test using a non-empty `MobileIOSBuildScope`. Assert `.official.persistenceScope(from:)` returns `nil`, and `.development(expectedInstanceTag:)` returns the detected scope unchanged. This pins the Release-sideload case without depending on compile configuration or bundle globals. Upstream's `.development` carries associated values since the 2026-09-30 merge, so the test constructs `.development(expectedInstanceTag: "fix-mobile-ui")`.

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

Since the 2026-09-30 merge upstream #14695 adds control-stream repair (`CmxByteTransportControlStreamRepairing`; the writeLoop task is `Task<UInt64?, any Error>` reporting the control-stream generation, with the fork capacity-wait fence in front). Its two new `PendingWrite` constructions need fenced edits: in `resolveControlFramesStranded(before:)` release the stranded request's slot (`releaseRequestWorkCapacity(requestID:)`) first, because a frame written to a replaced stream can never be answered there (otherwise the slot leaks for the connection's life and repeated repairs can wedge the writer), and let a resend re-enter admission with its recorded decoded size (fallback `written.frame.count`); in `verifyReplacedControlStream` the probe carries `decodedFrameByteCount: payload.count`. Releasing a stranded slot assumes the host is no longer processing that request — the one-slot margin covers most of the window; stress control-stream repair in dogfood.

### 156. `Packages/iOS/CmuxMobileTransport/Tests/CmuxMobileTransportTests/CmxTailscaleRouteProofTests.swift` — `tailscale-packet-tunnel-proof`

Keep the packet-tunnel regression beside the existing exact IPv4/IPv6 proof test. Build a valid proof and validate a satisfied established connection path whose available interfaces include the proven Tailscale interface, whose remote address/port exactly match the route, and whose `localAddress` is `nil`; validation must succeed. Keep the fenced fail-closed companion proving a non-nil local address outside `proof.selfAddresses` throws `localEndpointMismatch`. Do not weaken upstream's unfenced generation and interface-substitution expectations: a newer authority generation must throw `routeGenerationChanged`, and replacing the proven interface identity must throw `interfaceChanged`.

### 155. `Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxTailscaleRouteProof.swift` — `tailscale-packet-tunnel-proof`

Retain upstream's `authoritySnapshot.generation == proof.generation` guard. The fork changes only `connectionPath.localAddress`, treating it as an optional extra proof rather than a required field:

```swift
// SUPERMUX:begin tailscale-packet-tunnel-proof
if let localAddress = connectionPath.localAddress,
   !proof.selfAddresses.contains(localAddress) {
    throw CmxTailscaleRouteProofError.localEndpointMismatch
}
// SUPERMUX:end tailscale-packet-tunnel-proof
```

Do not weaken the security-relevant checks around this change: the authority generation must still match; the current authority path must be satisfied and still expose exactly one matching Tailscale interface with the prepared interface identity and self-address set; the connection path must be satisfied and contain that exact interface; and the remote address/port must exactly match the authorized peer. Network.framework can report `localEndpoint == nil` for a ready packet-tunnel connection while all of those stronger route/interface checks succeed, so requiring a non-nil value rejects a valid route locally before credentials are written.

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

### 147. `.github/workflows/ci-guards.yml` — `local-release-script-guard`

Upstream moved the Linux guard steps out of `ci.yml` into the reusable `ci-guards.yml` at the
2026-09-30 merge. Immediately after upstream's "Validate release-build timeout guard" step, run the
fork-owned local Release-script regression, gated on the same guard group:

```yaml
# SUPERMUX:begin local-release-script-guard
- name: Validate supermux local Release script
  if: ${{ matrix.group == 'release-notary' }}
  run: ./tests/test_supermux_release_stale_artifact.sh
# SUPERMUX:end local-release-script-guard
```

It runs only when the `release-notary` guard group is routed; unknown indirect inputs
(`scripts/supermux-release.sh`, `scripts/supermux-ios-release.sh`) fail open to every group.

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

Since the 2026-09-30 merge upstream's `renderItems` also takes `orderedGroups:` and
`effectiveMembership:` (membership computed over the FULL `tabs`, which keeps render and row
configuration in agreement). Only the `tabs: mainListTabs` argument is fenced (its own small
fence); pass upstream's other arguments through unchanged. Edge case: if a group's anchor is a
project-owned (hidden) workspace, its visible members now render under the group header instead of
as root rows. The VoiceOver label is upstream's `workspaceSnapshot.accessibilityLabel(index:
workspaceCount:)` (upstream deleted `TabItemView.accessibilityTitle(for:)`); the fence sits at that
call site in `TabItemView.body`, passing `snapshot.supermuxVisibleIndex ?? index` /
`snapshot.supermuxVisibleCount ?? accessibilityWorkspaceCount`.

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

Since the 2026-09-30 merge upstream refactored the row background: `backgroundColor(for:) -> Color`
became `rowBackground(for:railColor:)`, `rowBackgroundShape(style:…)` and
`backgroundStyle(for:isEmphasized:) -> SidebarWorkspaceRowBackgroundStyle`, and upstream added an
opt-in, window-activation-aware "Subtle Selection Highlight" (`workspaceColors.subtleSelection`,
default off). The faint-selection override now sits in a fence at the top of
`backgroundStyle(for:isEmphasized:)` and returns `SidebarWorkspaceRowBackgroundStyle(color: <the
`sidebarSelectionColorHex` hue or NSColor(Color.accentColor)>, opacity: 0.16)` for the active row,
with no `edgeColor` — so upstream's subtle-selection hairline never draws on the active row, and
upstream's toggle only affects multi-selected rows. **OPEN DECISION:** keep this override, or retire
`sidebar-selection-faint` and default upstream's `subtleSelection` to on (which would also let
upstream's `usesInvertedActiveForeground` logic apply).

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
Since the 2026-09-30 merge items 4–5 are split by upstream's background refactor: the
`.padding(.vertical, 4)` fence stays at the row's padding site (followed by upstream's
`.background(rowBackground(…))`), while corner radius 5 (×2) and the hover tint (the fill fallback
when `style.color == nil`) live in a fence at the top of `rowBackgroundShape`. The flat-row spinner
fence (`sidebar-flatrow-activity`) adds `&& workspaceSnapshot.supermuxActivity != .working` to
upstream's new compact-agent-status code (`compactStatusGlyph`, `showsUnreadBadge`); with upstream's
opt-in `sidebar.compactAgentStatus` on, the fork's amber working indicator still renders beside
upstream's compact glyph (dogfood with it on).
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

The Claude harness process seam (touchpoint #432) adds file reference `50BE0001…0136` and build
file `50BE0001…0137` for `SupermuxHarnessProcessSessionProtocol.swift`, wired in the same four
places so controller orchestration can use a protocol-injected process in app-target tests.
The native event transport seams under the same touchpoint add file references
`50BE0001…013A`/`…013C` and build files `50BE0001…013B`/`…013D` for
`SupermuxHarnessNativeEventTransport.swift` and `SupermuxHarnessWebHostOwnership.swift`, also wired
in the same four places each.

The focused native transport tests (touchpoint #450) add file reference `50BE0001…013E` and build
file `50BE0001…013F` for `SupermuxHarnessNativeEventTransportTests.swift`, wired into the
`cmuxTests` target in the same four places as the existing harness test file.

The focused-pane notification regression test (touchpoint #451) adds file reference
`50BE0001…0140` and build file `50BE0001…0141` for
`SupermuxFocusedPaneNotificationTests.swift`, wired into the `cmuxTests` target in the same four
places as the other fork-owned app-target tests.

The focused-pane notification policy (touchpoint #452) adds file reference `50BE0001…0142` and
build file `50BE0001…0143` for `SupermuxFocusedPaneNotificationPolicy.swift`, wired into the
`Supermux` group and the `cmux` target's Sources phase. The path may stay bare because the final
filename contains no OpenStep-special `+` character.

The phone agent-launch host (`Sources/Supermux/SupermuxMobileHost+Agent.swift`, the Mac side of
`mobile.supermux.agent.*`) adds file reference `50BE0002…00E3` and build file `50BE0002…00E4`,
wired into the `Supermux` group's `children` and the `cmux` target's Sources phase `files`. Its
path MUST be quoted (`path = "SupermuxMobileHost+Agent.swift";`) because of the OpenStep-special
`+`. It uses the `50BE0002` prefix, so it does not count toward the `50BE0001` total below.

The Changes-panel file-diff opener adds file reference `50BE0001…0146` and build file
`50BE0001…0147` for `SupermuxFileDiffOpener.swift`, wired the same way (Supermux group + `cmux`
Sources phase; bare path, no `+` in the filename).

Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `237`.

### 4. `.github/swift-file-length-budget.tsv` — RETIRED (0.65 merge)

Upstream removed the entire Swift file-length budget system (`Remove Swift file length budget`,
upstream #8125): the tsv, `scripts/swift_file_length_budget.py`, and the ci.yml validation step
are all gone. The fork's budget rows and the #121 `budget-fork-caps` per-PR cap widening were
deleted with it. Nothing to re-apply.

**This retirement invalidates every "raise the budget row" / "budget bump is in the #4 table"
instruction that used to appear in the re-apply notes below** (#5, #34–36, #37, #39, #62–67, #95,
#96, #108). Those steps have all been struck; do not go looking for the tsv. The only remaining
CI length/quality gate is `scripts/swift_warning_budget.py` (Swift *warnings*, not file length),
run from `.github/workflows/ci-macos.yml` / `ci-guards.yml` since upstream split `ci.yml` at the 2026-09-30 merge. Verify with
`git ls-files | grep -i length.budget` — it must print nothing.

### 4b. `Resources/Localizable.xcstrings` — additive supermux keys

All `supermux.*` keys (en + ja) live here because cmux packages resolve `String(localized:)`
against the app bundle. The merge is **additive only** — `scripts/supermux-merge-loc.py`
rewrites only `supermux.*` entries and leaves every other key byte-identical. On an upstream
merge conflict here, union both sides (supermux keys never collide with cmux keys) or simply
re-run the regen pipeline (see "Localization" in SUPERMUX.md). Verify no non-supermux key
changed: `git diff <base> -- Resources/Localizable.xcstrings | grep '^[-+]' | grep -v supermux`.
The one deliberate non-`supermux.*` rewrite left is #84's
`settings.search.alias.setting.app.workspace-inherit-working-directory` (en + ja). The former
`settings.app.workspaceInheritWorkingDirectory.subtitleOff` rewrite retired with #82 at the
2026-09-30 merge — upstream deleted that key, and the fork's orphaned copy was removed too. That
merge also restored 24 upstream keys the fork had deleted but upstream code still uses; a key
deletion is never "fork-only" if an upstream call site reads it. Known gap:
`supermux.notificationFeed.row.project` (used by #366's accessibility text) is in no catalog and
falls back to "Project".

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

Since the 2026-09-30 merge the enum itself (case/label/symbol/shortcutAction/paneModes) lives in
upstream's new `Sources/RightSidebarMode.swift` (#498), not `RightSidebarPanelView.swift`. Declare
`case changes` AFTER upstream's `case machines`: upstream's new tab customization (reorder/hide, ⌃1–9
following the visible order) is positional over `allCases`, so Changes last keeps every upstream
tab's digit. Changes has no switch shortcut action, so it never answers a ⌃digit — adding a
`switchRightSidebarToChanges` action is an open decision (it would be a new fork shortcut under the
shortcut policy). Upstream's `.machines` (and `.customSidebar`) appear beside `.changes` in the no-op
groups, and `.machines` → `MachinesPanelView` precedes the fork's content arm.

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

Since the 2026-09-30 merge upstream adds `.overlay { CloudSurfaceDropGate }` to the canvas/bonsplit
`Group` — keep it on `workspaceContent` so the drop gate covers the splits, not the presets bar — and
`.modifier(CloudPaneCreationFailurePresentation)` after `.frame`, which sits after
`// SUPERMUX:end presets-bar` and applies to the fork's VStack.

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

**Logo (#242, #242b, #507).** `CmuxLogo.imageset` is the in-app brand lockup read by
`RestoringSessionView`. It keeps its upstream name and path — a base64-PNG-in-SVG at 1024×1024 —
so no Swift call site changes; only the embedded image is replaced, squircle-masked (superellipse
n=5) so it reads as an app mark at 28–30pt. Upstream (#11725) re-sourced it as PNGs
(`cmux-logo.png`/`@2x`/`@3x` + a PNG Contents.json); on every merge keep the fork's SVG and
SVG-only Contents.json (`preserves-vector-representation: true`) and delete those PNGs. Since the
2026-09-30 merge `SignInView.brandHeader` reads upstream's new `CmuxSignInMark` imageset
(#11872/#11876) instead; the fork overwrites its `cmux-sign-in-mark.svg` with a byte-identical copy
of `cmux-logo.svg` (#242b). Upstream also added a launch screen (`UILaunchScreen` →
`LaunchLogo.imageset`, #10621/#10913) showing the cmux glyph; the fork re-renders its three PNGs
from the Supermux art (#507). The paired string `mobile.signIn.title`
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

Since the 2026-09-30 merge upstream's CLAUDE.md is a short index and its "iOS builds open on the
iPhone by default" rule lives in `ios/AGENTS.md`. The fence is a self-contained `##` section
("Supermux: phone dogfood…") after upstream's "Area instructions", and its intro says it overrides
that `ios/AGENTS.md` section. (Before, it was a `###` subsection right after the rule in CLAUDE.md.)
All five fork CLAUDE.md fences (#1, #244, #339, #379, #459) are now self-contained `##` sections,
none inside upstream lists or tables. It exists because upstream's rule is actively wrong here:

- `ios/scripts/reload.sh --tag <tag>` builds **Debug** with `CMUX_DEV_TAG=<tag>`, and a tagged DEV
  iOS build may pair only with the same-tag Mac DEV build. The user cannot sign in to those, so the
  phone gets an app that installs and is then unusable.
- (The old "`ios/scripts/reload-cloud.sh` does not exist" sentence was dropped at the 2026-09-30
  merge: upstream no longer names that script.)
- The command passes only `SUPERMUX_APP_BUNDLE_ID`; the xcconfigs chain upstream's
  `CMUX_APP_BUNDLE_IDENTIFIER` off it (#369/#370). Upstream's own `NotificationService` extension
  makes the command FAIL as written (ValidateEmbeddedBinary: its Release id
  `dev.cmux.app.beta.NotificationServiceV2` is not prefixed by `com.supermux.ios.dogfood`); it needs
  `CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER=com.supermux.ios.dogfood.NotificationService` (and,
  with signing on, likely `CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS`) — see the #368–372
  open decision.

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
SupermuxRemoteMacsSettingsCard(hostActions: hostActions)   // Remote Macs card (#596)
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
carries no fence at all since the 2026-09-30 merge (#34 moved to `Sources/GhosttyApp+KeybindOverrides.swift`
with upstream's extraction). The
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
Since the 2026-09-30 merge upstream's new right-sidebar tab customization adds `.onDrag`/`.onDrop`
(`RightSidebarModeBarDropDelegate`) to each `ModeBarButton` and a `.contextMenu { tabCustomizationMenu }`
on the bar. Keep the fork's `ViewThatFits` structure and put upstream's drag/drop modifiers inside the
fenced `modeButtonsRow(showsLabels:)` (it computes `let displayedModes = availableModes` and returns
the `HStack`); keep upstream's `tabCustomizationMenu` after the fenced helper and upstream's
`fileExplorerState.mode.isAvailable()` guard on the open-as-pane button. The modifiers attach to each
`ViewThatFits` candidate (only one renders) — dogfood drag-reordering tabs at a narrow width.

**27. `cmuxTests/SidebarWidthPolicyTests.swift` — `right-sidebar-min-width-test`.** Two clamp
assertions that previously hardcoded `276` now read `CGFloat(RightSidebarWidthSettings.minimumWidth)`
so they track the floor regardless of its value. Upstream converted the file to Swift Testing at the
2026-10-01 merge: re-apply by replacing the `- 276` in `rightSidebarConfiguredMaxBelowMinimumClampsToMinimumWidth`
and `rightSidebarClampKeepsMinimumWidth` with the fenced `minimumWidth` expression, and keep the fork's
fenced `@Test rightSidebarClampAllowsWidthBelowLegacyFloor` after them.

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
  `key: "\r", command: true, shift: true`. Both tables must agree. Since the 2026-09-30 merge
  upstream's package table lives in `builtInDefaultStroke` (front door `defaultStroke(using:
  ShortcutDefaultResolver)`), and both tables add upstream's `newPaneAutoLayout` ⌃⌘N right before the
  fenced `toggleSplitZoom` arm. That merge's new upstream defaults (⌃⌘N, ⌃6 machines, ⌥⇧⌘T team
  picker, ⌘Y / ⇧⌘Y cloud, ⌥Z word wrap) collide with no fork stroke; the only duplicate involving a
  fork action remains the deliberate ⌘G (`supermuxToggleRun` / `findNext`).
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

- **34. `Sources/GhosttyApp+KeybindOverrides.swift`** (upstream moved `loadCmuxOwnedGhosttyKeybindOverrides`
  and `numberedWorkspaceGhosttyUnbinds` here out of `GhosttyTerminalView.swift` at the 2026-09-30
  merge; the fence sits at the end of that function)**:** a fenced second `loadInlineGhosttyConfig` call in
  `loadCmuxOwnedGhosttyKeybindOverrides` adds `keybind = super+shift+enter=unbind` **and**
  `keybind = super+enter=unbind` (prefix `supermux-owned-keybind-overrides`): the first frees
  ⇧⌘↩ (`toggle_split_zoom`) for the commit accelerator, the second frees ⌘↩
  (`toggle_fullscreen`) for `supermuxCommit`. Both parse to the physical Enter trigger, exactly
  matching the default bindings, and Ghostty's `unbind` removes them (`Binding.zig`), after
  which the chords fall through to the SwiftUI commit buttons. If upstream adds these unbinds
  itself, drop this fence; if it changes the triggers, mirror the new triggers here. Upstream's
  new `loadGhosttyHostKeybindDefaults` already unbinds `super+enter` before user config loads,
  so the fork's `super+enter` line is redundant for defaults but still runs after user config and
  overrides a user binding; `super+shift+enter` is unbound only by the fork. Keep both lines.
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

One fenced line in `TabManager.addWorkspaceIfActive` (since the 2026-09-30 merge upstream's creation
entrypoint; `addWorkspace` is now a deprecated wrapper that traps on a finalized manager, and git
auto-merged the fence into `addWorkspaceIfActive`), right after `newWorkspace.owningTabManager = self`:

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
- **`restoreClosedWorkspace`** (reopen, ⌘⇧T) *does* go through the creation entrypoint (now
  `guard let workspace = addWorkspaceIfActive(...) else { return false }`, with the `forget` fence
  after it), so it would wrongly mark
  the reopened workspace standalone — it explicitly `forget`s the mark right after, restoring
  directory-based nesting (a reopened project workspace re-nests; the only residual imprecision is
  a standalone `+` workspace that sat exactly at a project's durable-linked root or inside a
  worktree dir, which re-nests on reopen — matching pre-change behavior and not worth persisting
  per-workspace standalone state through closed-workspace history).
- **`TabManager+DetachedWorkspace`** (move-tab / move-surface) builds a `Workspace` directly, so it
  marks the new workspace standalone too (touchpoint #42).
- **`releaseRestoredAwayWorkspace`** (session restore's teardown of the replaced pre-restore
  workspaces) never reaches the central `closeWorkspace` forget, so a fenced call `forget`s each
  released workspace's association/standalone entries itself, right after upstream's
  `workspace.retireFromOwningTabManager()` (which replaced `teardownAllPanels` /
  `teardownRemoteConnection` / `owningTabManager = nil` at the 2026-09-30 merge); the restored
  replacements re-nest by directory:

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
  projects model and survive, so a revived closed window re-nests by directory. Since the 2026-09-30
  merge the retained set also unions upstream's `recoverableMainWindowRoutes()` tab managers'
  workspace ids (orphaned routes whose workspaces are still live but no longer in
  `mainWindowContexts`), and the anchor comparison is upstream's `if tabManager === closingTabManager`.
- The fork-owned `Sources/Supermux/SupermuxTabManagerOpener.swift` also calls
  `addWorkspaceIfActive` (`guard let … else { return nil }`) since that merge.

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
   selection update sets `selectedTabId = nil` when `tabs.isEmpty` — since the 2026-09-30 merge a
   fenced `if tabs.isEmpty { selectedTabId = nil }` ahead of upstream's
   `if let next = workspaces.selectionTargetAfterClose(closedIndex:)` (which returns nil on empty).
2. The last-workspace close sites that called `window.performClose(nil)` now call
   `closeWorkspace(workspace, allowEmptyingWindow: true)` (in `closeWorkspaceIfRunningProcess`
   this drops upstream's `closeConfirmed` / `closeWindowForLastWorkspace(workspaceId:closeAlreadyConfirmed:)`
   branch; `closeWindowForLastWorkspace` stays in the file as upstream code, and upstream's
   `closeWorkspacesWithConfirmation` now also calls it on the omitted short-circuit). **This was three sites; since the 0.65
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
   the plan passes `willCloseWindow: false` because closing the final workspace is no longer a
   window-closing action (upstream replaced the plan's `acceptCmdD:` field with `willCloseWindow:`
   at the 2026-09-30 merge; it now drives both Cmd-D acceptance and the `.window` vs `.workspace`
   warning policy).

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
   (`selectedTabId = nil; return removed`) when its last workspace moves out, instead of upstream's
   refill (since the 2026-09-30 merge `if recoverEmptyWorkspaceAfterStartupIfNeeded() { return removed }`); `restoreSessionSnapshot` restores a snapshot persisted with zero
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

Since the 2026-09-30 merge the `empty-home` startup-recovery guard `guard !tabManager.tabs.isEmpty
else { … return }` replaces upstream's `if tabManager.recoverEmptyWorkspaceAfterStartupIfNeeded() {
didRecover = true }` (the new upstream TabManager helper that refills an empty window), and the
titlebar `onChange` guard reads `guard let authoritativeSelection else { updateTitlebarText();
return }` (upstream's renamed binding). The remote-tmux `.sessionEnded` arm (#60) still replaces
upstream's rewritten `acquireOptionalWorkspaceIfActive { addWorkspaceIfActive(…) }` workaround.

**OPEN DECISION — empty home does not survive relaunch.** Upstream #14788 (46444eaad52, "Discard
phantom (0-tab) windows…") adds `isPhantomSessionWindow` in
`Sources/SessionPersistencePolicy+CrashStorage.swift` (unfenced, auto-merged) and drops every window
with no workspaces and no window Dock on save, on startup load and on reopen, to avoid a
WindowServer wedge from several phantom windows at launch. The TabManager side above is intact
(`testRestoreSessionSnapshotKeepsPersistedEmptyHomeEmpty` still passes because it calls TabManager
directly), but an intentionally-emptied window is dropped before TabManager sees it. Options: (a)
accept upstream — empty-home windows are ephemeral across relaunch (current behavior); (b) add a
fork fence in `isPhantomSessionWindow` / `pruningCmuxCrashDiagnosticWindows` that keeps a single
intentional empty-home window (needs a marker, since a real phantom looks the same). Upstream also
renamed `testSessionSnapshotKeepsWindowWithNoRestorableWorkspaces` to
`testSessionSnapshotDropsWindowWithNoRestorableWorkspaces`; the fork takes it as-is.

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
   `portalHoverDelegationTarget(at:routingContext:pressedMouseButtons:dragPasteboardTypes:hasLiveTabTransfer:)`
   (the last param is `@autoclosure () -> Bool? = nil`; nil means "read the live tab-drag registry
   in the main-actor body", since a nonisolated default-argument autoclosure cannot).
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

**Since the 2026-09-30 upstream merge this family (#73–79) is largely redundant — a retirement
candidate.** Upstream (#10804 plus `LiveTabDragCapabilityResolver`) now requires a *live* tab-drag
registry entry before hover or pass-through routing uses a Bonsplit or file-preview payload, blocks
stale Finder file URLs on hover unless a native drag is active, and dropped sidebar-reorder from
hover pass-through entirely (`.pointerHover` returns `hasTabTransfer`). That fixes the same stale
`.drag`-pasteboard bug. The fork guard was kept as defense in depth, re-applied on upstream's new
signatures: the fenced `pressedMouseButtons:` param still sits before `hasActiveDropDrag:`, followed
by upstream's `hasLiveTabTransfer:`/`hasLiveFileDropPayload:`; #77's guard stays right after
`allowsPaneDropHitTesting`, before upstream's mouse-up liveness gate; #74's
`portalHoverDelegationTarget` forwards a fenced `hasLiveTabTransfer` autoclosure (default
`DragOverlayRoutingPolicy.hasLiveTabTransfer(in: NSPasteboard(name: .drag), resolver:
AppDelegate.shared?.liveTabDragCapabilityResolver)`), or an in-flight tab drag would be claimed for
the web view. The tests inject the live flags so the pressed-button gate stays the only variable:
#79 injects `pressedMouseButtons: 1` into every hover call and passes all live flags with
`pressedMouseButtons: 0` in the stale-hover test; #78 takes upstream's
`testStaleSidebarReorderDoesNotPassThroughBrowserHoverEvents` (both assertions false); #75's
regression test uses only the Bonsplit payload plus `hasLiveTabTransfer: true`. Retiring the family
means dropping #73, #76, #77, #78, #79, the drag-guard half of #75, and the #74 autoclosure.

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
- **#82 (`AppSection.swift`) and #83 (`SettingsAppBehaviorUITests.swift`) — RETIRED at the
  2026-09-30 merge.** Upstream #14883 replaced the ON/OFF subtitle pair with one fixed
  `settings.app.workspaceInheritWorkingDirectory.subtitle` ("Starts new workspaces in the working
  directory of the current workspace.") that no longer promises the Ghostty fallback, and deleted
  `…subtitleOn`/`…subtitleOff`; both files are byte-identical to upstream. Describing the OFF
  behavior ("…otherwise your home directory") would now mean overriding the fixed key's en+ja
  values — an open user decision against upstream's fixed-subtitle policy.
- **`Resources/Localizable.xcstrings` (#4b, unfenced):** the en+ja values of
  `settings.search.alias.setting.app.workspace-inherit-working-directory` swap
  `ghostty`/`Ghostty` for `home`/`ホーム` (#84). (The former `…subtitleOff` rewrite is gone with #82.)
- **`Sources/SettingsSearchAliases.swift` (#84) and `Sources/SettingsSearchIndex.swift`
  (#85; upstream extracted `SettingsSearchIndex` out of `SettingsNavigation.swift` at the
  2026-09-30 merge):** the settings-search keywords for the toggle drop the stale `ghostty` term for
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
- ~~#82 / #83~~ — already retired at the 2026-09-30 merge (upstream's fixed subtitle; nothing
  left to revert).
- **#84 `Sources/SettingsSearchAliases.swift`** and **#85 `Sources/SettingsSearchIndex.swift`** —
  the `home` search keyword reverts to `ghostty`.
- **#4b `Resources/Localizable.xcstrings`** — the en+ja values of
  `settings.search.alias.setting.app.workspace-inherit-working-directory` revert. That is the
  ONLY non-`supermux.*` key the fork still touches, so retiring #80 would make #4b purely additive
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

### 13 (cont.) + 90. `Packages/Shared/SupermuxMobileCore` registration (package-test lane + workspace group)

`Packages/Shared/SupermuxMobileCore` is the supermux-owned zero-dependency wire-contract package
for the iOS companion app (`mobile.supermux.*` method/topic/capability constants + Codable DTOs +
the `SupermuxWireJSON` Codable↔`[String: Any]` bridge). Two upstream files register it:

- **`scripts/ci/package-test-lane.sh` (#13, inside the existing `ci-package-tests` fence; it lived
  in `.github/workflows/ci.yml` until upstream split that workflow into reusable workflows and lane
  scripts at the 2026-09-30 merge):** upstream's `PACKAGES=(...)` allowlist never lists fork
  packages, so the fence runs `swift test --package-path Packages/Shared/SupermuxMobileCore`
  explicitly (same pattern as `Packages/SupermuxKit`). Re-apply: restore the fenced loop at the end
  of `run_package_tests`, after upstream's selected-package loop and before the results table; keep
  every fork package the fence tests listed there. `PACKAGES=(...)` is parsed by the router with a
  regex, so never put comments inside that array.
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

### 13 (cont.) + 90 (cont.). `Packages/iOS/SupermuxMobileKit` registration (package-test lane + workspace group)

`Packages/iOS/SupermuxMobileKit` is the supermux-owned iOS domain layer for the companion app:
the `SupermuxMacCalling` seam (typed `mobile.supermux.*` request/response + event streams), the
production `SupermuxMacClient` adapter over `CmuxMobileRPC`'s `MobileCoreRPCClient`, the
`SupermuxMobileCapabilities` gate (one accessor per `supermux.*.v1`), the etag-keyed
`SupermuxProjectIconCache`, and the `@Observable` phone stores (`SupermuxMobileProjectsStore`).
Dependencies are path-only (`../../Shared/SupermuxMobileCore`, `../CmuxMobileRPC`), so no
`Package.resolved` is generated. Two upstream files register it:

- **`scripts/ci/package-test-lane.sh` (#13, inside the existing `ci-package-tests` fence):**
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
- **#148–#151 + #502 (`supermux-mobile-projects-table-row`), the iOS Projects row:** re-apply all
  five files together; they are one feature. Order matters in two places: the zero-margin
  `.supermuxProjects` case in the coordinator's `configure` must not fall into the general chrome
  margins, and the `items.append(.chrome(.supermuxProjects))` must land inside the LEADING chrome
  run in `workspaceTableItems`. Both are explained in #148. Since the 2026-09-30 merge upstream's
  rebuilt table engine diffs `WorkspaceListRowModel` values (new file `WorkspaceListRowModel.swift`,
  #502): the Projects payload rides IN the row model as `.supermuxProjects(SupermuxProjectsTableRowConfiguration)`,
  its height identity is `WorkspaceListRowLayoutKey.supermuxProjects(String)` through upstream's
  shared LRU cache, and change detection is the fork-owned `extension
  SupermuxProjectsTableRowConfiguration: Equatable` (`==` is `!renderChanged(previous:next:)`, so
  upstream's model diff repaints on exactly the old conditions). The row model also carries the
  Projects `actions` closures; when two models compare equal the cell keeps the older closure bundle
  (as the old `rowChanged` did) — harmless because every closure captures the stable
  `SupermuxProjectsSectionModel` weakly.
- **`Packages/iOS/CmuxMobileShellUI/Package.swift` (#98, `supermux-mobile-shellui-deps`):** the
  package + target dependency lines. Re-apply: both lines, same fence id.
- **`scripts/ci/package-test-lane.sh` (#13, inside the existing `ci-package-tests` fence):**
  `swift test --package-path Packages/iOS/SupermuxMobileUI` appended after the SupermuxMobileKit
  entry (same pattern; restore the fenced block, keep every fork package listed).
- **`cmux.xcworkspace/contents.xcworkspacedata` (#90, unfenced — generated XML):** the package's
  FileRef in the iOS group. Re-apply with `python3 scripts/check-workspace-package-groups.py --write`;
  never hand-edit.

Same `lint-ios-package-conventions.sh` coverage as SupermuxMobileKit above (the #109
`lint-ios-conventions-fork-scopes` fence adds the fork packages to SCOPES).

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

Five fence blocks share the `fix-resolved-policy-path-deps` id (seven before the 2026-09-30 merge;
upstream independently shipped the per-root lockfile and iOS-workspace remote-closure skips, with a
`merge_base is not None` guard, so the fork's two duplicate fences — the last two bullets below —
were dropped and upstream's code taken):

- **`lockfile_recorded_dependency_calls(calls)`** filters dependency calls to URL/registry pins that
  SwiftPM can record.
- **`path_dependency_remote_pin_roots(...)`** distinguishes pin-free local graph edits from path
  edges that change which remote-pinned packages enter the resolution closure.
- **`file_text_at`** treats a manifest absent at the merge base as empty without leaking expected
  `git show` stderr.
- **`current_remote_memo`** supplies the shared graph memo used by the precise changed-root check.
- **The changed-roots skip** exempts a path edit only when both recorded calls and reachable
  remote-pin roots are unchanged.
- ~~**The iOS-workspace skip**~~ — upstream's now (dropped at the 2026-09-30 merge).
- ~~**The per-package skip**~~ — upstream's now (dropped at the 2026-09-30 merge).

Re-apply note: keep the invariant "a manifest dependency change requires a lockfile diff only if
it changes what Package.resolved can record." If upstream ships an equivalent path-dependency
exemption, drop the remaining five fences and take upstream. Do not weaken pinned-dependency protection:
URL-pin changes without lockfile churn must keep failing. Re-run the repository policy check and a
scratch red/green URL-pin case after any merge that touches this script.

### 108. `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceDetailView.swift` — `supermux-mobile-workspace-tools`

The iOS Changes AND Files screens' mount point (architecture §7: workspace-detail entries). All
logic is fork-owned in `Packages/iOS/SupermuxMobileUI` (`SupermuxWorkspaceTools.swift` — the
`supermuxWorkspaceTools` view modifier, the capability gates, and
`SupermuxWorkspaceToolsMenuEntries` — plus `SupermuxChangesScreen` / `SupermuxDiffScreen` /
`SupermuxFileBrowserScreen` and their `SupermuxMobileKit` stores `SupermuxMobileChangesStore` /
`SupermuxMobileFileBrowserStore`). Two fences, same fence id:

- the `import SupermuxMobileUI` in the import block;
- `.supermuxWorkspaceTools(connection: supermuxWorkspaceSeam, workspaceID:
  workspace.rpcWorkspaceID.rawValue, workspaceName: workspace.name, showingChanges:
  $isSupermuxChangesSheetPresented, showingFiles: $isSupermuxFilesSheetPresented)` on the outer
  `Group` in `body`, BEFORE `.mobileConnectionRecoveryOverlay` — the outer Group so the sheets
  ride every detail branch (terminal, browser, Simulator, and generic Mac surfaces) and survive
  upstream reshuffles of the inner `.toolbar` blocks. IMPORTANT: pass
  `workspace.rpcWorkspaceID.rawValue`, NOT
  `workspace.id.rawValue`. With two+ Macs paired, aggregation scopes `workspace.id` to
  `<macID>\u{1F}<uuid>`, but the Mac's `changes.*`/`files.*` RPCs parse `workspace_id` as a bare
  UUID, so the scoped id fails every request with `invalid_params`. `rpcWorkspaceID` is the
  Mac-local (unscoped) id the host expects.

The modifier mounts only the two `.sheet`s presenting `SupermuxChangesScreen` /
`SupermuxFileBrowserScreen`; it adds no `ToolbarItem`s. The visible entries are
`SupermuxWorkspaceToolsMenuEntries` rows inside #228's workspace title menu, which flip the two
`@State` bindings (fenced under #228) that this modifier receives.
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
`SupermuxEditorErrorText`, `SupermuxFolderPickerPath`, `SupermuxUsageCountdown`,
`SupermuxSharedProjectIconStore`, and `SupermuxUnreadBadgeGradient`) carry inline
`/// lint:allow …` justifications. `SupermuxProjectIconImageCache.shared` carries the matching
singleton allowance because decoded icons must synchronously outlive every hosted row subtree. All
follow the lint's sanctioned-exception mechanism (precedent: `CmxPairingURLScheme`,
`AutoNamingAgentCatalog`).

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

Since the 2026-09-30 merge upstream's `splitTabBar(_:didChangeGeometry:)` defers publishing, the
notification and terminal reconcile into `geometryNotificationScheduler.schedule(zeroDelayPolicy:
.yieldOnce)` (deferred, latest-wins). The guard therefore also requires
`!geometryNotificationScheduler.isScheduled`: without it, X→Y→X inside one yield would dedupe the
final X against a stale cache while Y is still pending, and Y would win. The body is otherwise
unchanged. The regression test (#117) is `async` and awaits delivery with
`AppKitTestEventPump.waitUntil`/`drain()`; its assertions are unchanged.

Re-apply note: after an upstream merge, re-insert the fence as the first statement of
`splitTabBar(_:didChangeGeometry:)`, before the `deviceLayoutExternal` capture and the
`geometryNotificationScheduler.schedule` call. If
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
   Since the 2026-09-30 merge this sits inside upstream's `remoteValuesByKey = pinsFlagsToLocalValues
   ? [:] : Self.allFlags.reduce…` closure (re-indented); every `remoteValuesByKey[...] = value` write
   site still routes through the gate.
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

### 134–138, 482 (473–481/483–484 retired). Upstream conventions-lint debt — `lint-allow-upstream-debt`

Upstream paused its automatic CI on 2026-07-13 (all core workflows became `workflow_dispatch`-
only), so `scripts/lint-ios-package-conventions.sh` violations accumulated on upstream `main`
unchecked. The 0.64.20 merge imported five offenders. The 2026-08-24 merge imported twelve more
files: upstream's pixel-scroll and Network.framework callback locks plus stateless namespace types
for diagnostics, generic Mac surfaces, Simulator streaming, keychain policy, and Kimi config
resolution. The fork still dispatches the iOS conventions job, which fails on any ERROR.

Each site keeps the smallest possible `lint-allow-upstream-debt` fence. Put the reviewed
`lint:allow <rule>` justification on the begin line or immediately above the offending declaration
so it stays within the linter's two/three-line suppression window. Parameter-type findings keep the
fence inside the parameter list; whole namespace declarations close the fence immediately after the
type. Per #109's rule, `scripts/lint-namespace-types-baseline.txt` was not grown.

Re-apply note: preserve only enough fence to cover the upstream declaration, then run
`./scripts/lint-ios-package-conventions.sh` and expect "OK: no unjustified convention violations."
Drop a fence as soon as upstream fixes the design or adds its own reviewed allowance; this
fork-side grandfathering may only shrink.

The 2026-09-30 merge dropped #473–481 and #483–484 under exactly that rule: upstream converted
`DiagnosticBuildStamp` (now `DiagnosticReport.buildStamp(infoDictionary:fallbackName:)`),
`MacSurfaceTextDecoder`, `SimStreamTouchMapping`, `SimStreamProtocol`, `SimStreamWireCodec` and
`MacSurfaceGalleryFixtureBytes` to `Sendable` structs, deleted `MacSurfaceFileContext`, turned
`MobileKeychainAccessGroupPolicy` into `String.cmuxKeychainAccessGroup(from:)`, and added its own
`Carve-out:`/`lint:allow` justifications to the pixel-scroll and Tailscale callback locks. Surviving
fences: #134–138 and #482 (`KimiConfigLocationResolver`). Known lint ERROR after that merge, in
fork-owned code (no fence applies): `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/SupermuxNewWorktreeSheet.swift`
`enum SupermuxAgentEffortLabel` (a namespace enum, unchanged from pre-merge HEAD).

### 487. RETIRED (2026-09-30 upstream merge) — `remote-tab-context-disconnect`

Upstream now routes `.disconnectRemote` in `Workspace.splitTabBar(_:didRequestTabContextAction:for:inPane:)`
to the identical `disconnectRemoteConnection(clearConfiguration: false)`, so the fork fence was
dropped. Nothing to re-apply; if a future upstream regresses the “Disconnect SSH” menu item to
`@unknown default`, restore the one-line route with `clearConfiguration: false`.

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
3. `reload-supermux-profile-seed` — once the old same-tag app is gone, calls the seeder with `--target-bundle-id "$BUNDLE_ID"` and `--wait-for-exit` on the tagged executable
   path. Failure fails the reload (a silently signed-out dogfood build is the bug this exists to
   prevent). Since the 2026-09-30 merge upstream quits/kills the same-tag app earlier (before the
   staging swap, with `pkill -KILL` and a `launchctl bootout`) and deleted the old post-build "Tag
   mode: always terminate" block, so the fence sits after the swap and prune block, just before
   upstream's `BUILD_ONLY` / socket-lock check, and is additionally guarded by
   `"$BUILD_ONLY" -ne 1` (upstream's `--build-only` must not mutate the running tag's identity).
   The usage text lists upstream's `--prod-auth` continuation lines first, then the fork's block.
   `--supermux-profile` still sets `PROD_AUTH=1`, which also skips upstream's new shared-dev-backend
   requirement.

The seeder (fork-owned, no fence) copies from the `com.supermux.app` release install:
- the full UserDefaults domain (`defaults export | import`), then force-writes
  `cmux.auth.stackProjectID` to the production Stack project id (parsed out of
  `Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/AuthEnvironment.swift`; upstream moved it
  out of `Sources/Auth/` at the 2026-09-30 merge) so `MacAuthComposition.detectAuthProjectSwitch` does not
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

**#339** is the `mac-dogfood-supermux-profile` fence in `CLAUDE.md` — since the 2026-09-30 merge a
self-contained `##` section right after the #459 section (both follow upstream's "Verification and
isolation"): user-facing Mac dogfood builds must use `--supermux-profile`; agent-only builds keep
plain `--tag` + the `~/.secrets` auto-sign-in, and now need `CMUX_DEV_BACKEND_MODE=local` because
upstream's `reload.sh` otherwise requires cmuxterm-hq's `scripts/dev-backend.sh` (absent in this
checkout). Defaulting that mode in the fork is an open decision.

**To re-apply after an upstream merge:** re-add the three #338 fences around reload.sh's flag
declarations, arg parse, and the post-quit point (the seeder script itself is fork-owned and merges
clean), and re-insert the #339 doc section after the #459 section.

### 285–321, 325–327. Phone/Mac selection sync vs upstream's last-opened tab — `supermux-mobile-selection-sync`

The rows carry the per-file detail; this note records the cross-file interaction the 2026-09-30
upstream merge introduced. Upstream added a per-workspace "last opened tab" memory
(`MobileWorkspaceLastTabStore`, `pendingLastTabRestoreWorkspaceID`,
`restoreLocalBrowserTabIfRequested`, `recordLastOpened*StreamTab`) whose own doc says following the
Mac's focus on every open "is exactly the behavior this store exists to override" — while the fork
makes the Mac's focus authoritative. Both are kept: on open upstream restores the phone's last tab
and the fork pushes that tab to the Mac (`adoptRestoredTabAsSupermuxFocusedPanel(in:)` in the
`.restored` case, #286/#287); later Mac-driven focus still reconciles onto the phone and counts as an
explicit open (re-recording the remembered tab). In `WorkspaceDetailView` the `.task(id:)` order is
`refreshWorkspaceSelection()` → `applyFocusedPanelFromStore()` → `restoreLocalBrowserTabIfRequested()`
(#307). Upstream's demo/SSH rows are phone-served: the list reconcile is skipped while one is selected
and `enqueueSupermuxSelectionSync` ignores them (the Mac has no such rows). Known rough edge: a
restored browser stream's first start can be deferred by the fork gate (#325) until the focus RPC
returns. **OPEN DECISION:** (A) keep as merged (phone memory wins on open, Mac follows); (B) disable
upstream's restore when the host advertises `selectionSync` (Mac-authoritative, as before the
merge). Needs dogfood — watch for flip-flop between the restored tab and the Mac-focused pane.

### 407–412. Simulator stream presentation lifecycle — `simulator-stream-presentation-lifecycle`

**Symptom:** open a Simulator pane from the phone, switch to another pane/workspace tab, then return.
The phone loses the stream and the Mac Simulator pane can fall onto its connection-failure screen.

**Cause:** Simulator teardown had two independent owners. Selection actions deactivated and queued a
stop, while the conditionally mounted pane also queued an unconditional stop from `onDisappear`.
SwiftUI is free to unmount an old detail after its replacement appears; task scheduling could also
let either stale stop run after the same panel was active again. The per-panel RPC queue serialized
those operations but preserved the wrong order, so a delayed old teardown could release the new
session's Mac ownership and disable its framebuffer.

Keep the fix as one lifecycle path:

1. `MobileSimulatorStreamStore` records a stable presentation UUID per `(workspace, panel)`. The
   final registered presentation owns deactivation; an overlapping old view cannot clear a newer
   view for the same panel. If the old view disappears first, the replacement registration restores
   the local selection and reports that the caller must restart. Explicit deactivate, panel switch,
   discovery removal, and close all clear registrations so the later `onDisappear` is a no-op.
2. `SimulatorStreamPresentationLifecycleModifier` owns registration plus start/stop dispatch for one
   mounted view. It may restore only when the phone's selected workspace and generic focused panel
   still exactly identify this Simulator; it always registers lifecycle identity so a later
   authoritative transition can still tear the view down cleanly. Its store read stays an OPTIONAL
   environment value (hosts without the store, e.g. upstream's lifecycle tests, render plain content).
3. `WorkspaceDetailView+Surfaces.swift` keeps the fenced `CMUXMobileCore` import for
   `MobileWorkspaceFocusedPanel`, then mounts that modifier instead of keeping a second raw
   `onDisappear` stop path.
4. `MobileShellComposite.stopMobileSimulatorStream` re-checks the active selection inside the
   serialized operation. A stop queued by an old presentation yields if the exact panel is active
   again. Do **not** put that gate in `performMobileSimulatorStreamStop`: backgrounding intentionally
   keeps selections for foreground restart but must still stop every Mac session unconditionally.

Re-apply all six rows together. The two store tests pin both SwiftUI lifecycle orders, and the
composite regression pins the task-order race (reactivated selection skips the stale stop, then a
real deactivation still stops). Run:

```bash
swift test --package-path Packages/iOS/CmuxMobileShell \
  --filter MobileSimulatorStreamStoreTests
swift test --package-path Packages/iOS/CmuxMobileShell \
  --filter MobileShellCompositeSimulatorStreamTests
```

Then verify on a real phone: open Simulator, switch to a terminal or another workspace, return, and
confirm the same pane resumes without either the phone stream or Mac Simulator connection failing.

### 413–432. Claude harness pane — `claude-harness-*`

The dedicated Claude Code harness pane (`PanelType.claudeHarness`): a WKWebView-hosted chat surface
driving the Claude CLI over stream-json stdio. All logic lives in fork-owned files — the
SupermuxKit engine under `Packages/SupermuxKit/Sources/SupermuxKit/ClaudeHarness/`, the app glue
under `Sources/Supermux/Harness/`, the web app in `harness-web/` (built by
`scripts/supermux-build-harness-web.sh` into the committed `Resources/supermux-harness/index.html`).
The fences are thin switch arms; to re-apply after a merge:

1. `Panel.swift`: add `case claudeHarness` at the end of `PanelType` plus a lowercase decode
   fallback block before the `DecodingError` throw (#413).
2. `SurfaceKind.swift`: additive `public static let claudeHarness = SurfaceKind(rawValue:
   "claudeHarness")` — the raw string is frozen; the package test pins it (#414–#415).
3. Every exhaustive `switch panel.panelType` / `switch snapshot.type` gains a `.claudeHarness` arm:
   render `SupermuxHarnessPanelView` + drop-target `true` (#416), canvas icon `sparkles` (#417),
   sidebar kind `.unknown` (#418), palette label/keywords (#419), closed-history title (#420),
   lifecycle kind `claude_harness` (#421), surface-navigation raw value (#422), file-drop `nil`
   (#423), global-search `.title` (#424), layout-capture unsupported (#425), and the open mobile
   inventory wire kind `claudeHarness` (#485).
4. `Workspace.swift` (#426): declare `var claudeHarnessSnapshot: SessionSupermuxHarnessPanelSnapshot?
   = nil` beside the other per-kind locals; snapshot arm calls
   `supermuxHarnessSessionSnapshot(for:)` and nils the other locals; pass
   `claudeHarness: claudeHarnessSnapshot` in the `SessionPanelSnapshot` init; restore arm passes
   `!restoresUntrustedSavedDirectory` to `restoreSupermuxHarnessPanel` so saved remote paths never
   become local Claude cwd values; in `attachDetachedSurface` re-install the
   subscription via `installSupermuxHarnessPanelSubscription` after `updateWorkspaceId`, and in the
   createTab-failure rollback clear `onDisplayStateChanged`.
5. `Workspace+PanelLifecycle.swift` (#427): one `discardSupermuxHarnessPanelSubscription` call next
   to the agent-session discard.
6. `SessionPersistence.swift` (#428): optional `var claudeHarness:
   SessionSupermuxHarnessPanelSnapshot? = nil` on `SessionPanelSnapshot`.
7. `Workspace+SidebarDirectories.swift` (#429): in
   `restoresLegacyRemoteDirectoryWithoutProvenance`, return `true` when `snapshot.claudeHarness`
   is non-nil (before the agent-session fallback).
8. `cmuxApp.swift` (#430): mount `SupermuxHarnessDebugMenuButtons()` inside the `#if DEBUG`
   `CommandMenu("Debug")`, after the Iroh/AgentSession buttons.
9. pbxproj (#431–#432): 4 entries per file with the reserved ids listed in the rows; re-run
   `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj`, `./scripts/check-pbxproj.sh`,
   and `./scripts/lint-pbxproj-test-wiring.sh`.
10. Keep `MobileSurfaceKindMappingTests.canonicalKinds` exhaustive with `claudeHarness` (#486), so
    a new upstream panel type cannot silently drop the fork surface from mobile state sync.

Since the 2026-09-30 merge upstream's new `PanelType.cloudVPNSetup` / `SurfaceKind.cloudVPNSetup`
sits beside the fork's `claudeHarness` in every one of those switches (upstream's arm first, then the
fenced fork arm); in the mobile mapping and its test the `PanelType` count still balances. Two more
re-homes from that merge: #465's `PaneDropTargetRepresentable` fences now live in upstream's new
`Sources/PaneDropTargetRepresentable.swift` (#499), and the top-level CLI `usage()` help line naming
`claude-harness` moved to `CLI/CMUXCLI+TaskHelp.swift` (#506, unfenced); the per-command
`new-surface` help strings stay in `CLI/cmux.swift`. The #433 nil-`bonsplitAction` group also lists
upstream's `.newCloudWorkspace, .newCloudMachine`.

Copy keys: every `supermux.harness.*` string in `Sources/Supermux/Harness/SupermuxHarnessCopy.swift`
mirrors `harness-web/src/copyKeys.ts`; regenerate localizations with the loc scripts. Rebuild the
web shell with `bun run harness-web:build` and commit the artifact.

### 443–445. Claude harness branch chip + unread indicator

Two user-reported gaps, both caused by upstream keying pane behavior on `TerminalPanel`.

**Branch chip (443–444).** The workspace-tab / sidebar branch comes from
`panelGitBranches`, written only by `SidebarGitMetadataService`'s probe. Every site that
schedules that probe walks `TerminalPanel`s, and the service's watcher restart gates on
`host.hasTerminalPanel(...)`. So a workspace whose only pane is a harness pane never got a probe
and rendered no branch. Fix, entirely by reusing the existing probe (no new branch resolution, no
shelling out): the fork-owned `Workspace.scheduleSupermuxHarnessGitMetadataProbe(panelId:reason:)`
in `Sources/Supermux/Harness/Workspace+SupermuxHarness.swift` calls the same
`scheduleInitialWorkspaceGitMetadataRefreshIfPossible` upstream calls for a terminal, and is
invoked from both harness creation paths (fork-owned, unfenced). Two upstream hooks remain:

1. `TabManager.swift` (#443): after upstream's restore-sweep `TerminalPanel` loop, add
   `workspace.scheduleSupermuxHarnessGitMetadataProbes(reason: "harnessSessionRestore")`.
2. `TabManager+SidebarGitHosting.swift` (#444): in `hasTerminalPanel`, return `true` for a
   `SupermuxHarnessPanel` too.

Terminal panes are untouched on both paths.

**Unread indicator (445).** Harness panes never showed an unread mark because
`PanelContentView`'s `.claudeHarness` arm did not forward `hasUnreadNotification` (upstream's
outline ring is drawn by `GhosttyTerminalView`'s `notificationRingLayer`, which only terminals
mount). The arm now forwards it, and the pane renders the fork's own treatment —
`SupermuxHarnessUnreadIndicator` (`Sources/Supermux/Harness/`), a short glowing accent tick on the
pane's leading edge that breathes slowly — instead of the outline the user called ugly. It honors
the same `unreadPaneRing` setting and the same `workspaceAttentionColor` the terminal ring uses.
The upstream ring renderer is deliberately NOT modified: it is on a typing-latency-sensitive path,
and scoping the new treatment to the harness pane keeps the diff to one argument.

### 433–442. Claude harness entrypoints — `claude-harness-builtin-action` etc.

User-facing entrypoints for the harness pane, all routed through the one shared action id
`cmux.newClaudeHarness` (Simulator pattern). The fork-owned glue (palette contribution/handler,
`performNewClaudeHarnessPaneFromMenu`, `performConfiguredNewClaudeHarnessAction`,
`performNewClaudeHarnessShortcutAction`) lives in
`Sources/Supermux/Harness/SupermuxHarnessCommandPaletteIntegration.swift` (pbxproj ids
`50BE0001…0132`/`…0133` under #432). To re-apply after a merge:

1. `CmuxSurfaceTabBarBuiltInAction.swift` (#433): `case newClaudeHarness = "cmux.newClaudeHarness"`,
   the alias block in `init?(configID:)` (`claude-harness`, `claudeharness`, `claude`, `harness`),
   metadata arm (`supermux.harness.command.newPane.title` + keywords), `sparkles` default icon,
   add the case to the nil `bonsplitAction` group, and a `shortcutAction` arm returning
   `.supermuxNewClaudeHarness`.
   `AppDelegate+NewWorkspaceContextMenu.swift` (#510): a `.newClaudeHarness` arm returning `true`
   in `isBuiltInActionAvailableInNewWorkspaceMenu` (always available, like the palette). Both
   switches are exhaustive, so a missing arm is a compile error, not a silent gap.
   `TerminalCopyAction.swift` (#600): a `.newClaudeHarness` arm returning `nil` in upstream's
   `terminalCopyAction` switch (also exhaustive).
2. `Workspace.swift` (#434): `.newClaudeHarness` arm in `executeSurfaceTabBarCommandButton`
   calling `newSupermuxHarnessSurface(inPane: pane, focus: true)`.
3. `AppDelegate.swift` (#435): `.newClaudeHarness` arm in `executeConfiguredCmuxAction` delegating
   to `performConfiguredNewClaudeHarnessAction`; shortcut dispatch block for
   `.supermuxNewClaudeHarness` immediately after the run-toggle dispatch (guard `isARepeat`,
   beep on failure, return true).
4. `ContentView.swift` (#436): `contributions.append(.newClaudeHarnessPane)` after the Simulator
   contribution and `registry.registerNewClaudeHarnessPane(tabManager:windowId:)` beside
   `registerNewSimulatorPane`. `ContentView+AgentChatCommandPalette.swift` (#436b): palette-id →
   config-id map case.
5. `cmuxApp.swift` (#437): File menu `splitCommandButton` "New Claude Pane" with
   `menuShortcut(for: .supermuxNewClaudeHarness)` after the Simulator menu item.
6. `CmuxConfig.swift` (#438): `static let newClaudeHarness = actionReference(...)` beside
   `newSimulator`.
7. Shortcut double-enum (#439–#440): app-target case/label/default (⌃⌘A) in
   `KeyboardShortcutSettings.swift`; package `case supermuxNewClaudeHarness` in
   `ShortcutAction.swift` plus arms inside the existing `supermux-shortcut-defaults` /
   `-display-names` / `-groups` fences; Dock routing exclusion inside `run-shortcut-dock-routing`
   (#212); drift tests in `cmuxTests/KeyboardShortcutContextTests.swift` (#66) and
   `SupermuxShortcutActionTests.swift` (#68) each carry the sixth row.
8. Socket (#441–#441c): `claudeharness` token in `v2PanelType(rawToken:)`; `surface.create` arm;
   split guards in both `controlSurfaceSplit` and `controlPaneCreate` extended to
   `|| panelType == .claudeHarness`; the per-command `new-surface` help in `CLI/cmux.swift` and the top-level `usage()` in `CLI/CMUXCLI+TaskHelp.swift` (upstream moved `usage()` there at the 2026-09-30 merge; #506) list `claude-harness`.
9. Docs (#442) and schema (#14): shortcut row in `web/data/cmux-shortcuts.ts` (surfaces section)
   and the `supermuxNewClaudeHarness` enum id in `web/data/cmux.schema.json`.

### 447–449. Harness web CI — `harness-web-ci`

The harness web app is fork-owned (`harness-web/`) but its generated, committed single-file bundle
ships inside the macOS app at `Resources/supermux-harness/index.html`. Keep one independent
`harness_web` route rather than folding it into the broad `web` area: ordinary website and diff
webview changes must not pay for the harness suite, while every harness source/test/package/lock
change, the committed bundle, `scripts/supermux-build-harness-web.sh`, and the root `package.json`
script registry must run it. Do not add the root `bun.lock`: the harness installs from
`harness-web/bun.lock` and does not consume the root dependency graph. The new predicate is additive;
leave every existing `web`, `agent_session_web`, and `macos` decision unchanged. In particular, the
committed resource remains app-affecting under the existing macOS classifier.

In `.github/workflows/ci.yml`, preserve all of these together (since the 2026-09-30 merge upstream
moved macOS jobs to `ci-macos.yml`, web to `ci-web.yml` and Linux guards to `ci-guards.yml`, but the
`changes` router, the fork's `harness-web` job and the gates stay in `ci.yml`):

1. Export `harness_web` from `changes` as `harness_web: ${{ steps.detect.outputs.harness_web ||
   'false' }}` — upstream has several early-exit emit blocks that never write it, and the detector
   emits `harness_web=true` only when routed (keeping upstream's exact-output assertions valid) — and
   echo `harness_web=true` from `emit_all_areas`, so `workflow_dispatch`, empty diffs and diff
   failures run the lane. Router-only edits no longer run it: upstream now skips product-area CI for
   a routing-policy-only PR.
2. The routed Linux `harness-web` job uses the repository's pinned
   `oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6` action with Bun `1.3.14`, installs
   `harness-web/bun.lock` frozen, runs `bun run typecheck` and the full `bun run test`, then invokes
   the root `bun run harness-web:build` production path and fails on any diff in
   `Resources/supermux-harness/index.html`.
3. Add `harness-web` as a direct need of `linux-preflight`, `tests`, `ci-status` **and
   `macos-admission-gate`** (upstream's `test_macos_admission_gate_needs_every_fast_linux_only_job`
   derives the gate's needs from every fast Linux-only job). The routed/unrouted checks in the `tests`
   aggregate and `linux-preflight` are standalone fenced blocks (before `if bad:` in preflight) that
   read `needs.get("harness-web", …)`: a routed skip fails, an unrouted skip passes, a failure always
   fails. They deliberately do NOT go through upstream's `allowed_routed`/`routed_outputs` dicts, so
   upstream's fixtures lacking the key keep passing; upstream's "routes:" print line stays untouched.
   `linux-preflight` now skips when `macos=false`, so the stable `tests` gate is what catches a
   routed harness skip. The job uses upstream's standard Linux `runs-on` expression (non-manaflow
   owners get `ubuntu-24.04`), `permissions: contents: read` and `persist-credentials: false`.

The tests execute the classifier and the embedded Python gate scripts through the workflow's
existing extraction helpers. Keep the positive cases separate from website-only negatives, and keep
the behavior checks that a routed harness skip fails Linux preflight and a failed harness job fails
the stable aggregate. Do not replace those with source grep assertions; only the established
workflow-shape helper is used to pin the action version and exact validation commands.

### 450. Harness transport contract tests

`cmuxTests/SupermuxHarnessNativeEventTransportTests.swift` is a fork-owned Swift Testing suite.
Keep its `50BE0001…013E` file reference and `…013F` sources-build entry in the four normal pbxproj
locations. The suite pins the native half of the retained-WKWebView contract: events remain
backlogged through one in-flight batch until the exact epoch/sequence acknowledgement arrives,
failed evaluations retry identically, navigation re-sequences every unacknowledged event in order,
batches obey both count and encoded-byte caps, backlog accounting remains bounded, and stale host
generations can neither attach nor release the retained view.

### 451. Focused-pane notification regression test

`cmuxTests/SupermuxFocusedPaneNotificationTests.swift` is a fork-owned Swift Testing suite. Keep its
`50BE0001…0140` file reference and `…0141` sources-build entry in the four normal pbxproj locations.
The test drives the real `TerminalNotificationStore` against the selected workspace's focused panel
with the app-focus seam forced active. The notification may remain in chronological history, but it
must be read, carry no pane flash, contribute no unread/badge/outline state, create no focused-read
indicator, and invoke no delivered alert or sound. The suppressed local path may still carry an
explicit custom notification command, which remains automation rather than user-facing alerting.

### 452–453. Focused-pane notification admission

`Sources/Supermux/SupermuxFocusedPaneNotificationPolicy.swift` owns the pure decision. Treat a target
as already visible only when it has an exact non-nil surface id and the store's existing live
focus/external-delivery gate says that target is focused in the active main window. Targetless
workspace notifications must keep their existing behavior rather than being guessed into a pane.
For an already-visible target, preserve `record` and `command`, but force `markUnread`,
`reorderWorkspace`, `desktop`, `sound`, and `paneFlash` off. The notification therefore stays in
history as read while every user-facing attention surface remains absent; an explicitly configured
custom command still runs.

In `TerminalNotificationStore.applyNotification`, keep the `focused-pane-notification-suppression`
fence immediately after final live-owner resolution and the existing `shouldSuppressExternalDelivery`
calculation. That placement is load-bearing: async policy hooks and cross-workspace surface moves may
change the live owner before completion, so applying focus suppression from the request's initial
`isFocusedPanel` snapshot can suppress the wrong pane. Shadow the resolved `effects` once there so
recording, unread indexes, sidebar/Dock/mobile badges, pane ring/flash, native alert/sound, and reorder
all consume one policy result. The #332 direct APNs fence must call the same exact-target decision and
skip visible forwarding for that focused pane; non-focused targets still bypass broad presence/away
heuristics and forward normally.

### 454–457. Focused-notification fixture updates

These are test-only adaptations to the new admission invariant:

- `NotificationAndMenuBarTests` now asserts a focused notification is read, produces no delivered
  alert or sound, and keeps the command effect. Its separate focused-read-indicator lifecycle test
  seeds that legacy indicator explicitly after creating unread with app focus off.
- `TerminalAndGhosttyTests` creates unread with the app-focus seam off, then restores focus before the
  mouse/key interaction, so those tests continue covering exact direct-interaction dismissal rather
  than focused-notification admission.
- `WorkspaceUnitTests` does the same around the competing-unread pane-navigation fixture.
- `AgentNotificationMoveRaceTests` expects the immediate focused relay to be read with no focused-read
  indicator, then retains its original source-confinement assertions after the panel moves.

Keep each fence narrow around the fixture/expectation delta; the surrounding upstream test remains
unchanged. `cmuxTests/SupermuxFocusedPaneNotificationTests.swift` (#451) is the primary exact repro.

### 458. Focused-pane notification documentation

Keep the fenced paragraph in `docs/notifications.md` immediately before the existing
`notifications.suppressOnlyFocusedSurface` withdraw setting. The new paragraph describes admission
for an already-focused exact pane; the existing section describes later auto-withdrawal of a banner
that was delivered while not focused. They are related but distinct and must not be collapsed into a
setting claim: focused-pane admission is unconditional, while narrow auto-withdraw remains opt-in.

### 459–460. Direct tagged-build launch links

Tagged Debug apps already register the unique callback scheme `cmux-dev-<normalized-tag>`. Use that
native LaunchServices identity for dogfood handoff instead of the retired localhost Tag Opener:

```markdown
[Open <tag>](cmux-dev-<tag>://launch)
```

The `launch` host is deliberately inert: opening the URL is enough for LaunchServices to start or
activate the owning tagged app, while the app ignores the non-auth route. Never use `auth-callback`
for this purpose because that route is reserved for Stack sign-in. A build made with `--launch` is
registered automatically. After a build-only reload, run the system `lsregister -f` tool against the
exact `App path:` printed by `reload.sh` before handing off the link; registration must not require
launching a browser or a local server.

Keep the fenced instructions in `CLAUDE.md` and the `cmux-dev-workflow` tagged-build reference in
lockstep. Do not restore `http://127.0.0.1:17320/<tag>`: without a separately installed Tag Opener it
opens the embedded browser and fails, which is exactly the handoff regression these touchpoints
remove. The existing prohibition on `file://`, raw `.app`/DerivedData paths, and `/tmp` build links in
chat remains unchanged.

Since the 2026-09-30 merge the `CLAUDE.md` fence is a self-contained `##` section ("Supermux: tagged
build handoff links") after upstream's "Verification and isolation" (upstream's CLAUDE.md became a
short index). In the skill reference the fork's "## Direct launch links" section replaces upstream's
one-line "A normal reload.sh build prints an App path… Never put file://" paragraph at the end of
"Compile-only checks", and adds that a `--build-only` run leaves nothing to link.

### 461, 512. Claude harness Dock admission

Keep the two narrow `claude-harness-dock-admission` fences in
`Sources/AppDelegate+DockSurfaceMove.swift` inside `canMoveSurfaceIntoDock(_:)`. A workspace-owned
Claude harness pane must return `false` before detach, and a pre-existing Dock-owned harness pane must
also be rejected as a source. Dock does not retain the harness controller's event subscription,
bridge routing, or persistence state, so admission is disabled until Dock implements that complete
ownership contract.

The regression test `harnessSurfaceCannotMoveIntoDock` in `cmuxTests/DockPortalReconcileTests.swift`
(#512) is fenced as a whole function under `claude-harness-dock-admission-test`. If upstream reshapes
its sibling Dock tests, follow their setup (today `workspace.requiredDockSplitForTesting`, since
`workspace.dockSplit` became Optional) and keep the three assertions: `canMoveSurfaceIntoDock` false,
`moveSurfaceIntoDock` false, and the harness panel still owned by the workspace.

### 462. iOS release-lane identity coverage

Keep the `ios-appstore-lane-identity` fences in `tests/test_ios_appstore_lane_identity.py` around only
the Supermux-specific fake-tool support and assertions: capture `SUPERMUX_APP_BUNDLE_ID`, provide the
fake `otool` used to inspect embedded frameworks, assert the beta and App Store bundle IDs, and reject
the retired `com.cmuxterm.app` identity. The surrounding upstream release-lane harness remains
unchanged. Since the 2026-09-30 merge upstream's harness parses and checks its own
`CMUX_APP_BUNDLE_IDENTIFIER`; the fork fences are purely additive on top of it
(`bundle_id = setting("SUPERMUX_APP_BUNDLE_ID=") or bundle_id` after upstream's line, then the
separate fenced Supermux checks).

### 463. Remote-daemon timeout test queues

In `RemoteDaemonRPCClientTimeoutIsolationTests.swift`, create one dedicated serial callback queue per
PTY attachment and pass it to `attachPTY` (since the 2026-10-01 upstream merge only the first test
attaches a PTY; upstream's rewritten cancellation-write test has none). Keep the declarations and arguments inside
`remote-daemon-timeout-isolation-event-queues` fences. Do not use `.global()`: unrelated test work can
starve those callback semaphores and make the timeout-isolation tests flaky without exercising a
product failure.

### 464. Harness web root build command

Keep the additive `harness-web:build` script in the root `package.json`, invoking
`scripts/supermux-build-harness-web.sh`. JSON cannot carry a fence, so this touchpoint is registered as
`unfenced`. The script is the shared production bundle path used by developers and the harness-web CI
freshness check; do not duplicate the bundler command in CI.

### 413, 413b. Pull-request glyph arrowhead — `pull-request-glyph-arrowhead`

**Symptom:** the open-PR icon does not read as a pull request. It looks like a branch diagram, or
just "weird" — most visibly once the PR badge went icon-only (no `#1234` beside it) and the glyph
had to carry the meaning alone.

**Cause:** the glyph was missing its arrowhead. GitHub's `git-pull-request` octicon is two SEPARATE
branch strokes with a left-pointing arrow flying between them — the arrow is literally the "pull".
Upstream drew the two branches joined by one continuous connector and no arrow, which is the
`git-branch` icon. It also cut the top-right corner with a 45° chamfer (`(9.4,3) → (11,4.6)`) where
every other corner in the set is round; at 12–13pt that diagonal is a couple of stair-stepped pixels.

The corrected 13-unit geometry, shared by all four copies:

```
left branch:   move(3.0, 4.8) → line(3.0, 9.2)
right branch:  move(11.0, 9.2) → line(11.0, 4.6)
               → arc(tangent1: (11.0, 3.0), tangent2: (6.6, 3.0), radius: 1.6)
               → line(6.6, 3.0)
arrowhead:     move(8.0, 1.6) → line(6.6, 3.0) → line(8.0, 4.4)
nodes:         (3,3) (3,11) (11,11)      [unchanged]
```

The merged glyph is unchanged — it was already correct.

Four files carry this geometry, and they are copies on purpose (each side of the SwiftUI/AppKit and
macOS/iOS splits owns its own path). Re-apply to all four or the app draws two different PR icons:

| File | Kind |
|---|---|
| `Packages/SupermuxKit/…/UI/SupermuxPullRequestBadgeView.swift` | fork, SwiftUI — has named `arrowTipX`/`arrowBarb` constants |
| `Packages/iOS/SupermuxMobileUI/…/SupermuxMobilePullRequestGlyph.swift` | fork, SwiftUI (phone twin) |
| `Sources/ContentView.swift` (`PullRequestOpenIcon`) | upstream, SwiftUI — **fenced** |
| `Sources/Sidebar/…/Cells/SidebarWorkspaceRowSlotViews.swift` | upstream, AppKit `NSBezierPath` — **fenced** |

The AppKit copy uses `appendArc(from:to:radius:)` for the corner. That view sets `isFlipped = true`,
so the y-down coordinates port across unchanged — do not flip them.

Verify by eye at real size, not just zoomed: the arrow has to survive 12pt. Render the glyph into
its chip at 13/21 (phone) and 12/18 (desktop) and confirm the arrowhead is still legible and its
barbs do not collide with the left branch's node.

### 489–495. Supermux release mobile identity — `supermux-release-mobile-identity`

Keep the exact release pair explicit and fail-closed:

1. `CmxPairingURLScheme.swift` classifies only `cmux-ios-com.supermux.ios` as the fork's additional
   release scheme. Do not broaden this to arbitrary foreign bundle ids. Its shared-core test requires
   the exact scheme and release classification.
2. `MobileMacBuildCompatibilityPolicy.swift` admits only `mac:com.supermux.app` beside upstream's
   Stable/Nightly namespaces under `.official`. Its iOS shell test drives the authenticated-host
   policy with a locally authorized Tailscale route.
3. `MobileIOSPairingTargetStore.swift` receives the Mac bundle id as an injectable constructor value.
   When the official tag and exact `com.supermux.app` bundle agree, its sole pairing target is
   `com.supermux.ios`; upstream cmux and tagged DEV selection remain unchanged. The app-target test
   requires that default. Push targeting is no longer the Mac's job: upstream #13741 removed
   `pushTargetNamespace`, and `PhonePushClient` sends `targetBundleIdentifier: nil` so the server fans
   pushes out to every iOS build registered for the account. Supermux phone pushes therefore depend
   on that fan-out including `com.supermux.ios` device tokens (`web/app/api/notifications/push/route.ts`,
   `web/services/apns/routePolicy.ts`) or on the fork's direct push path (#332).
4. `MobilePairingModel.swift` maps that target to the localized `supermux.mobile.pairing.target`
   product name (en+ja in `Resources/Localizable.xcstrings`, covered by #4b).
5. `ios/Config/Release.xcconfig` must not restore the retired shared `CMUX_IOS_URL_SCHEME = cmux-ios`
   override; inherit the exact-bundle scheme from `Shared.xcconfig`. The fork-owned
   `scripts/supermux-ios-release.sh` (#372) rejects a built app unless its registered scheme is
   `cmux-ios-com.supermux.ios`.

Together these cover the real Tailscale QR failure introduced when upstream made app namespaces
exact: without any one boundary, the fixed release pair can be rejected as build-incompatible, route
its QR to cmux, or (before #13741) publish pushes to the wrong iOS bundle.

### 496–497. Socket override inherited from another bundle — `socket-override-foreign-bundle`

`scripts/supermux-release.sh` bakes `CMUX_ALLOW_SOCKET_OVERRIDE=1` into the release app's
LSEnvironment (isolated `/tmp/supermux.sock`), and every terminal it spawns carries that flag plus
`CMUX_SOCKET_PATH=/tmp/supermux.sock` and `CMUX_BUNDLE_ID=com.supermux.app`. A tagged dev build
opened from one of those terminals (the `cmux-dev-<tag>://launch` link, `open`) inherits all three
and, upstream, honors the override: it tries to listen on the release app's socket (never succeeds)
and its bundled CLI — the Changes panel's per-file diff opener and Open Diff Viewer — connects to the
release app instead ("Access denied" / "Workspace not found").

Re-apply: in `SocketControlSettings.shouldHonorSocketPathOverride`, move the
`inheritedBundleIdentifierConflicts(...)` early return ABOVE the `CMUX_ALLOW_SOCKET_OVERRIDE` early
return (fenced `socket-override-foreign-bundle`). `reload.sh` launches keep working because they set
`CMUX_BUNDLE_ID` to the tagged bundle id. The two fenced tests in `SocketControlSettingsTests.swift`
(`socket-override-foreign-bundle-test`) pin both directions.

### 511. iOS 27 SDK without `toolbarMinimizeBehavior` — `ios27-sdk-no-toolbar-minimize`

Upstream's `mobilePinnedNavigationBar()` gates the native iOS 27 opt-out
(`.toolbarMinimizeBehavior(.never, for: .navigationBar)`) on `#if compiler(>=6.4)`. Xcode 27.0
(27A266a) ships Swift 6.4 but its iOS 27 SDK only has `tabBarMinimizeBehavior` /
`windowMinimizeBehavior`, so that branch does not compile on this machine; upstream CI (Xcode 26)
never reaches it. Re-apply: append `&& SUPERMUX_IOS27_TOOLBAR_MINIMIZE` to that `#if` inside the
fence (the flag is deliberately never defined, so the UIKit `PinnedNavigationBarApplier` path always
runs). This is a temporary toolchain workaround: once the SDK exposes `toolbarMinimizeBehavior(_:for:)`
(or upstream changes the gate), delete the fence, take upstream's line, and retire #511.

### 513–514. Supermux release Cloud override — `supermux-release-cloud-override`

Why: upstream gates Cloud Machines — and with it Mac-to-Mac **My Devices** — on the PostHog flag
`cloud-machines-enabled-release`, and only lets Nightly/Debug identities override it locally. The
Supermux release app (`com.supermux.app`) is not in that rollout, so the Cloud tab never appeared.
Re-apply: (a) in `CmuxFeatureFlagOverrideCapability`, add the `isSupermuxRelease` stored property
and prefix `allowsCloudOverride` with `isSupermuxRelease ||`; (b) in `CmuxFeatureFlags.init`, just
before the `if let remoteFlagLoader` branch, write `true` to
`overrideDefaultsKey(for: cloudMachinesFlag.key)` when `isSupermuxRelease` and no value is stored.
Retire both if upstream ever ships the flag on for everyone.

### 515. Release SIL type mismatch on `ghostty_surface_clear_selection` — `release-clear-selection-seam`

Upstream's lifecycle-cancel path in `sendSyntheticGhosttyMouseRelease` (`Sources/GhosttyTerminalView.swift`)
calls the GhosttyKit-header `ghostty_surface_clear_selection`, while
`GhosttyRuntimeCInterop.swift` in `CmuxTerminalCore` still declares the same symbol with
`@_silgen_name` and a non-optional `ghostty_surface_t`. Debug builds link fine; the Release build
crashes swift-frontend in `MandatorySILLinker` with `SILFunction type mismatch`. Re-apply: route that
one call through `GhosttyRuntimeCInterop.clearSelection(surface)` like every other call site in the
file. Retire this row once upstream drops the `@_silgen_name` shim (the header now exports the
symbol) or stops calling the header function directly — then take upstream's line.

### 517–522. Remote Macs foundation (F1) — `device-link-supermux-events`, `device-mirror-export-filter`, `supermux-release-devices-defaults`, `supermux-devices-socket`

Design: `plans/supermux-remote-workspaces/DESIGN.md`; API for consumers:
`plans/supermux-remote-workspaces/FOUNDATION-API.md`. All logic lives in `Sources/Supermux/Devices/` and
`Packages/SupermuxKit/Sources/SupermuxKit/Devices/`; the upstream edits only call into it.

- **#517 `Sources/Devices/DeviceLink.swift`.** (1) Replace the `static let eventTopics` line with upstream's
  literal wrapped as `Set<String>([…]).union(SupermuxDeviceLinkEvents.topics)` (keep every upstream topic;
  upstream tests only assert `contains`). (2) In `handle(_:)`, insert before `default:` the arm
  `case let topic where SupermuxDeviceLinkEvents.topics.contains(topic): SupermuxDeviceLinkEvents.receive(instance: instance, topic: topic, payload: envelope.payloadJSON)`.
  (3) In `startConnect`'s success path, after `self.onNotificationFeedChange?()`, call
  `SupermuxDeviceLinkEvents.linkConnected(instance: self.instance)` — it must stay AFTER the post-connect
  `performFetch`, because consumers read it as "records fetched since this connect". (4) In
  `tearDownClient(notify:)`, right after upstream's `if notify { terminalEvents.broadcast(.linkLost) }`, add
  `if notify { SupermuxDeviceLinkEvents.linkLost(instance: instance) }`. If upstream renames these methods,
  put the hooks where the link becomes connected-with-fetched-state and where a connected link is torn down.
- **#518 `Sources/Mobile/MobileStateSync.swift`.** In `buildRows`, first line inside
  `for workspace in tabs where seenWorkspaceIDs.insert(workspace.id).inserted {`:
  `if SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) { continue }`. This is the loop guard — never
  drop it while device mirrors exist, or two Macs with auto-mirror re-export each other's mirrors forever.
- **#519 `Sources/TerminalController+MobileWorkspaceList.swift`.** In `v2MobileWorkspaceList`: (a) the
  single-window branch's `} ?? tabManager.tabs` becomes
  `} ?? tabManager.tabs.filter { !SupermuxDeviceWorkspaceIndex.isDeviceMirror($0) }`; (b) the all-windows loop
  body starts with `if SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) { continue }`. The notification
  feed needs nothing: upstream's `isMirroredFromDevice` already drops `.deviceMac` rows.
- **#520 `Sources/FeatureFlags.swift`.** Immediately after `// SUPERMUX:end supermux-release-cloud-override`
  (#514), add `SupermuxDevicesDefaults.seedReleaseDefaultsIfNeeded(isSupermuxRelease: overrideCapability.isSupermuxRelease, defaults: defaults)`.
  Retire together with #513/#514 if upstream ever turns Devices on for everyone.
- **#521 `Sources/TerminalController+ControlSocketAsync.swift`.** In
  `processV2CommandUsingSocketExecutionPolicyAsync`, first statement inside the
  `withSocketCommandPolicyAsync { … }` body: `if SupermuxDevicesSocketCommands.handles(authorizedRequest.method) { let result = await SupermuxDevicesSocketCommands.handle(method: authorizedRequest.method, params: authorizedRequest.params); return Self.v2Encoder.response(id: authorizedRequest.id, result) }`.
  It must stay on the async lane (the handler awaits RPCs and opens workspaces on the main actor without
  blocking it); never move it into the synchronous main-actor switch.
- **#522 `cmux.xcodeproj/project.pbxproj`.** Re-add the 14 `Devices/…` file references, build files, Supermux
  group children and cmux Sources-phase entries with the `50BE0004…` ids listed in the row, then run
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj` and `scripts/check-pbxproj.sh`.
### 525–526. DEBUG loopback device harness — `loopback-device-runtime`

Why: a real Mac-to-Mac link needs two machines running the same bundle id and build tag
(`IrxMacPeerAuthorization`, worker SQL). The loopback harness makes one tagged DEBUG build both
Macs. A synthetic "Loopback Mac" `DeviceSurfaceProvider` sits in `SurfaceCatalog.shared`. Its
`DeviceLink` dials an in-memory byte pipe instead of Iroh, and the other end is admitted into this
app's own `MobileHostService.acceptTransport` as an `.irohAdmission` Mac peer. That peer gets the
`device.workspace.*` layout handler, so the whole viewer→host pipeline runs in one process. The
code is fork-owned (`Sources/Supermux/Devices/SupermuxDeviceLoopback*.swift`, `#if DEBUG`) and is
started from `SupermuxMobileHostGlue.activateIfNeeded()`. The run instructions are in
`plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md`.
Re-apply:
1. `loopback-device-runtime` (#525): at the end of `Sources/Devices/DeviceLinkRuntime.swift`, add
   the fenced `#if DEBUG` extension with
   `func supermuxReplacingTransportFactory(_ factory: any CmxByteTransportFactory) -> DeviceLinkRuntime`.
   It copies `self`, sets `transportFactory = factory` and `independentEventByteStreamProvider = nil`,
   and returns the copy. If upstream renames `transportFactory` or makes the runtime a protocol, keep
   the same helper name and set whatever field the RPC client's `makeTransport` reads.
2. pbxproj (#526): re-add the four entries per file listed in the #526 row
   (`python3 scripts/normalize-pbxproj.py && ./scripts/check-pbxproj.sh` afterwards).
Retire both if the harness is ever replaced by a real two-Mac CI rig.
### 530–537. Device mirrors: auto-mirror, close semantics, status parity (workstream Ma) — `device-mirror-close`, `device-layout-non-terminal-panels`, `device-mirror-flatrow-status`, `device-mirror-flatrow-refresh`, `device-mirror-unhide-palette`

Design: `plans/supermux-remote-workspaces/DESIGN.md` decisions 1, 3 and 7. All logic is fork-owned in
`Sources/Supermux/Devices/` (`SupermuxDeviceMirrorCoordinator`, `…Closer`,
`SupermuxDeviceStatusProjector`, `…StatusWriter`, `SupermuxDeviceLayoutSurfaceFilter`, …) and
`Packages/SupermuxKit/Sources/SupermuxKit/Devices/` (`SupermuxMirrorReconciler`, `SupermuxHiddenRemoteWorkspaces`,
package-tested). The coordinator starts from `SupermuxDevicesGlue.activateIfNeeded()` (no new launch hook).
Re-apply:

- **#530 `Sources/TabManager.swift`.** (1) `closeWorkspace(_:recordHistory:allowEmptyingWindow:)`: after
  `guard tabs.contains(where: { $0.id == workspace.id }) else { return }` add
  `SupermuxDeviceMirrorCloseGate.workspaceWillClose(workspace, recordHistory: recordHistory)`. It must stay
  before teardown and must keep receiving `recordHistory` (true = programmatic close → Hide Here; false = internal
  close → unbind only). (2) In `closeWorkspaceIfRunningProcess(_:requiresConfirmation:source:closeAlreadyConfirmed:)`,
  after upstream's close confirmation (`if showsCloseConfirmation, !confirmClose(…) { return false }`) and before the
  close itself: `if SupermuxDeviceMirrorCloseGate.closeOnItsMac(workspace, in: self) { return true }`. It must come
  after every upstream confirmation (the pinned prompt runs in the callers, the batch prompt in
  `closeWorkspacesWithConfirmation`, whose members reach this function with `requiresConfirmation: false`), so a
  mirror asks exactly what a local workspace asks and nothing more. Every user close path (single and batch) funnels
  through this function; if upstream adds a new user close path that bypasses it, route it here too. Never add these
  calls to `finalizeAllWorkspacesForWindowClose` (window close and quit must not hide or close anything remotely).
  (Before round 4 a third fence in `closeWorkspacesWithConfirmation` and this one, at the top of the function, showed
  the fork's own "Close on <Mac> / Hide Here / Cancel" prompt; both are gone.)
- **#531 `Sources/Devices/DeviceWorkspaceLayoutCoordinator.swift`.** In `reconcile()`, replace
  `let sourceIDs = try snapshot.layout.validatedSurfaceIDs()` with the fenced block computing
  `supermuxNonTerminalIDs`, the filtered `sourceIDs`, and `supermuxTerminalLayout = snapshot.layout.removingSurfaceIDs(supermuxNonTerminalIDs)`
  (`continue` when nil); then use `supermuxTerminalLayout` in the `layoutLocations(…)` call and in
  `remappingSurfaceIDs(reverse)`. Retire if upstream learns to skip non-terminal layout surfaces itself.
- **#532 `Sources/SidebarWorkspaceSnapshotFactory.swift`.** Four fenced expressions: `?? SupermuxDeviceMirrorSidebar.branch(for: workspace)`
  after the inline `gitBranchSummaryText(…)`; in `compactDirectoryCandidates`, upstream's
  `return cloud?.directoryCandidates ?? compactDirectoryCandidatesList(…)` gains a leading
  `SupermuxDeviceMirrorSidebar.directoryCandidates(for: workspace, orderedPanelIds: orderedPanelIds, usesLastSegmentPath: settings.usesLastSegmentPath) ??`;
  the vertical `if let cloud { … }` line builds its `branch:` from `SupermuxDeviceMirrorSidebar.branch(for:)` when
  `settings.showsGitBranch` (upstream: `branch: nil`) and its `directoryCandidates:` from the same
  `directoryCandidates(…) ?? cloud.directoryCandidates`; and
  `+ SupermuxDeviceMirrorSidebar.pullRequestDisplays(for: workspace)` after `pullRequestDisplays(…)`. If upstream stops
  prefixing device directory lines with the Mac name, drop the two `directoryCandidates` expressions.
- **#533 `Sources/ContentView.swift`.** After the `.sidebarWorkspaceObservations(ids:workspaces:debouncedInterval:)`
  modifier of the workspace scroll area, the fenced `.onReceive(SupermuxWorkspaceLifecycleRelay.lifecycleDidChange)`
  that calls `scheduleWorkspaceSnapshotRefresh(workspaceId:)` for ids in `renderContext.workspaceIds`.
- **#534 `Sources/ContentView.swift`.** Next to the `claude-harness-palette-contribution` fences:
  `contributions.append(.supermuxUnhideRemoteWorkspaces)` (contributions list) and
  `registry.registerSupermuxDeviceMirrorCommands()` (handler registry).
- **#535/#536.** Inside the existing `supermux-mobile-workspace-fields` fences: the three record fields (see the #535
  row) and, in `MobileStateSyncHost.workspaceRow`, the three `SupermuxMobileWorkspaceStatusFields` arguments plus the
  branch/PR fallbacks (`?? SupermuxMobileWorkspaceStatusFields.branch(for:)` / `.pullRequest(for:)`).
- **#537 pbxproj.** Re-add the four entries for each file in the #537 row with the `50BE0005…` ids, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`.

Verify: `swift test --filter "SupermuxMirrorReconcilerTests|SupermuxHiddenRemoteWorkspacesTests"` in
`Packages/SupermuxKit`, then a tagged build launched with the loopback device and
`CMUX_TAG=<tag> python3 tests/supermux/loopback_auto_mirror_e2e.py` (plus `loopback_device_smoke.py`).
### 538. Blank terminals after an off-screen OSC 11 fill — `backdrop-cutout-after-first-frame`

Found as P1-1 of the Remote Macs visual walkthrough: a device mirror opened in the background
(auto-mirror, or upstream's own `vm.workspace_open` with `focus: false`) or restored at
launch never drew, while `read-screen` showed its buffer. It is an upstream bug, not a mirror bug: a
local background terminal that runs `printf '\033]11;#202830\007'` stays blank the same way. The
pane-local fill makes `GhosttySurfaceScrollView.setBackgroundColor(_:clearsSharedWindowBackdrop:)`
add the lazily built Core Image cutout view (`makeSharedBackdropCutoutView`, `layerUsesCoreImageFilters`
+ a custom `compositingFilter`). Added while the pane is detached or before its first frame (the hidden
bootstrap window, a never-shown or hidden-never-shown pane), that view keeps AppKit from compositing
the terminal's scroll view (text, cursor, overlays) once the pane is shown; built after the pane has
shown a frame it does not (upstream issue #8870 is the milder late-creation symptom). Building it
during the move into the real window, or one main-queue turn later while the pane was still hidden,
still blanked it; only the presented-frame gate held. Mirrors hit it every time because the owning
Mac's replay carried its colors; since #651 it carries none, so a mirror reaches the cutout only when
a program on the other Mac sets a background (the background OSC 11 terminal step still exercises it).

Re-apply: in `GhosttySurfaceScrollView.synchronizeSharedBackdropCutout(visible:)`
(`Sources/GhosttyTerminalView.swift`), before `if visible {`, add the fenced early return

```swift
if visible, sharedBackdropCutoutView == nil, window == nil || surfaceView.terminalSurface?.hasPresentedFrame != true { return }
```

An existing cutout is kept, and the removal path is untouched. Retire the fence when upstream stops
building the cutout lazily (open PR #9103 replaces it with a persistent root backdrop) or proves early
creation safe: run the E2E below without the fence and check it passes.

Verify: a tagged build launched with the loopback device, then
`CMUX_TAG=<tag> python3 tests/supermux/loopback_mirror_render_e2e.py --app-path "<App path>" --projects-file /tmp/<tag>/projects.json`
(background mirror, background OSC 11 terminal and restored mirror must each show text in a window
screenshot; the plain background workspace is the detector's control).
### 545–553. Remote Macs: notification and phone-push parity (Mb) — `device-mac-phone-forward`, `device-mac-phone-badge`, `device-notification-parity`, `device-notification-project`

Why: with remote Macs as first-class workspaces, a notification raised on the MacBook that runs an
agent is mirrored onto the viewer Mac as a `.deviceMac` record. Before this, the viewer ALSO pushed
it to the phone (duplicate banners with different ids, a tap opening a mirror of a mirror, a
notification counted once per Mac in the badge); a read on either Mac never reached the other copy; the mirrored
copy lost its project; rate-limited rows waited for an unrelated event; and an unattended MacBook
with the agent's pane focused swallowed the notification as "already seen" and never pushed. All
logic is fork-owned: `Sources/Supermux/SupermuxPhoneForwardGate.swift`, `SupermuxMacPresence.swift`,
`SupermuxFocusedPaneNotificationPolicy.swift` (presence-aware), `SupermuxDirectPhonePush.swift`,
`SupermuxMobileHost+PhonePushShare.swift`, `Sources/Supermux/Devices/SupermuxDeviceNotification*.swift`,
`SupermuxPhonePushShareCoordinator.swift`, and `Packages/SupermuxKit/Sources/SupermuxKit/Push/`
(share planner, merger, service extension, `macInstanceTag`). E2E: `tests/supermux/loopback_notifications_e2e.py`.
Re-apply:

- **#545** `TerminalNotificationStore.swift`: (1) first statement of `emitNotificationsDismissed(ids:)`:
  `let ids = SupermuxPhoneForwardGate.phoneFacingDismissIDs(ids, in: notifications)`; (2) its
  `let unreadCount = indexes.unreadCount` becomes `let unreadCount = supermuxPhoneBadgeCount`; (3) in
  `emitUnreadBadgeEventIfChanged`, `let count = supermuxPhoneBadgeCount`; (4) in
  `deliverNotificationSideEffects`, replace upstream's relay `if shouldAttemptPhone { … }` with
  `let supermuxRelayAttempted = shouldAttemptPhone && SupermuxPhoneForwardGate.allowsUpstreamRelay(for: notification)`
  and `if supermuxRelayAttempted { PhonePushClient.shared.forward(notification, badgeCount: supermuxPhoneBadgeCount) }`.
  Keep `supermuxRelayAttempted` declared BEFORE the `direct-phone-push` fence, which reads it. If
  upstream adds another phone-facing badge or dismiss emit, route it through `supermuxPhoneBadgeCount` too:
  each Mac sends only its own share and the phone totals the shares (#554–#557).
- **#546** in the visible-forward `direct-phone-push` fence, keep the `focusedPaneAlreadyVisible`
  computation and call `SupermuxComposition.directPhonePush.deliver(notification:focusedPaneAlreadyVisible:upstreamRelayAttempted:badgeCount:)`.
  Never go back to calling `forward` directly: that path ignores `.deviceMac` and `onlyWhenAway`.
- **#547** `TerminalController+MobileNotificationSync.swift`: reconcile's `unread_count` is
  `store.supermuxPhoneBadgeCount`.
- **#548** `DeviceSurfaceProvider+Notifications.swift`: the `deliver:` closure is
  `{ [weak self] row, target in guard let self else { return .declined }; return SupermuxDeviceNotificationDelivery.deliver(row, to: target, via: self) }`;
  after `notificationSync.apply(rows: notificationFeed.rows)` in `fetchNotificationFeed`, call
  `SupermuxDeviceNotificationReadMirror.mirrorHostReads(of: self)`. If upstream renames
  `deliverNotification(_:to:)`, `notificationFeed` or `notificationSync`, update the fork files that read them.
- **#549** `DeviceNotificationFeed.swift`: fenced `import SupermuxMobileCore`, the `supermuxProjects`
  property after `remoteWorkspaceIDs`, and `supermuxProjects = SupermuxDeviceNotificationProjects.projects(inFeedResponse: response)`
  after `self.init(rows:remoteWorkspaceIDs:)`.
- **#550** the `notification-project-identity` construction-site line is
  `project: SupermuxNotificationProjectBridge.project(for: request)`.
- **#551** the `mobile-supermux-dispatch` call passes `executionContext: executionContext`
  (the `mobileHostHandleRPC` parameter). Without it `phone_push.share` refuses every caller, which is
  safe but disables Mac-to-Mac push provisioning.
- **#552** pbxproj: re-add the four entries per file in the #552 row, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`.
- **#553** restore the two paragraphs inside the `focused-pane-notification-suppression-doc` fence.
### 554–557. Remote Macs: the phone badge is every Mac's total — `supermux-phone-badge-total`

Why: each Mac pushes and reports only its OWN unread count (#545/#547: a record mirrored from another
Mac is that Mac's to count). The phone used to apply whichever count arrived last as the whole
badge, so it undercounted and flipped between Macs, and a reconcile with the foreground Mac could
clear the badge while another Mac's notification was still unread. The phone now keeps the latest
count per Mac BUILD in the `group.com.supermux.ios` app group (`SupermuxPhoneBadgeLedger`, one
defaults key per device id + instance tag, `supermux.phoneBadge.<device>@<tag>`, so the extension
and the app never race) and badges the sum. Stable and Nightly on one Mac are two slots, like
`MacPairingKey` everywhere else on the phone; only the tags a Release phone pairs with (`default`,
`nightly`, `rc`; no tag is `default`) get a slot, so a tagged dev or dogfood build that shares the
Mac's push setup can neither erase the real builds' counts nor leave a slot that outlives it.
Pre-tag per-Mac keys migrate into that Mac's `default` slot on first use. Writers: the
notification service extension on every direct push (`SupermuxNotificationDecorator`, #383/#516;
the Mac side sends `mutable-content` on every notify push and an empty alert plus `mutable-content`
plus `macDeviceId` on the dismiss push, in `SupermuxPhonePushService`/`SupermuxDirectPhonePush`),
and the app from the foreground Mac's live count (#555) or a forgotten Mac (#556). A build signed
without the app group (the personal-team dogfood extension) keeps the old single-Mac behavior.
Tests: `SupermuxPhoneBadgeLedgerTests` (SupermuxMobileCore) and the payload tests in
`SupermuxPhonePushServiceTests` (SupermuxKit).
Re-apply:

- **#554** restore the whole fenced file `MobileShellComposite+SupermuxPhoneBadge.swift`. If upstream
  renames `foregroundMacDeviceID`, `activeMacInstanceTag` or `deliveredNotificationClearer`, follow
  the rename there.
- **#555** first statement of `applyAuthoritativeUnreadBadge(_:)`:
  `let count = supermuxPhoneBadgeTotal(foregroundCount: count)`. If upstream adds another path that
  sets the icon badge from a Mac's count, route it through `applyAuthoritativeUnreadBadge` or the
  same helper; a count from a Mac that is not the foreground Mac must be filed under THAT Mac.
- **#556** first statement of `forgetHiddenComputer`'s `if deletion.cleaned {` branch:
  `supermuxForgetPhoneBadge(macDeviceID: computer.macDeviceID, instanceTag: computer.instanceTag)`.
- **#557** iOS pbxproj: re-add the file ref and build file listed in the #557 row to the
  `NotificationService` target (not the app target: the app gets the type from SupermuxMobileCore).
  The iOS simulator build of `cmux-ios` compiles both.

### 560–561. Projects across Macs (P1) — `sidebar-flatrow-device-chip`

Why: every Mac's projects render in the Mac sidebar (merged by git origin), device mirrors nest
under the project that owns their remote record, and flat mirror rows mark their Mac. All logic is
fork-owned (`Sources/Supermux/Projects/`, `Packages/SupermuxKit/Sources/SupermuxKit/Devices/`,
`…/UI/`); API in `plans/supermux-remote-workspaces/PROJECTS-API.md`. The Projects section, the
flat-list filter (`SupermuxMainListFilter`), the socket router fallback and the host RPC router are
fork files, so they need no touchpoint.
Re-apply:
1. pbxproj (#560): re-add the four entries per file listed in the #560 row with the `50BE0006…`
   ids (`Projects/<name>` paths in the Supermux group), then
   `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`.
2. `sidebar-flatrow-device-chip` (#561): find upstream's `SidebarCloudWorkspaceBadgeView(` call in
   `TabItemView`'s title-line `HStack` (just before the title `Text`/rename field). Fence it, add
   `&& workspaceSnapshot.deviceWorkspaceLabel == nil` to the condition that picks its `label`, and
   after it, in the same fence, add the title-line fallback
   `if let deviceWorkspaceLabel = workspaceSnapshot.deviceWorkspaceLabel, !SupermuxFlatRowDeviceChip.drawsOnBranchLine(workspaceSnapshot, settings: settings) { SupermuxFlatRowDeviceChip(deviceWorkspaceLabel: deviceWorkspaceLabel, pointSize: GlobalFontMagnification.scaledSize(scaledFontSize(10), percent: globalFontMagnificationPercent), tint: activeSecondaryColor(0.7)) }`.
   Then, under `if detailVisibility.showsBranchDirectory` ("Branch + directory row"), anchor on the
   `if sidebarShowGitBranchIcon` glyph that opens each layout's `HStack` (vertical, stacked-compact,
   inline) and add, in its own fence with the same id right before that glyph,
   `if let deviceWorkspaceLabel = workspaceSnapshot.deviceWorkspaceLabel { SupermuxFlatRowDeviceChip(deviceWorkspaceLabel: deviceWorkspaceLabel, pointSize: GlobalFontMagnification.scaledSize(scaledFontSize(9), percent: globalFontMagnificationPercent), tint: activeSecondaryColor(0.6)) }`
   (the icon sits immediately before the branch, sized and tinted like the branch glyph so it reads
   on a selected row). If upstream changes when a layout draws its line, update
   `SupermuxFlatRowDeviceChip.drawsOnBranchLine(_:settings:)` to the same conditions, so the icon is
   drawn exactly once (the `supermux.devices.sidebar_rows` / `flat_chips` `placement` fields report
   it). If upstream renames `deviceWorkspaceLabel`, pass whatever snapshot field carries the device
   label; if upstream changes the "Workspace on %@" format key, update
   `SupermuxFlatRowDeviceChip.macName(fromDeviceWorkspaceLabel:)` to the new key.
### 570–573. Workspace behaviors for device mirrors (workstream W) — `device-new-workspace-menu`, `device-new-workspace-opener`, `mirror-file-explorer-hint`

Why: a local mirror of another Mac's workspace carries a meaningless LOCAL `currentDirectory`, so
workspace-scoped fork features acted on the wrong repository, and creating a global workspace on
another Mac was only reachable from the right-sidebar Cloud tab (and ⌘N showed a provisional
"Cloud VM" row). The behavior itself is fork-owned: `Sources/Supermux/Mirrors/` (mirror resolver,
⌘G / presets / project actions over `mobile.supermux.run.*`, `preset.launch`, `action.run`; the
Changes panel's remote model over `mobile.supermux.changes.*` via the SupermuxKit backend seam
`SupermuxChangesBackend`), `SupermuxMobileHost+RunWorkspace.swift` (host side of the additive
`workspace_id` run param), and small fork-file hooks in `SupermuxRunSupport.swift`,
`SupermuxAppGlue.swift` (presets bar + Changes mount), `SupermuxTabManagerOpener.runAction`,
`SupermuxMobileHost+Run.swift` and `SupermuxFileDiffOpener.swift`. Re-apply:

- **#570** in `makeNewWorkspaceContextMenu`, wrap upstream's final
  `renderNewWorkspaceContextMenu(model:context:cmuxConfigStore:)` call as the `to:` argument of
  `SupermuxNewWorkspaceDeviceMenu.appending(to:windowId:devices:)` (keep upstream's call exactly).
  If upstream moves menu construction, wrap wherever the finished `NSMenu?` is returned; every `+`
  entry point must go through it.
- **#571** in `performNewWorkspaceAction`, keep upstream's `deviceMachineForNewWorkspace` branch and
  put the fenced `if SupermuxComposition.deviceNewWorkspace.handles(machine) { return
  performNewWorkspaceCreationAction(initialSurface: .terminal, preferredTabManager: manager, event:
  event, placementOverride: placementOverride, debugSource: debugSource) }` before its
  `deviceWorkspaceCreationCoordinator` call: a plain New Workspace with a device mirror selected
  stays on this Mac (the user's call: a selected mirror is context; another Mac is the explicit
  "New Workspace on ▸" choice). If upstream renames `performNewWorkspaceCreationAction`, call
  whatever its own final local-create line in `performNewWorkspaceAction` calls.
- **#572** in `FileExplorerWorkspaceRootResolver.resolve(_:)`, first statement of the
  `usesRemoteDirectoryProvenance` branch. If upstream adds a device-files provider, replace the hint
  with routing to it (or to `mobile.supermux.files.*`) and retire the fence.
- **#573** re-add the four entries per file listed in the #573 row, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.

Verify: `swift test --filter SupermuxRemoteChangesBackendTests` in `Packages/SupermuxKit`, then
`CMUX_TAG=<tag> python3 tests/supermux/loopback_workspace_behaviors_e2e.py` against a tagged build
launched with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` (see the script's docstring).
### 574–576. Sidebar rows, Mac icons and close UX for device mirrors (A3) — `device-mirror-row-menu`, `sidebar-footer-clearance`

Why: rows that show other Macs' workspaces had to read the same everywhere — the Mac icon before
the branch, nested rows grouped by Mac, a flat mirror row's menu with
the same Hide Here item as a nested one (each row's own Close Workspace closes a mirror on its Mac). All logic is fork-owned
(`Packages/SupermuxKit/Sources/SupermuxKit/UI/`, `…/Devices/SupermuxNestedWorkspaceOrder.swift`,
`Sources/Supermux/Projects/SupermuxNestedWorkspaceRows.swift`, `Sources/Supermux/Mirrors/SupermuxMirrorRowMenuItems.swift`);
E2E: `tests/supermux/loopback_sidebar_rows_e2e.py`. Re-apply:

- **#574 `Sources/TabItemView+WorkspaceContextMenu.swift`.** In `workspaceContextMenu`, after the
  `if let key = closeWorkspaceShortcut.keyEquivalent { … } else { … }` Close Workspace block and
  before Close Other Workspaces, add the fenced
  `if !isMulti, workspaceSnapshot.deviceWorkspaceLabel != nil { SupermuxMirrorRowMenuItems(workspaceId: workspaceId) }`.
  If upstream renames `deviceWorkspaceLabel`, test whatever says the row shows another Mac's
  workspace. Do not add a close item: upstream's Close Workspace closes a mirror on its Mac (#530).
- **#575 `Sources/ContentView.swift` (`VerticalTabsSidebar`).** Add the fenced
  `@State private var supermuxSidebarFooterHeight: CGFloat = 0` next to the
  `sidebar-projects-empty-area` state; in `body`'s `ZStack(alignment: .bottomLeading)`, fence
  `.supermuxReportsSidebarFooterHeight($supermuxSidebarFooterHeight)` after the `SidebarFooter(…)`'s
  `.frame(maxWidth: .infinity, alignment: .leading)`, and
  `.supermuxClearsSidebarFooter(height: isPresented ? supermuxSidebarFooterHeight : 0)` after
  `workspaceScrollArea(renderContext: renderContext)`. Retire all three if upstream stops drawing the
  footer over the list (e.g. stacks it below the scroll view or gives it a bottom inset).
- **#576 pbxproj.** Re-add the four entries for each file in the #576 row with the `50BE0013…`
  ids, then `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`.

Verify: a tagged build launched with the loopback device, then
`CMUX_TAG=<tag> python3 tests/supermux/loopback_sidebar_rows_e2e.py` (also in `run_all_loopback_e2e.sh`).
### 577. Local workspaces never inherit a mirror's directory — `device-mirror-no-cwd-inherit`

Why: upstream's "inherit working directory" gives a new workspace the selected workspace's
directory. With a device mirror selected, that is a path on the other Mac, so This Mac (or any
local creation that inherits) started the local terminal somewhere that may not exist here.
Re-apply:

- **#577** in `TabManager.preferredWorkingDirectoryForNewTab(workspace:)`, right after
  `guard let workspace else { return nil }`, re-add the fenced
  `if SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) { return nil }`. If upstream renames
  the helper or adds another source for the inherited directory of a new workspace, put the same
  check where that source reads the selected workspace.

Verify: `CMUX_TAG=<tag> python3 tests/supermux/loopback_projects_e2e.py --projects-file <file>`
(step `local_workspace_ignores_mirror_cwd`).
### 580–586. iOS multi-Mac Supermux — `supermux-mobile-mac-seams` + `supermux-mobile-workspace-mac-seam`

Why: upstream iOS aggregates workspaces from every paired Mac (foreground + background control
subscriptions; rows scoped `<pairingID>` + U+001F + `<uuid>` once two Macs are paired), but the #96
seam exposes only the foreground Mac. With it the Projects section showed one Mac's projects,
disappeared when the foreground Mac was offline, navigated with Mac-local ids ("No Workspace" with
two Macs), and registered the phone's push token only with the foreground Mac. All logic is
fork-owned in `Packages/iOS/SupermuxMobileUI` (`SupermuxProjectsSectionModel` +
`SupermuxMacProjectsSession` per pairing, `SupermuxProjectKey`, `SupermuxWorkspaceNavigator`,
`SupermuxNewWorktreeMacOptions`, `SupermuxPhonePushRegistrations`) and `SupermuxMobileKit`
(`SupermuxMacSeam`). Re-apply:

- **#580** `CmuxMobileShell/Package.swift`: `.package(path: "../SupermuxMobileKit")` in the package
  dependencies and `"SupermuxMobileKit"` in the `CmuxMobileShell` target dependencies, each fenced.
- **#581** restore the whole file from git history (it is fork-owned in full). It uses only
  `connectionState`, `remoteClient`, `supportedHostCapabilities`, `foregroundMacDeviceID`,
  `foregroundMacKey`, `activeMacInstanceTag`, `focusedForegroundConnection`,
  `secondaryMacSubscriptions`, `workspacesByMac`, `stableMacColorSlots` and `pairedMacs`; if
  upstream renames one, follow the rename. The seam's `pairingID` MUST equal the pairing id
  stamped on that Mac's workspace rows (`CmxMacAppInstanceIdentity(macDeviceID, macInstanceTag)`),
  or the section's per-Mac joins silently match nothing.
- **#582** restore the whole file; it only wraps
  `store.workspaceID(matchingRemoteWorkspaceID:macDeviceID:instanceTag:)`.
- **#583** in both #97 driver fences, pass `seams: store?.supermuxConnectionSeams ?? []`,
  `selectedWorkspaceID: selectedWorkspaceID` and `resolveWorkspace: supermuxResolveWorkspace`. The old single-seam `connection:` overload was
  removed on purpose: re-applying the pre-multi-Mac line fails to compile instead of silently
  losing background Macs and the scoped-row navigation.
- **#584** restore the whole file. **#585/#586** replace `store.supermuxConnectionSeam` with
  `supermuxWorkspaceSeam` at the five reads listed in the rows; any new fork read of the seam in
  `WorkspaceDetailView` should use `supermuxWorkspaceSeam` too.

Verify: `swift test` in `Packages/iOS/SupermuxMobileUI` (the multi-Mac suites are
`SupermuxMultiMacSectionTests`, `SupermuxMultiMacPartitionTests`, `SupermuxWorkspaceNavigatorTests`,
`SupermuxNewWorktreeMacPickerTests`), then an iOS simulator build of `cmux-ios`, then a two-Mac
check on a real phone (projects of both Macs listed under Mac headers; New Worktree offers the
second Mac for the same repository; the created workspace opens).
### 587. iOS Mac-seam resolution test — `supermux-mobile-mac-seams`

Whole-file fork test (`Packages/iOS/CmuxMobileShell/Tests/CmuxMobileShellTests/SupermuxMacSeamResolutionTests.swift`)
inside an upstream package. Nothing to merge: if upstream deletes or renames the package's test target,
move the file to the new target (or drop it together with #581, whose behavior it pins). It has no fence
because the whole file is fork-owned.

### 590. New Worktree on any Mac (workstream P2) — pbxproj only

Why: the Mac New Worktree sheet creates on This Mac or on another Mac that has the project (device
picker; the last Mac the user chose for a worktree is remembered once for every project), and every
entry point (hover ＋, context menu, "New Worktree on ▸ <Mac>", remote-only rows) opens that one
sheet. All logic is fork-owned: the
sheet, its model and the `SupermuxWorktreeCreationTarget` seam live in `Packages/SupermuxKit`
(`UI/SupermuxNewWorktreeSheet*.swift`, `UI/SupermuxNewWorktreeSheetModel*.swift`,
`Agent/Supermux{WorktreeCreationTarget,LocalWorktreeCreationTarget}.swift`,
`Devices/SupermuxWorktree{DeviceEntry,DevicePlanner,LastDeviceStore}.swift`,
`Devices/SupermuxRemoteWorktreeFailure.swift`); the remote target and the DEBUG socket drivers live
in `Sources/Supermux/Projects/`. The socket route is in the fork-owned
`SupermuxDevicesSocketCommands`. The additive `ai_naming_configured` field on
`mobile.supermux.agent.options` is in the fork-owned wire contract (`SupermuxAgentLaunchOptionsDTO`)
and host handler (`SupermuxMobileHost+Agent.swift`). Re-apply:

- **#590** re-add the four entries per file listed in the #590 row with the `50BE000B…` ids
  (`Projects/<name>` paths in the Supermux group), then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.

Verify: `swift test --filter "SupermuxWorktreeDevicePlannerTests|SupermuxWorktreeLastDeviceStoreTests|SupermuxRemoteWorktreeFailureTests|SupermuxNewWorktreeSheetModelTests|SupermuxNewWorktreeSheetTests"`
in `Packages/SupermuxKit`, then `CMUX_TAG=<tag> python3 tests/supermux/loopback_new_worktree_picker_e2e.py`
against a tagged build launched with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` (see the script's docstring).

### 591–593. Where New Workspace goes — `device-new-workspace-this-mac`, `new-workspace-target-help`

Why: "New Workspace on ▸" offered no way to create on this Mac while a mirror was selected, and a
plain `+` / ⌘N there silently created on the other Mac. Now the submenu starts with **This Mac** and
the row a plain `+` would use right now is checked. Since #571 a plain `+` / ⌘N with a mirror
selected creates on this Mac, so This Mac is checked there too and the `+` tooltip (which named the
other Mac while `+` created there) is upstream's again: #592 is inert. The menu and the target
resolver (`SupermuxNewWorkspaceTarget`) are fork-owned; the upstream edits are the local entry point
and the tooltip. Re-apply:

- **#591** after `performNewWorkspaceAction(…)` in `AppDelegate.swift`, re-add the fenced
  `supermuxPerformLocalNewWorkspaceAction(tabManager:placementOverride:)`, passing its defaulted
  `placementOverride` through (the empty area's This Mac row passes `.end`). It must stay in
  `AppDelegate.swift` because `performNewWorkspaceCreationAction` is `private`; if upstream renames
  that method or its parameters, call the new one with a `.terminal` initial surface, the window's
  tab manager and the placement override.
- **#592** wrap the primary `+` segment's tooltip in `TitlebarNewWorkspaceSplitButton` with
  `.supermuxNewWorkspaceButtonHelp(…)` instead of `.safeHelp(…)`, passing upstream's own string
  unchanged. If upstream moves the `+` button, fence its new tooltip site the same way, or retire
  the fence (with `SupermuxNewWorkspaceButtonHelp.swift`): it only changes the tooltip for a
  `SupermuxNewWorkspaceTarget.device` target, which #571 no longer produces.
- **#593** re-add the four entries per file listed in the #593 row with the `50BE0014…` ids, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.

Verify: `CMUX_TAG=<tag> python3 tests/supermux/loopback_workspace_behaviors_e2e.py` (steps
`new_workspace_menu_lists_mac`, `new_workspace_shortcut_on_mirror` and
`new_workspace_this_mac_from_mirror`).

### 594. Restored mirror panes keep their notifications — `device-restored-pane-notifications`

Why: a relaunch restores a device mirror with placeholder panes that carry the mirror's
notifications. When the link returns, `DeviceSurfaceProvider.reconnectRestoredPanes` materializes a
live pane and closes the placeholder; closing a pane clears its notifications, and the device sync
acknowledges each cleared mirrored notification to the owning Mac as read. So every relaunch of
the viewer silently dropped its mirrored notifications and read them on the other Mac (which then
also cleared them on the phone), and a Mark as Unread never survived one. The fork helper
(`Sources/Supermux/Devices/SupermuxRestoredMirrorNotifications.swift`) moves the placeholder's
notifications to the live pane through the store's own `restoreSessionNotifications`, keeping ids
and read state and restoring the `.deviceMac` origin from the correlation key. Re-apply:

- **#594** in `reconnectRestoredPanes`, right before the placeholder's
  `SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)`, re-add the
  fenced `SupermuxRestoredMirrorNotifications.carry(fromPanel: projection.panelID, toPanel:
  created.panelID, inWorkspace: projection.workspaceID)`. If upstream stops closing the placeholder
  (reusing its panel id for the live pane), drop the fence. If `TerminalNotification` gains stored
  fields, copy them in the helper's `supermuxMoved(from:to:)`.

Verify: `CMUX_TAG=<tag> python3 tests/supermux/loopback_auto_mirror_e2e.py --app-path "<App path>"`
(step `h_restart_one_mirror_per_source`).

### 595–599. Remote Macs sync gaps and user controls (workstream X) — `device-layout-tab-changes`

Why: (1) the owning Mac announced a workspace's layout only when its pane geometry changed, which
needs the workspace on screen, so background tab changes (agents, the phone, presets, CLI
`new-surface`) never reached another Mac's mirror; (2) the fork's remote-Mac preferences had no UI.
All logic is fork-owned: `Sources/Supermux/Devices/SupermuxDeviceLayoutChangeObserver.swift`
(observation-tracked layout capture), `SupermuxRemoteMacsSettingsFeed.swift` (the card's app side),
`HostSettingsActions+SupermuxRemoteMacs.swift` (the hosting conformance) and
`SupermuxRemoteMacsSocketCommands.swift` (`supermux.devices.remote_macs_settings*`, `flat_chips`).
Re-apply:

- **#595** in `DeviceWorkspaceLayoutHost`: add the fenced `private lazy var supermuxTabChanges =
  SupermuxDeviceLayoutChangeObserver { [weak self] id in guard let self, self.snapshots[id] != nil
  else { return }; _ = self.snapshot(for: id) }` among the stored properties, and in
  `snapshot(for:)` route upstream's `capture(workspaceID)` through
  `supermuxTabChanges.capture(workspaceID, { capture(workspaceID) })` (keep upstream's validation
  in the same `guard`). If upstream starts publishing on tab add/remove/move itself (for
  workspaces off screen too), retire the fence and the observer file;
  `tests/supermux/loopback_tab_sync_e2e.py` proves either way.
- **#596–#598** restore the three whole files from the fork's history; they depend only on
  `CmuxSettings` (`ManagedDevicePolicy`, `DevicesAccessCoordinator.Preference`) and this package's
  `SettingsCard*`, `DeviceAccessControl`, `ComputersSettingsActions` and `SettingsHostActions`.
  Follow any upstream rename of those. The mount is one line inside #18's body fence.
- **#599** re-add the four entries per file listed in the #599 row, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.

Verify: `CMUX_TAG=<tag> python3 tests/supermux/loopback_tab_sync_e2e.py` and
`CMUX_TAG=<tag> python3 tests/supermux/loopback_remote_macs_settings_e2e.py` against a tagged build
launched with `SUPERMUX_DEBUG_LOOPBACK_DEVICE=1` (both run in `tests/supermux/run_all_loopback_e2e.sh`).
### 600. Harness arm in upstream's copy-action switch — `claude-harness-builtin-action`
`Sources/TerminalCopyAction.swift` maps each `CmuxSurfaceTabBarBuiltInAction` to a
`TerminalCopyAction?` with an exhaustive switch. Re-apply: after upstream's `return nil` group, add a
fenced `case .newClaudeHarness: return nil`. A missing arm is a compile error, not a silent gap.
### 601. iOS Notifications tab stays on by default — `ios-notifications-tab-default`
Upstream's iOS agent Feed (2026-10-01 merge) hides the Notifications tab unless the
`cmux.mobile.debug.feedReplacesNotifications.v1` default is `false`, and treats an absent key as
`true`. The fork's project-aware notification rows (#365/#366) render only in that tab. Re-apply: in
`MobileDisplaySettings.init(defaults:)`, change the `feedReplacesNotifications` fallback from
`?? true` to `?? false` inside the fence. Retire this row (take upstream's `?? true`) if the fork
decides to converge on the Feed, ideally after porting the project avatar into the Feed rows.


### 630–637. Remote Macs: typing and sizing behave as on the Mac itself — `device-mirror-input-batch`, `device-mirror-hidden-counts`, `device-mirror-input-host`, `sizing-hidden-mac-pane`, `device-mirror-key-resolver`

User feedback: in a device mirror, Claude Code received Esc as Escape plus a literal "[27u", a mouse
drag as Esc presses, and modified keys as junk; and a tab opened from the mirror stayed small until
it was opened on the other Mac. Fork code: `Sources/Supermux/Devices/SupermuxDeviceTerminalInput.swift`,
`SupermuxTerminalSizingVisibility.swift`, and in SupermuxKit `SupermuxForwardedKeyEvent`,
`SupermuxTerminalInputBatch`, `SupermuxTerminalReplyFilter` (their tests list the failure modes).
Capability: `supermux.terminal_input.v1`; an older Mac on either side keeps upstream's text path.

Re-apply after an upstream merge:
- **#630 router**: keep the batch as the pending store and upstream's `init(send:onFailure:)` as a
  convenience over `init(sendBatch:onFailure:)`; `enqueue` must route every `TerminalManualInput`
  through `SupermuxDeviceTerminalInput.batchItem` (never drop `.namedKey` unconditionally).
- **#631 session**: wherever upstream builds the `mobile.terminal.input` params in the router's send
  closure, build them with `SupermuxDeviceTerminalInput.inputParams(batch, base:, hostTakesBatches:)`
  and keep upstream's later fields (`client_id`). Keep the replay's `counts_override` while
  `supermuxHidden` or while the host still holds it, and the `track`/`untrack` calls in `bind`/`stop`.
- **#632 host**: the `supermux_input` batch must reach `SupermuxDeviceTerminalInput.deliver` inside
  upstream's `MobileTerminalByteTee.performMobileInput` closure, so ordering, admission, viewport
  piggyback and acknowledgements stay upstream's.
- **#633**: wherever upstream creates a `LocalTerminalSizingHost` for a local terminal, call
  `prepareHost(&host, surface:)` before storing and applying it. Retire #633 and the host half of
  `SupermuxTerminalSizingVisibility` if upstream stops counting off-screen panes itself.
- **#634/#635**: every device-pane `keyNameResolver` comes from `SupermuxDeviceTerminalInput.keyResolver(for:)`.
- **#636**: keep the rewritten reservation test in step with #635.


### 660–664. New tabs append; New Terminal to the Right keeps its spot in a mirror — `new-tab-at-end`, `mirror-terminal-to-right`

User feedback: every terminal tab opened from a remote workspace (⌘T, `+`, the phone) landed second
on both Macs. Upstream inserts a new tab after the pane's selected tab; a mirrored workspace's tabs
are created unfocused on the owning Mac, whose selection never follows the viewer, so on a headless
Mac it stays on the first tab and the mirror adopts that order. One rule now: new tabs append
(workspaces, the Dock; browser tabs too). "New Terminal to the Right" in a device mirror sends
`after_surface_id` with `device.workspace.terminal.create` (capability
`supermux.terminal_placement.v1`; an older owning Mac gets no new param and appends). Fork code:
`Sources/Supermux/Mirrors/SupermuxMirrorTerminalPlacement.swift`; DEBUG drivers
`SupermuxTabOrderSocketCommands.swift` (`supermux.devices.mirror.tab_bar_new_tab`,
`tab_context_action`, and for a lost reply's Retry `lose_next_create_reply`, `pending_creations`,
`retry_pending`). Re-apply after an upstream merge:

- **#660 (1) / #661**: keep `newTabPosition: .end` wherever upstream builds the workspace's and the
  Dock's `BonsplitConfiguration`. If upstream adds a tab-placement setting, retire both fences and
  default that setting to "end".
- **#660 (2) / #660b**: every "New Terminal to the Right" entry point asks
  `SupermuxMirrorTerminalPlacement.createTerminalToRight` first and stops when it returns non-nil.
  If upstream routes "to the right" through one shared function, fence that one instead.
- **#662**: `remember` must run after the request exists and before `reserveCloudTerminalPane`
  inserts the pane (it reads the tab left of the requested index).
- **#663 / #663b**: the provider adds `after_surface_id` only for tab creates; the host accepts it,
  validates it against the captured layout, and places the tab before capturing the reply's
  snapshot. If upstream adds its own position param, map onto it and retire these fences.
- **#664**: pbxproj only.

Verify: `CMUX_E2E_SUITES="loopback_new_tab_order_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`.

### 665–670. Remote Macs: a terminal fills the Mac you view it from; one size choice per Mac — `sizing-default-policy`, `device-mirror-sizing-claim`, `sizing-sticky-preference`, `device-mirror-viewport-limit`

User feedback: a terminal on the other Mac was not full screen in its mirror. Upstream creates every
terminal as Fit everyone (smallest), in memory, per terminal, so a phone or a small pane elsewhere
shrank it, and a mode chosen in the size panel changed one terminal until the next relaunch. Fork
code: `Sources/Supermux/Devices/SupermuxTerminalSizingDefaults.swift` (the preference in UserDefaults
`supermux.terminalSizing.preference`, the mirror claim, the viewport limit, the DEBUG loopback viewer
identity), `SupermuxTerminalSizingVisibility.trackedMirrorSessions()`, and the DEBUG drivers in
`SupermuxTerminalSizingSocketCommands.swift`. No engine change: `priority` is upstream's mode.

Re-apply after an upstream merge:
- **#665**: wherever upstream creates a `LocalTerminalSizingHost` for a local terminal, call
  `SupermuxTerminalSizingDefaults.shared.prepareHost(&host)` after #633's `prepareHost` and before the
  host is stored and published. Retire it if upstream grows a per-Mac default policy (then seed that
  from the preference instead).
- **#666**: keep `supermuxSizingClaim` on the session; call `mirrorAttached(self)` once per attach that
  sticks (after `phase = .attached`), and `connectionDropped(self)` wherever upstream handles a lost
  link. Never call the claim from the `.sizeState` / `.updated` handlers or from `receiveReplaySizing`:
  pushing in answer to the other Mac's events is the loop the claim exists to prevent. Keep the
  viewer identity coming from `viewerIdentity(for:)`.
- **#667/#668**: every UI entry point that changes the mode, fixed size or priority order goes through
  `userChoseMode/userChoseFixedSize/userChosePriority`. Size to My Window, the counts toggle and the
  socket `terminal.size_policy.set` stay on the store (per terminal). If upstream adds another mode
  entry point (command palette, shortcut), route it the same way.
- **#669**: wherever upstream clamps a reported viewport, keep phones at upstream's limit and let
  `device_kind: mac` reach `TerminalSizingPolicy.maximumFixedSize`. Retire it if upstream raises its
  clamp to at least that.

Verify: `CMUX_E2E_SUITES="loopback_terminal_sizing_policy_e2e loopback_terminal_input_e2e" CMUX_TAG=<tag>
tests/supermux/run_all_loopback_e2e.sh`.

### 620–622. New Workspace stays on this Mac; other Macs on request — `sidebar-empty-area-local`, `device-root-workspace-create`, `sidebar-empty-area-device-menu`

Why: device mirrors made every plain New Workspace entry point follow upstream's device routing, so
with a mirror selected a double-click on the sidebar's empty area (and `+` / ⌘N) created on the
other Mac, in whatever directory that Mac had selected. A selected mirror is context, not a target:
plain New Workspace creates here (#571, #620) and another Mac is an explicit choice — "New Workspace
on ▸" in the `+` menu (#570) or the empty area's context menu (#622) — which starts in that Mac's
home folder (#621). Re-apply:

- **#620** in `sidebarEmptyAreaUsesRemoteNewWorkspaceRouting(tabManager:)`, fence the whole body:
  `if SupermuxNewWorkspaceTarget.isForkDeviceWorkspace(tabManager.selectedWorkspace) { return false }`
  then upstream's expression with `return`. If upstream adds terms, keep them after the guard. If
  upstream stops routing device workspaces here (drops the `deviceMachineForNewWorkspace` term),
  retire the fence.
- **#621** in `v2MobileWorkspaceCreate`, after upstream's `createParams` overrides (`focus`,
  `eager_load_terminal`, `auto_refresh_metadata`) and before `v2PrepareWorkspaceCreate`, re-add the
  fenced `SupermuxDeviceWorkspaceOpener.applyRootDirectoryRequest(to: &createParams)`. It must run
  before the working-directory validation and the idempotency preparation read the params. If
  upstream moves the mobile create, fence wherever it first reads `working_directory` / `cwd`.
- **#622** at the end of `sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager:)`'s `contextMenu`
  builder (after the New Empty Workspace Group button, both shortcut branches), re-add the fenced
  `SupermuxEmptyAreaNewWorkspaceMenu(tabManager: tabManager)`. If upstream renames or splits the
  empty area's context menu, mount it at the end of whichever menu the empty sidebar area shows. If
  the fork ever turns the AppKit list on (#130), append `SupermuxNewWorkspaceDeviceMenu.parentItem`
  rows to `SidebarWorkspaceTableController.emptyAreaMenu()` too.

Verify: `CMUX_TAG=<tag> python3 tests/supermux/loopback_workspace_behaviors_e2e.py` (steps
`new_workspace_shortcut_on_mirror`, `empty_area_on_mirror_creates_local_root`,
`empty_area_menu_lists_macs`, `empty_area_menu_creates_on_mac_in_home` and
`empty_area_menu_this_mac_creates_local`).

### 640–644. Remote Macs: a busy mirror tab closes like a local one — `mobile-terminal-close-force`, `device-terminal-close-force`, `device-terminal-close-deferred`, `remote-mac-viewer-generation-floor`, `device-mirror-viewport-generations`

User feedback: a mirror tab running Claude Code would not close ("Couldn't update the machine
workspace / The Cloud operation failed"), came back, then showed "Mac disconnected" and could not be
closed again. Two upstream bugs: `mobile.terminal.close` never passed `force` to the guarded
`controlSurfaceClose` (upstream #15613) and reported the refusal as `internal_error`; and every
mirror pane on one link shares a client id while each viewer counted viewport generations from 0,
so a pane that re-projected (or reopened) a terminal reported below the earlier pane's clear and the
host fenced it until the link reconnected. Round 4 (user feedback: "it should just kill the process and close the tab
just like it does for local") removed the "Close “X” on <Mac>?" prompt this round had added: every close now forces.
Fork code: `Sources/Supermux/Devices/SupermuxDeviceViewportGenerations.swift`,
`SupermuxDeviceHeldCloses.swift` (also consulted by `SupermuxDeviceLayoutSurfaceFilter`, fork-owned,
which leaves a held terminal out of the reconcile through the existing #531 fence), DEBUG drivers in
`SupermuxDeviceTerminalCloseSocketCommands.swift`.

Re-apply after an upstream merge:
- **#640**: wherever upstream's `mobile.terminal.close` calls `controlSurfaceClose`, pass
  `force: v2Bool(params, "force") == true` and answer `.confirmationRequired` with the
  `confirmation_required` code (never `internal_error`, which `mobileHostResult` sanitizes). Retire
  the fence if upstream does both itself. Mac viewers always force (#641); the phone's pane close forces on the host.
- **#641 force**: the `mobile.terminal.close` request in `performClose` adds `"force": true` to
  upstream's `["workspace_id": remoteID, "surface_id": close.surfaceID]`, for every close (a held close
  sent on reconnect goes through the same path). The catch keeps upstream's `close.fail(error)`.
  Retire it if upstream forces this close itself.
- **#641 deferred**: keep the four hold sites (offline `enqueueClose` for a close with a local
  workspace, `cancelPendingCloses` unless `stopped`, the `performClose` catch while disconnected,
  the offline delivery restore at the top of `projectionDidEnd`) and send
  `SupermuxDeviceHeldCloses.shared.take(on: machine)` in `connectionChanged` before
  `scheduleReconcile()`. If upstream starts deferring closes itself, retire this fence and
  `SupermuxDeviceHeldCloses`.
- **#642/#643**: every place a device mirror's `RemoteMacTerminalViewer` reports a viewport
  generation raises it to `SupermuxDeviceViewportGenerations.shared` first and records what it sent
  (a clear records `generation + 1`). The host keeps one viewport per client id, so the pane that
  reported its grid last (or came on screen last) speaks for this Mac: another live pane of the
  same terminal leaves the grid out of its replays, re-reports, automatic counts changes and clear
  until its own pane resizes or is shown. The speaking pane hands the role to another pane of the
  terminal when it goes off screen beside one on screen or closes (only the last pane clears), and
  the automatic `counts_override: false` is tracked per client id and terminal in
  `SupermuxDeviceViewportGenerations` (`supermuxHostHoldsHiddenCounts` is a computed property over
  it), never per pane. Retire both if upstream gives each viewer a per-surface client id or seeds the
  generation itself.

Verify: `CMUX_E2E_SUITES="loopback_mirror_tab_close_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`.
### 650–653. Device mirrors use this Mac's terminal appearance — `replay-theme-portable`, `device-mirror-viewer-colors`, `osc-default-bg-clears-override`

User feedback: remote (device-mirror) tabs ignored a translucent background. Every replay from the
other Mac restored that Mac's default colors (OSC 10/11/12) and palette, so each mirror pane got a
pane-local OSC 11 override and painted its own fill (`TerminalSurfaceBackgroundFillPlan` owner
`terminal`, plus the Core Image cutout) instead of the window's shared translucent backdrop a local
pane uses; it looked opaque and showed the other Mac's colors. The fix follows upstream's Cloud
mirror: the replay carries no color state, and only the colors a program on the other Mac set itself
(its effective colors that differ from its `terminal_config_theme`) travel beside it as a sparse
`CloudTuiRemoteColors` set. Every replay settles the colors in full rather than as a delta from
earlier replays, since live bytes (or bytes lost in a link gap) can change them in between: it
resets each absent special color (OSC 110/111/112), resets the palette (OSC 104), then sets the
authored ones; on a mirror a reset to the default clears the pane override (#652). A host that
does not export `terminal_config_theme` sends none, so this Mac's theme wins. Fork code:
`Sources/Supermux/Devices/SupermuxDeviceMirrorColors.swift` (`SupermuxDeviceMirrorColors`,
`SupermuxDeviceMirrorColorState`); DEBUG driver `Sources/Supermux/Mirrors/SupermuxMirrorAppearanceSocket.swift`.

Re-apply after an upstream merge:
- **#650** in `MobileTerminalRenderGridReplay`: keep upstream's `init(_:)` and add the fenced
  `includesColorState` property and `init(_:includesColorState:)`. Wrap whatever block the full
  snapshot uses to restore default colors and palette (today OSC 10/11/12 via `oscColorOrResetBytes`
  and `appendPaletteRestore`, just before the default-style SGR) in `if includesColorState { … }`. If
  upstream adds another color emission to the full snapshot, put it inside the same `if`. Retire if
  upstream gives the replay its own theme-portable mode, and pass that instead.
- **#651** in `DeviceTerminalMirrorSession`: the render-grid branch of `decodeReplay` must build its
  bytes with `SupermuxDeviceMirrorColors.themePortableBytes(frame)` and its colors with
  `authored(in: frame)`; wherever `attach()` feeds the replay to the surface, feed
  `supermuxColors.bytes(applying:colors:)` instead. The legacy `snapshot_data_b64`
  branch leaves `colors` nil (its RIS resets every color). Live `terminal.bytes` stay untouched.
- **#652** in the `GHOSTTY_ACTION_COLOR_CHANGE` background branch: the value stored in
  `surfaceView.backgroundColor` comes from `SupermuxDeviceMirrorColors.surfaceBackgroundOverride`
  with `isMirror: surfaceView.terminalSurface?.ioMode == .manualMirror`; keep upstream's
  `applySurfaceBackground()` / `applyWindowBackgroundIfActive()` after it. Retire if upstream stops
  treating a color change to the default as an override.
- **#653**: pbxproj entries only.

Verify: `CMUX_E2E_SUITES="loopback_mirror_appearance_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`
(steps `mirror_matches_local`, `mirror_after_resync`, `authored_color_propagates`,
`authored_reset_restores_translucency`, `live_reset_during_gap_settles`, `restored_mirror_matches_local`; the hard proof is the
mirror driver's `applied_remote_colors == {}` and `last_replay_color_osc == false`).
### 675–681. Remote Macs: a mirror's Files panel browses the other Mac — `mirror-file-explorer-device`, `mirror-file-explorer-follow`, `mirror-file-search-scope`, `mirror-file-preview-error`, `mirror-file-explorer-authz`

User feedback: a device mirror's Files panel only said "Remote files unavailable: They are on <Mac>."
No upstream provider can read another Mac's disk over the device link. Fork code:
`Sources/Supermux/Mirrors/` (`SupermuxMirrorFileExplorerRoot` resolver states and follower,
`SupermuxDeviceFileExplorerProvider` + `SupermuxDeviceFileTransport` + `SupermuxDeviceFileError`,
`FileExplorerStore+SupermuxDevice`, `SupermuxMirrorFileExplorerLiveRefresh`,
`FileSearchController+SupermuxDevice`, the DEBUG `SupermuxMirrorFilesSocket`), the host side
(`SupermuxMobileHost+FilesRead.swift`, `SupermuxHostFileSearch.swift`, `files.list {show_hidden}` in
`SupermuxMobileHost+Files.swift`), and in packages `SupermuxMobileFileBrowser(+Read)` (its read tests
list the failure modes) and the `SupermuxFile*DTO`s. Capability `supermux.files_read.v1`; an older Mac
keeps the unavailable root, now reading "Update Supermux on <Mac> to browse its files here." The
methods are workspace-scoped and never relay-allowlisted. #572's fence line is unchanged; its function
now returns `.supermuxDevice` when the Mac serves the capability.

Re-apply after an upstream merge:
- **#675** (a) keep `case supermuxDevice(SupermuxMirrorFileRoot)` in `FileExplorerWorkspaceRoot` (it
  must stay `Equatable`: the observation dedupes on it); (b) every exhaustive switch over the root
  needs the arm calling `applySupermuxDeviceWorkspaceRoot`; (c) the device branch must run inside
  `refreshGitStatus` after upstream bumps its generation, setting `gitStatusByPath` only when the
  generation and resource context still match. If upstream makes the git setter non-private, move (c)
  into the fork extension.
- **#676** keep the call as the last statement of `FileExplorerWorkspaceObservation.init` (after
  every stored property is set). If upstream starts observing device catalog changes itself, retire it.
- **#677/#678** keep the scope case beside upstream's Cloud one and its dispatch right after the Cloud
  dispatch. If upstream adds a generic remote-provider search seam, route the device provider through it.
- **#679** keep the fallback between upstream's `FileExplorerError` text and its generic sentence.
- **#680** re-add the four entries per file listed in the row, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.
- **#681** keep the three methods in the workspace-scoped arm.

Verify: `swift test --filter SupermuxMobileFileBrowser` in `Packages/SupermuxKit`, then
`CMUX_E2E_SUITES="loopback_mirror_files_e2e loopback_workspace_behaviors_e2e" CMUX_TAG=<tag>
tests/supermux/run_all_loopback_e2e.sh`.

### 682–684. A remote preview reopens and refreshes; its error alert never blocks the main queue — `preview-error-alert-nonblocking`, `preview-refresh-readonly-replace`

Found by the files E2E: reopening a mirror's open README.md preview hung the app. Two bugs. Upstream's
`CloudFilePreviewCache.refresh` replaced the read-only (`0o400`) preview copy with `replaceItemAt`,
which needs a writable original, so every refresh failed with `NSFileWriteNoPermissionError` (513) —
for Cloud previews too. And the coordinator reported that failure with `runCmuxModal` from its
main-actor task: a nested modal session inside a main-queue job, where CFRunLoop does not drain the
main queue, so every socket request and mirror waited for OK. Fork code:
`Sources/Supermux/SupermuxAlertPresentation.swift`.

Re-apply after an upstream merge:
- **#682** keep the alert's construction upstream's and only swap the presentation call. If upstream
  presents this alert without a nested modal (a sheet it does not wait on, or outside the task),
  retire the fence.
- **#683** keep the `0o400` on the temporary file and swap only the replace. If upstream stops making
  the copy read-only or replaces it some other way that works on a read-only original, retire it.
- **#684** re-add the four entries, then
  `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && ./scripts/check-pbxproj.sh`.

Verify: `CMUX_E2E_SUITES="loopback_mirror_files_e2e loopback_mirror_tab_close_e2e" CMUX_TAG=<tag>
tests/supermux/run_all_loopback_e2e.sh` (`open_file_preview` reopens a changed file; `large_file_capped`
shows the 8 MB refusal as a sheet while the socket keeps answering).

### 685–686. A replay keeps the program's mouse modes — `replay-mouse-modes-last`

Found by the input E2E once its key checks pressed each key on the source Mac too: hiding and showing
the mirror changes the terminal's grid, every grid change replays the mirror, and after a replay a
drag in the mirror selected text instead of reaching Claude Code as mouse reports. The render-grid
frame carries the right modes (`1000`, `1002`, `1006` on), but the full snapshot re-applied them in
code order and Ghostty's mouse event and format modes are single settings that any reset clears
(`ghostty/src/termio/stream_handler.zig`), so the frame's own `?1003l` and `?1015l`/`?1016l` undid
them. Upstream bug (phones replay the same way).

Re-apply after an upstream merge: keep the reorder on the full snapshot's mode loop (after the default
baseline, before the cursor restore): disabled modes, then enabled non-format modes, then the enabled
formats in preference order 1005, 1015, 1006, 1016 (#686 tests this against a model of Ghostty's state).
If upstream emits the mouse groups in an order-safe way itself (or only the enabled member of each
group, from Ghostty's real `flags.mouse_event`/`flags.mouse_format`), retire both.

Known limit (review R2-1 b): per-code flags cannot tell that a program cleared tracking with a
different code than it set (`?1000h`, later `?1002l`); the frame still has 1000 on, so a replay turns
tracking back on. Only a ghostty-side export of the single event/format value fixes that.

Verify: `swift test --filter "MobileTerminalRenderGrid|SupermuxReplay"` in `Packages/Shared/CMUXMobileCore`, then
`CMUX_E2E_SUITES="loopback_terminal_input_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`
(`mouse_drag_is_mouse_reports` and `mouse_survives_replay`).

### 687–689. A failed mirror tab stays out of the session; Mac wording (#689 RETIRED) — `device-reserved-pane-not-saved`, `device-pane-failure-mac-wording`

Found by the round-3 visual check: a mirror tab whose create failed while the link was down read "The
Cloud operation failed…" and came back after a relaunch as a local shell, first in the mirror. Fork
code: `SupermuxDevicePaneFailureText` (`SupermuxDeviceError.swift`, strings `supermux.devices.paneFailure.*`,
en + ja).

Re-apply after an upstream merge:
- **#687** keep the reserved device panes out of `allPanelIds` before the panel snapshots are taken.
  Retire it if upstream stops saving reserved Cloud panes itself (or restores them as placeholders).
- **#688** keep upstream's `CloudPaneCreationFailure` for every other machine; only a device machine
  gets the Mac text. Retire it if upstream words the card per machine kind.
- **#689 RETIRED** (round 4, mirror close): `device-close-cancel-restores-tab` in `Sources/Workspace.swift`
  (`SupermuxDeviceClosedTabs.shared.noteClosing(…)` in `splitTabBar(_:shouldCloseTab:inPane:)`) selected a busy
  mirror tab again after a Cancel in "Close “X” on <Mac>?". Every mirror-tab close now forces, so there is no Cancel;
  the fence and `SupermuxDeviceClosedTabs` are gone and `Workspace.swift` is upstream's there. Nothing to re-apply;
  do not reuse the number.

Verify: `CMUX_E2E_SUITES="loopback_new_tab_order_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`
(`failed_mirror_tab_not_restored_locally`).

### 695–696. A mirror closes like a local workspace; the phone closes a busy workspace — `ios-workspace-close-force`

User feedback (round 4) on the "Close “X”? — Close on <Mac> / Hide Here / Cancel" prompt: "it should just close when
i click close just like it does for local workspaces. same for terminal tabs, it should just kill the process and
close the tab just like it does for local." A user close of a mirror now meets only this Mac's own confirmations and
then closes the workspace on its Mac with `force` (#530; offline closes wait in the persisted
`supermux.devices.pendingRemoteCloses.v1` set and go out on reconnect, also after a relaunch); a mirror tab's close
always forces (#641). Hide Here stays in the row menus (#574). Fork code: `SupermuxDeviceMirrorCloser`; E2E:
`tests/supermux/loopback_mirror_workspace_close_e2e.py`.

Re-apply after an upstream merge:
- **#695 `MobileShellComposite+WorkspaceActions.swift`.** In `closeWorkspace(id:)`, build
  `supermuxCloseParams` from `workspaceMutationParams(id:)` with `"force": true` and pass it to the
  `workspace.close` `sendWorkspaceMutation`. Every phone close path asks "Delete Workspace?" first
  (`MobileWorkspaceCloseConfirmation`); if upstream adds one that does not, keep that one without force. Retire it if
  upstream forces this close itself.
- **#696 pbxproj.** Re-add the four entries of `Devices/SupermuxDeviceMirrorCloseSocketCommands.swift` with the
  `50BE00180200…` ids in the #696 row, then `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`.

Verify: `CMUX_E2E_SUITES="loopback_mirror_workspace_close_e2e loopback_mirror_tab_close_e2e loopback_auto_mirror_e2e"
CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh`; the phone leg by dogfood (close a Mac workspace running Claude
Code from the phone: it closes instead of "<Mac> rejected the request.").
