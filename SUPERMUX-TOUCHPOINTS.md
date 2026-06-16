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
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + `AppIcon-Debug.icon` (DEV band) + `AppIcon-Nightly.icon` (NIGHTLY band); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered glass icon. Wiring lives in touchpoint #3. |
| 19 | `Sources/AppDelegate.swift` | `disable-auto-update` | Disables the Sparkle auto-updater: removes the launch-time `updateController.startUpdaterIfNeeded()` call so there is no launch/periodic update probe and no scheduled check, which means the sidebar "Update Available" pill never auto-appears. supermux ships updates via git merge from upstream, not Sparkle. |
| 18 | `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) at the end of the Automation section, and stores the `secretStore` + `errorLog` the card needs. The card itself is a new supermux-owned file, `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). |
| 20 | `Sources/GhosttyTerminalView.swift` | `browser-link-new-tab` | When a cmd-clicked terminal link opens in the embedded browser and there is no existing browser pane to reuse, open it as a new browser tab in the current pane (and switch to it) instead of creating a horizontal split |
| 21 | `Sources/App/ShortcutRoutingSupport.swift` | `run-toggle-shortcut-dispatch` | ⌘G (the supermux Run/Stop toggle, shared with Find Next) is never ceded to a focused browser's native find, so cmux always owns the chord (otherwise WebKit swallows ⌘G and it is a dead key in the browser) |
| 22 | `cmuxTests/AppDelegateShortcutRoutingTests.swift` | `run-toggle-shortcut-dispatch` | Updates the browser-find routing contract for ⌘G (run-toggle chord excluded from browser-first routing) and adds the regression test |
| 23 | `Sources/KeyboardShortcutSettings.swift` | `workspace-switcher-shortcut-case`, `workspace-switcher-shortcut-label`, `workspace-switcher-shortcut-default` | Adds the two workspace-switcher shortcut actions: `supermuxWorkspaceSwitcherNext` (default ⌘\`) and `supermuxWorkspaceSwitcherPrevious` (default ⇧⌘\`) |
| 24 | `Sources/AppDelegate.swift` | `workspace-switcher-monitor` | One hook in the app-local NSEvent monitor routes every event to `SupermuxComposition.workspaceSwitcher.handleMonitorEvent(_:appDelegate:)`: idle it acts only on the open chord; while presented it owns keyDown/keyUp/flagsChanged so it can cycle and commit on ⌘ release |
| 25 | `web/data/cmux-shortcuts.ts` | `workspace-switcher-shortcut-doc` | Documents the two workspace-switcher shortcuts in the keyboard-shortcut registry |
| 26 | `Packages/CmuxSettings/Sources/CmuxSettings/Policies/RightSidebarWidthSettings.swift` | `right-sidebar-min-width` | Lowers the right-sidebar minimum width floor from upstream's 276 to 200 so the panel can be dragged narrower (mode bar collapses to icon-only via touchpoint #5) |
| 27 | `cmuxTests/SidebarWidthPolicyTests.swift` | `right-sidebar-min-width-test` | Two right-sidebar clamp assertions read `RightSidebarWidthSettings.minimumWidth` instead of the hardcoded `276`, so they track the lowered floor |

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

Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `69`.

### 4. `.github/swift-file-length-budget.tsv` — unfenced

Several rows carry supermux's fenced growth over upstream. Each was raised by exactly the
number of fenced lines added to that file — never to absorb unrelated debt:

| Row | Δ | Reason |
|-----|---|--------|
| `Sources/ContentView.swift` | +9, +14, +28 | `sidebar-projects-section` mount (+3) and `sidebar-hide-project-workspaces` filter (+6); `sidebar-selection-faint` (+14: faint-tint `backgroundColor` + `usesInvertedActiveForeground` overrides); `sidebar-projects-empty-area` (+28: `@State` height + empty-area subtraction + `.onPreferenceChange` handler, 19311→19339). Budget also absorbed a pre-existing 2-line drift (HEAD file was 19297 vs a 19295 budget). |
| `Sources/WorkspaceContentView.swift` | +12 | `presets-bar` mount above the splits (if/else branch on minimal mode) |
| `Sources/RightSidebarPanelView.swift` | +18, +35 | `right-sidebar-changes-mode-*` (case/label/symbol/shortcut/rootsync/content, +18); `right-sidebar-compact-mode-bar` (+35: `ViewThatFits` wrapper with pinned trailing controls + `modeButtonsRow(showsLabels:)` helper + `showsLabel` pill param/conditional, 743→778) |
| `Sources/RightSidebarToolPanel.swift` | (within budget) | `.changes` added to 4 existing case groups |
| `Sources/MainWindowFocusController.swift` | +10 | changes-mode focus routing |
| `Sources/KeyboardShortcutSettings.swift` | +13, +18 | `supermuxToggleRun` action (+13); `workspace-switcher-shortcut-*` (+18: case/label/default for the two switcher actions, 2586→2604) |
| `Sources/AppDelegate.swift` | +10, +3, +10 | `run-toggle-shortcut-dispatch` (+10); `disable-auto-update` (+3: a 4-line fenced comment replaces the 1-line `startUpdaterIfNeeded()` call, 18128→18131); `workspace-switcher-monitor` (+10, 17791→17801) |
| `Sources/App/ShortcutRoutingSupport.swift` | +11 | `run-toggle-shortcut-dispatch` (⌘G never browser-first) |
| `cmuxTests/AppDelegateShortcutRoutingTests.swift` | +32 | `run-toggle-shortcut-dispatch` (contract update + regression test) |
| `CLI/cmux.swift` | +4 | `changes` CLI mode |

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
- `AppIcon.icon/` — Release. `icon.json` = a purple→blue `linear-gradient` fill + one
  `glass:true` layer `supermux.png` (the dark glass mark; opaque, so it reads as the dark
  mark and the gradient sits behind it). This is the source of truth from Icon Composer.
- `AppIcon-Debug.icon/` — copy of the base with a **DEV** band (`#FF6B00`) baked into the
  bottom of `supermux.png`.
- `AppIcon-Nightly.icon/` — copy with a **NIGHTLY** band (`#8C3CDC`) baked in.
- `Assets.xcassets/AppIcon{Light,Dark}.imageset/` — 1024 PNGs used by the dock-tile plugin
  (`Sources/AppIconDockTilePlugin.swift`, which overrides the *running* dock icon) and the
  Settings icon picker. Re-sourced from the actual rendered glass icon
  (`NSWorkspace.icon(forFile:)` of the built app), so the dock matches Finder.

Badge geometry: the system scales the 1024 layer into an 824×824 squircle at 100 px margin
(scale ≈ 0.8047), then masks. Bands are baked from mark-space `y≈815..1024` (full width) so
they land inside the squircle's lower band with rounded bottom corners; text is centered,
white, Arial-Bold. Badges inherit the layer's glass, so they read as glassy bands (fine for
dev/nightly distinction).

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

