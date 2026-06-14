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
| 2 | `Sources/ContentView.swift` | `sidebar-projects-section`, `sidebar-hide-project-workspaces`, `sidebar-flatrow-activity`, `sidebar-selection-faint` | Mounts `SupermuxProjectsMount()` atop the sidebar; hides project-owned workspaces from the flat list; renders the agent-activity indicator on flat-list workspace rows; gives the flat-list selection the faint accent tint used by nested project rows |
| 3 | `cmux.xcodeproj/project.pbxproj` | `unfenced` | Wires the SupermuxKit package + `Sources/Supermux/` files into the cmux target, `cmuxTests/SupermuxSidebarBranchTests.swift` into the cmuxTests target, and the three `AppIcon*.icon` Icon Composer files into the app Resources phase (see #17) |
| 4 | `.github/swift-file-length-budget.tsv` | `unfenced` | Budget rows raised by exactly the fenced growth in their files (see #4 notes below) |
| 4b | `Resources/Localizable.xcstrings` | `unfenced` | Adds en+ja entries for all `supermux.*` keys (additive only; never edits non-supermux keys) |
| 5 | `Sources/RightSidebarPanelView.swift` | `right-sidebar-changes-mode-*` | Adds the `changes` right-sidebar mode (case/label/symbol/shortcut/rootsync) and renders `SupermuxChangesMount` for it |
| 6 | `Sources/RightSidebarMode+Availability.swift` | `right-sidebar-changes-mode-*` | `changes` is always available and reachable from the CLI mode argument |
| 7 | `Sources/RightSidebarToolPanel.swift` | `right-sidebar-changes-mode-*` | `.changes` joins the `.feed, .dock` no-op groups (sync/focus/intent/anchor, ×4) |
| 8 | `Sources/MainWindowFocusController.swift` | `right-sidebar-changes-mode-*` | Focus routing for the changes mode (host, no special endpoint) |
| 9 | `Sources/ContentView+RightSidebarCommandPalette.swift` | `right-sidebar-changes-mode-*` | Palette command id for "Show Changes"; not openable as a pane |
| 10 | `CLI/cmux.swift` | `right-sidebar-changes-mode-*` | CLI accepts `cmux right-sidebar set changes` (and the `changes` alias) |
| 11 | `Sources/KeyboardShortcutSettings.swift` | `run-toggle-shortcut-*` | `supermuxToggleRun` action (case/label/default ⌘G, shared with Find Next) |
| 12 | `Sources/AppDelegate.swift` | `run-toggle-shortcut-*` | ⌘G dispatch: Find Next while find overlay is open, run toggle otherwise |
| 13 | `.github/workflows/ci.yml` | `ci-package-tests` | Adds `SupermuxKit` to the SPM package-test allowlist so its tests gate CI |
| 14 | `web/data/cmux.schema.json` | `unfenced` | Adds `supermuxToggleRun` to the shortcut-action enum so cmux.json validation accepts rebinding it |
| 15 | `web/data/cmux-shortcuts.ts` | `run-toggle-shortcut-doc` | Documents the `supermuxToggleRun` ⌘G shortcut in the keyboard-shortcut registry |
| 16 | `Sources/WorkspaceContentView.swift` | `presets-bar` | Renders `SupermuxPresetsBarMount(workspace:)` above the splits (normal mode only); minimal mode keeps the original top-safe-area layout |
| 17 | `AppIcon.icon` | `unfenced` | App-icon rebrand (representative path; full family in the #17 re-apply note): supermux Icon Composer "Liquid Glass" `.icon` for Release + `AppIcon-Debug.icon` (DEV band) + `AppIcon-Nightly.icon` (NIGHTLY band); old PNG appiconsets deleted; `AppIcon{Light,Dark}` imagesets re-sourced from the rendered glass icon. Wiring lives in touchpoint #3. |
| 18 | `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/AutomationSection.swift` | `ai-settings` | Renders `SupermuxAISettingsCard` (Vercel AI Gateway API key + model) at the end of the Automation section, and stores the `secretStore` + `errorLog` the card needs. The card itself is a new supermux-owned file, `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/SupermuxAISettingsCard.swift` (no conflict on merge; lives in the upstream package only because the section stack is closed to app injection and cannot import `SupermuxKit`). |

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
4. In the row's title `HStack`, before `Text(workspaceSnapshot.title)`, render
   `SupermuxAgentActivityIndicator(activity:size:)` when `supermuxActivity.isVisible`.
The indicator is reactive via the existing workspace observation (it changes with
`statusEntries`/`progress`, which the snapshot already observes). If upstream restructures the
snapshot/row, the requirement is just: derive activity per workspace and render the indicator
beside the title.

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

### 3. `cmux.xcodeproj/project.pbxproj` — unfenced (comments are not safe there)

Fourteen ID-based additions, all using the reserved supermux ID prefix `50BE0001…`. To re-apply by
hand, mirror how `CmuxSocketControl` is wired and how `CmuxSidebarActionDispatch.swift` is
listed, with these exact IDs:

| ID | Section | Entry |
|----|---------|-------|
| `50BE000100000000000000A1` | XCLocalSwiftPackageReference | `relativePath = Packages/SupermuxKit` (also listed in the project's `packageReferences`) |
| `50BE000100000000000000A2` | XCSwiftPackageProductDependency | `productName = SupermuxKit` (also listed in the `cmux` target's `packageProductDependencies`) |
| `50BE000100000000000000A3` | PBXBuildFile | `SupermuxKit in Frameworks` (also listed in the `cmux` target's Frameworks phase `files`) |
| `50BE000100000000000000B1` | PBXFileReference | `SupermuxAppGlue.swift` |
| `50BE000100000000000000B2` | PBXBuildFile | `SupermuxAppGlue.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B3` | PBXGroup | group `Supermux` (path = `Supermux`, children = `…B1`, `…B4`), listed in the `A5001041 /* Sources */` group's `children` |
| `50BE000100000000000000B4` | PBXFileReference | `SupermuxRunSupport.swift` |
| `50BE000100000000000000B5` | PBXBuildFile | `SupermuxRunSupport.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B6` | PBXFileReference | `SupermuxWorkspaceActivityResolver.swift` (also listed in the `Supermux` group's `children`) |
| `50BE000100000000000000B7` | PBXBuildFile | `SupermuxWorkspaceActivityResolver.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000B8` | PBXFileReference | `SupermuxSidebarFontScaleStore.swift` (also listed in the `Supermux` group's `children`) |
| `50BE000100000000000000B9` | PBXBuildFile | `SupermuxSidebarFontScaleStore.swift in Sources` (also listed in the `cmux` target's Sources phase `files`) |
| `50BE000100000000000000C2` | PBXFileReference | `SupermuxSidebarBranchTests.swift` (also listed in the cmuxTests group's `children`) |
| `50BE000100000000000000C1` | PBXBuildFile | `SupermuxSidebarBranchTests.swift in Sources` (also listed in the `cmuxTests` target's Sources phase `files`) |

After re-applying run `python3 scripts/normalize-pbxproj.py && ./scripts/check-pbxproj.sh`.
Verification: `grep -c 50BE0001 cmux.xcodeproj/project.pbxproj` should print `29`.

### 4. `.github/swift-file-length-budget.tsv` — unfenced

Several rows carry supermux's fenced growth over upstream. Each was raised by exactly the
number of fenced lines added to that file — never to absorb unrelated debt:

| Row | Δ | Reason |
|-----|---|--------|
| `Sources/ContentView.swift` | +9, +14 | `sidebar-projects-section` mount (+3) and `sidebar-hide-project-workspaces` filter (+6); `sidebar-selection-faint` (+14: faint-tint `backgroundColor` + `usesInvertedActiveForeground` overrides). Budget also absorbed a pre-existing 2-line drift (HEAD file was 19297 vs a 19295 budget). |
| `Sources/WorkspaceContentView.swift` | +12 | `presets-bar` mount above the splits (if/else branch on minimal mode) |
| `Sources/RightSidebarPanelView.swift` | +18 | `right-sidebar-changes-mode-*` (case/label/symbol/shortcut/rootsync/content) |
| `Sources/RightSidebarToolPanel.swift` | (within budget) | `.changes` added to 4 existing case groups |
| `Sources/MainWindowFocusController.swift` | +10 | changes-mode focus routing |
| `Sources/KeyboardShortcutSettings.swift` | +13 | `supermuxToggleRun` action |
| `Sources/AppDelegate.swift` | +10 | `run-toggle-shortcut-dispatch` |
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