### 19. `Sources/AppDelegate.swift` — `disable-auto-update`

cmux uses Sparkle for auto-updates. On launch, `applicationDidFinishLaunching` sets the
update controller's delegate and starts the updater, which immediately probes the release feed
(and re-probes periodically + on Sparkle's schedule). When that probe finds a newer version, the
update controller's model flips to `.updateAvailable` and the sidebar footer renders the blue
"Update Available: x.y.z" pill (`UpdatePill` in `Sources/ContentView.swift`). supermux ships
updates by merging from upstream cmux via git, so this auto-update path is unwanted (it would
also offer to replace the supermux build with an upstream cmux release).

The fix removes only the launch-time auto-start. The `actionDelegate` assignment stays so the
manual "Check for Updates…" menu still works on explicit invocation (it calls
`startUpdaterIfNeeded()` itself, lazily). The fence replaces the single `startUpdaterIfNeeded()`
call:

```swift
            updateController.actionDelegate = self
            // SUPERMUX:begin disable-auto-update
            // supermux updates via git merge from upstream, not Sparkle — never auto-start the
            // updater (no launch/periodic probe, no scheduled checks → the pill never appears).
            // SUPERMUX:end disable-auto-update
```

If upstream restructures the updater bootstrap, the requirement is: do not call
`startUpdaterIfNeeded()` (or any equivalent that begins automatic/scheduled update checks)
automatically at launch, so the model never auto-transitions to `.updateAvailable` and the pill
never appears. Leaving the manual `checkForUpdates(_:)` menu path intact is fine — it only runs
on explicit user action.

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
