# Supermux

Supermux is a fork of [cmux](https://github.com/manaflow-ai/cmux) that adds the best parts of
superset/piggycode on top of cmux's experience: **sticky Projects**, first-class **worktree
creation**, a **Changes (git) panel**, **run actions**, and **terminal presets**.

**If you are an AI agent working in this repo: read this file completely before changing
anything.** It is the contract that keeps the fork mergeable with upstream cmux.

## What supermux adds (product goals)

1. **Projects (core feature).** A project is a *sticky* registered repo/folder — it stays in the
   sidebar forever, even when no workspace for it is open (like piggycode workspaces). From a
   project row you can:
   - open the project **locally** (a workspace at the repo root), or
   - **create a git worktree** (quick: name a branch, choose its starting branch, and get an isolated checkout + workspace).
   Projects have icons and colors: an avatar is auto-detected from the repo's logo/favicon, with
   a per-project **custom icon file** the user can pick in the editor to override detection (and a
   fallback SF Symbol or letter avatar). Worktrees created from a project are listed under it and
   can be cleaned up from the UI.
2. **Changes panel.** A right-sidebar git panel for the active workspace: changed files, diffs,
   stage/unstage/discard, commit, push/pull — quick git actions without leaving the keyboard.
   Clicking a file row opens that file's diff (staged or working-tree side, matching the section)
   in cmux's diff viewer as a browser tab beside the workspace; the next click replaces that tab.
3. **Run actions (⌘G).** Per-project start/stop dev-server commands with running-state display.
4. **Terminal presets.** Named terminal setups (command + cwd) launchable per project.
5. **Custom app actions** per project (open editor, open URL, arbitrary commands).
6. **Worktree setup/teardown scripts.** A per-project setup script runs in a fresh worktree right
   after it is created (e.g. `bun install`, `cp "$SUPERSET_ROOT_PATH/.env" .env`); a teardown
   script runs right before a worktree is removed. Setup/teardown/run/actions can be **auto-imported
   from a repo-shipped `.supermux/config.json` or `.superset/config.json`**, so a project ships its
   own onboarding (see "Worktree scripts & project config" below).
7. **AI integration (Vercel AI Gateway).** A single Vercel AI Gateway API key (pasted in
   Settings → Automation) powers supermux's AI features through the gateway's OpenAI-compatible
   Chat Completions API. First features: (a) **AI branch names** — when creating a worktree with a
   workspace name and a blank branch field, a lightweight model names the branch from the workspace
   description (falling back to a random name when AI is off or fails); (b) **AI commit messages** —
   in the Changes panel, an empty commit message turns the Commit button into "Generate & Commit",
   which stages all changes, asks the model for a Conventional-Commits message, and commits. The key
   is stored in a private `0600` file (never in `cmux.json`); the model is configurable.

8. **Start Claude from the New Worktree sheet (prompt-first).** The same New Worktree sheet
   (Mac hover ＋ / context menu; phone swipe, long-press menu, inline row, detail header) has a
   prompt field at the top. Leave it empty and it is the classic flow. Type a task and it becomes
   a Claude launch: blank workspace/branch fields are derived from the prompt (one AI call when the
   gateway key is set, an offline heuristic otherwise — typed values win), the worktree is created,
   and the workspace opens with its terminal already running the chosen **Claude command** with the
   prompt as its first message. The command list is user-editable (`claude`, `cc`, `ccx`, …
   — aliases and wrapper scripts resolve because launches run as interactive-shell input), and
   the **model picker shows the models that specific command advertises** (probed through the
   user's login shell with Claude's stream-json `initialize`, cached per command), with an effort
   picker scoped to the selection (the default model row takes effort too). The exact shell line
   is previewed in the sheet. Last model/effort is remembered per command. The line is typed into
   the new shell's pty before it leaves canonical mode, where macOS drops input past 1024 bytes,
   so a prompt that would not fit inline is saved under the cmux state directory
   (`supermux-agent-prompts/<sha256>.txt`, pruned after 7 days) and the line reads it with
   `"$(command cat -- …)"` (`(command cat -- … | string collect)` on fish).

9. **Remote Macs as first-class workspaces (Superset-style).** Every workspace on every one of the
   user's other Macs appears in the LEFT sidebar automatically, as a real local "mirror" workspace
   (terminals, tabs and splits stream from the owning Mac), nested under its project or loose in the
   list with a small Mac icon before its branch. Projects merge across Macs by git origin; the New
   Worktree sheet has a **device picker**; "New Workspace on ▸ <Mac>" (the `+` menu, the sidebar's
   empty-area menu) creates project-less workspaces remotely, while a plain New Workspace always stays
   on this Mac. Activity
   spinners, status pills, progress, logs, branch/PR, unread and notification banners mirror the
   owning Mac; closing a mirror closes it on its Mac like a local workspace (row menus also offer
   "Hide Here"). The phone gets pushes from the
   Mac that runs the agent, so the main Mac can be closed. Details: "Remote Macs (devices)" below and
   `plans/supermux-remote-workspaces/`.

Where cmux already has a primitive (workspace groups, Dock, `actions`/`commands` in cmux.json,
diff viewer, per-workspace git branch/dirty tracking), supermux **extends** it rather than
building a parallel system.

### Implementation status

| Goal | Status | Where |
|------|--------|-------|
| Sticky Projects (sidebar section, icons, colors, persisted) | ✅ | `SupermuxProjectsModel`, `SupermuxProjectStore`, `SupermuxProjectsSectionView`; mounted via the `sidebar-projects-section` touchpoint |
| Open local / create worktree from a project | ✅ | `SupermuxGitWorktreeService` (selectable starting branch; piggycode semantics: `--no-track -b`, `push.autoSetupRemote`, `branch.<n>.base`, dedup, exclude) |
| List / open / delete worktrees (dirty-checked), plus project-level Delete All Worktrees (clean ones go, dirty ones get a second confirm) | ✅ | `SupermuxGitWorktreeService.listWorktrees/removeWorktree`, `SupermuxProjectsModel+BulkWorktreeRemoval`, project row disclosure / context menu |
| Worktree PR badges (clickable, state-colored) | ✅ | opened worktrees reuse cmux's per-workspace `SidebarPullRequestState` (carried on `SupermuxOpenWorkspace.pullRequest`); unopened ones via `SupermuxWorktreePullRequestModel` + `SupermuxPullRequestProbe` (wrapping `CmuxGit.PullRequestProbeService`); both render `SupermuxPullRequestBadge`. SupermuxKit now depends on `CmuxGit`. |
| Changes (git) panel | ✅ | right-sidebar `changes` mode (`right-sidebar-changes-mode-*` touchpoints) → `SupermuxChangesPanelView` / `SupermuxChangesModel` / `SupermuxGitChangesService`; a file-row click captures `SupermuxChangesModel.fileDiffPatch` and `SupermuxFileDiffOpener` pipes it to the bundled `cmux diff -` CLI (upstream's viewer, one tab per workspace) |
| PR viewer in the Changes panel (header `#N` buttons per open PR, load-on-click detail: state, mergeability, reviews, checks, labels, description, files; refresh inside) | ✅ | `Packages/SupermuxKit/Sources/SupermuxKit/PullRequests/` (`SupermuxPullRequestDetail`, `SupermuxGitHubClient`, `SupermuxPullRequestDetailService`, `SupermuxPullRequestViewerModel`) + `SupermuxPullRequestViewerView` / `SupermuxPullRequestHeaderButton`; mounted by `SupermuxChangesMount` with `SupermuxChangesPullRequestObserver` (mirrors cmux's already-probed workspace PR into the header — no polling of its own). Auth: `GH_TOKEN`/`GITHUB_TOKEN` else `gh auth token`, same as cmux's probe |
| Run actions (⌘G start/stop) | ✅ | `supermuxToggleRun` shortcut (shares ⌘G with Find Next) → `SupermuxRunCoordinator` |
| Custom app actions + terminal presets (per project) | ✅ | `SupermuxProjectAction`, editor Actions section, project-row Actions submenu |
| Worktree setup/teardown + `config.json` import | ✅ | `SupermuxProjectConfig`(+`Loader`), `SupermuxWorktreeScript`/`SupermuxWorktreeEnvironment`; setup runs in a dedicated terminal via `SupermuxTabManagerOpener`, teardown headless in `SupermuxGitWorktreeService.removeWorktree`; import wired in `SupermuxProjectsModel` |
| AI integration (Vercel AI Gateway key + branch names + commit messages) | ✅ | `Packages/SupermuxKit/Sources/SupermuxKit/AI/` (`SupermuxAIConfig`, `SupermuxAIGatewayClient`, `SupermuxAIBranchNamer`, `SupermuxAICommitMessenger`); key UI via the `ai-settings` touchpoint (#18) → `SupermuxAISettingsCard`; wired in `SupermuxComposition`. Key in a `0600` secret file under the cmux state dir; model id (default `openai/gpt-5.4-mini`) editable in Settings, persisted in UserDefaults (`supermux.ai.model`). |
| Start Claude in a new worktree (prompt-first, per-command model catalog) | ✅ | `Packages/SupermuxKit/Sources/SupermuxKit/Agent/` (`SupermuxAgentLauncherSettings`, `SupermuxAgentModelCatalog` + `SupermuxAgentCommandProbePlan`, `SupermuxPromptNaming`, `SupermuxAgentLaunchCommand`, `SupermuxAgentWorktreeLauncher` — the one shared path), `AI/SupermuxAIWorktreeNamer`; Mac UI: the prompt path lives inside `UI/SupermuxNewWorktreeSheet(+Chips)` (shown when the selected Mac's target offers it), whose state and flow are `UI/SupermuxNewWorktreeSheetModel` over one `SupermuxWorktreeCreationTarget` per Mac (device picker: create on This Mac or another Mac with the project — `plans/supermux-remote-workspaces/PROJECTS-API.md`); wired in `SupermuxComposition.agentLaunch`. Catalogs cache in the harness `SupermuxHarnessModelCatalogStore` under `/supermux-agent-command/<cmd>` pseudo-paths |
| Localization (en + ja) | ✅ | macOS/app-target `supermux.*` keys in `Resources/Localizable.xcstrings`; the iOS screens package owns a SECOND catalog, `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/Resources/Localizable.xcstrings` (~207 keys). Regenerate with the scripts under "Localization" below |
| Remote Macs in the left sidebar (auto-mirror, close/hide, restart-stable bindings) | ✅ loopback-E2E | `Sources/Supermux/Devices/` (`SupermuxDevices` facade, `SupermuxDeviceWorkspaceIndex`, `SupermuxDeviceWorkspaceOpener`, `SupermuxDeviceMirrorCoordinator` + `SupermuxMirrorReconciler`), loop guard #518/#519, close hook #530 |
| Status parity on mirrors (activity, pills, progress, log, branch/PR, color/description/pin) | ✅ loopback-E2E | `SupermuxDeviceStatusProjector`, additive `supermux_status_entries/progress/log` record fields (#535/#536), flat-row fences #532/#533 |
| Projects across Macs (merge by git origin, remote-only rows, project sync, Set Up on <Mac>) | ✅ loopback-E2E | `Sources/Supermux/Projects/`, `SupermuxUnifiedProjects`, host RPCs `project.probe`/`project.clone`, `plans/supermux-remote-workspaces/PROJECTS-API.md` |
| New Worktree device picker + New Workspace on ▸ <Mac> | ✅ loopback-E2E | `SupermuxNewWorktreeSheetModel` over `SupermuxWorktreeCreationTarget` (local / remote), #570/#571, #620–#622 (plain New Workspace stays local; the empty area's menu; another Mac's home folder) |
| Mirror workspace behaviors (⌘G run, presets, Changes panel, file tools) | ✅ loopback-E2E | `Sources/Supermux/Mirrors/`, `SupermuxChangesBackend` (local / remote over `changes.*`), #572 |
| Files panel in a mirror browses the other Mac (list, preview, Find, git colors, live refresh, file operations) | ✅ loopback-E2E | `SupermuxDeviceFileExplorerProvider` over `files.*` (`supermux.files_read.v1`), #675–#681, `tests/supermux/loopback_mirror_files_e2e.py` |
| Background tab sync (tabs added/closed/reordered on the owning Mac reach mirrors) | ✅ loopback-E2E | `SupermuxDeviceLayoutChangeObserver`, #595 |
| Notification/push parity (no duplicate pushes, shared read state, presence-aware host, push setup shared between Macs) | ✅ loopback-E2E | #545–#550, `SupermuxDeviceNotification*`, `phone_push.status/share` |
| Remote Macs settings card (Settings › Automation) | ✅ | `SupermuxRemoteMacsSettingsCard` (#596–#598) |

Both phases are verified against a live tagged build (worktree creation, the Changes panel on
real git status, and the full ⌘G run→stop→restart cycle confirmed by an actually-listening dev
server port).

### Mobile (iOS companion) parity status

The iOS companion app remote-controls a paired supermux Mac over additive `mobile.supermux.*`
JSON-RPC methods (wire contract in `Packages/Shared/SupermuxMobileCore`; phone stores in
`Packages/iOS/SupermuxMobileKit`; screens in `Packages/iOS/SupermuxMobileUI`; Mac handlers in
`Sources/Supermux/SupermuxMobileHost+*.swift`). The Mac stays the sole source of truth (projects
file, git, AI keys). Every iOS entry point is capability-gated (`supermux.*.v1`), so a fork phone
paired with an upstream cmux Mac renders exactly upstream's UI.

> **Where the Projects UI is mounted on iPhone (read before touching the workspace list).**
> The iPhone renders the workspace list through a UIKit `UITableView`
> (`WorkspaceListTable`), not the SwiftUI `List`. Projects and workspaces are ONE list there, like
> the Mac sidebar: the table's leading run is a slim PROJECTS caption, then each project (merged
> across Macs) as its own row with its workspaces nested right under it as the shell's own
> indented workspace rows, then the shell's groups and loose workspaces — touchpoints #148–#151,
> #502 and #700–#702, projected by `SupermuxProjectsListLayout`. The SwiftUI
> `SupermuxProjectsMobileSection` mount (with per-Mac headers) is macOS-only. The session driver
> lives on the iOS `workspaceTable` (#97).
>
> This is the fork's most dangerous known failure mode, because it fails **silently and
> compiling**: upstream 0.64.20 moved the iOS list behind `#if os(iOS)` and left the fork's mount
> in the `#else` arm, which took the ENTIRE Projects surface — the section, project detail,
> worktrees, presets, run actions, custom actions and the project editor — off the phone from
> 2026-07-25 until it was restored. Nothing failed to build and no test went red; the parity table
> below simply kept claiming "✅ on iOS". After any upstream merge that touches
> `WorkspaceListView`, verify Projects on a real phone rather than trusting this table.

Status per fork feature area:

| # | Fork feature area | Mobile status | How / where |
|---|-------------------|---------------|-------------|
| 1 | Projects (sticky, full CRUD) | ✅ on iOS | `SupermuxProjectsListLayout` + `SupermuxProjectsTableRowView` (iPhone: one row per project in the workspace table, #148–#151) / `SupermuxProjectsMobileSection` (macOS `List`) + `SupermuxProjectDetailScreen` + `SupermuxProjectEditorSheet` over `projects.list` / `project.create/update/delete/open` |
| 2 | Project icons & colors | ✅ on iOS | custom icon via `project.icon` (base64 PNG, etag-cached `SupermuxProjectIconCache`) → SF Symbol → letter avatar tinted by `color_hex` |
| 3 | Worktrees (create/open/remove, starting branch, AI branch suggest) | ✅ on iOS | `SupermuxNewWorktreeSheet` + project-detail worktree rows over lazy `worktrees.list` branch snapshots (`include_branches`) / `worktree.suggest_branch/create/open/remove` (dirty removals require `force` after a phone-side confirm) |
| 4 | Worktree PR badges | ✅ on iOS | `SupermuxPullRequestDTO` (number/state/url; title optional-nil, matching the desktop probe) on `worktrees.list` rows |
| 5 | Changes (git) panel | ✅ on iOS | `SupermuxChangesScreen` / `SupermuxDiffScreen`: status, diffs, stage/unstage/discard, commit, AI commit message, push/pull, stash/pop, history over `changes.*` |
| 6 | Run actions | ✅ on iOS | project-row run menu + running indicator over `run.state/start/stop` |
| 7 | Terminal presets | ✅ on iOS | preset manager + editors (m2) and launcher (m4) over `preset.create/update/delete/launch` |
| 8 | Custom app actions | ✅ on iOS | `action.run`; `open_url`-classified actions return the URL and the phone opens it locally |
| 9 | Worktree setup/teardown scripts | ✅ mac-side execution, phone-triggered | scripts always run on the Mac when worktrees are created/removed from the phone; script lists editable in the phone's project editor (config-imported projects render read-only) |
| 10 | AI integration | ✅ mac-side only (by design) | the AI key/model never leave the Mac; the phone consumes results (`worktree.suggest_branch`, `changes.generate_commit_message`) and surfaces the `ai_unavailable` error when unconfigured |
| 11 | Workspace switcher | ✅ covered by existing surface — **deliberate decision** | the existing iOS workspace list already is the mobile switcher; no new switcher UI was built. Workspace selection and the focused panel sync bidirectionally with the Mac: v1 preserves terminal-only compatibility, while `supermux.selection_sync.v2` covers terminals, browser tabs, Simulator tabs, and forward-compatible future panel kinds. Phone-created panels request atomic Mac focus before the create reply, and browser/Simulator streams wait for the ordered focus operation before starting, so a newly opened or selected tab is immediately visible and operable on both devices |
| 12 | Agent activity indicators | ✅ on iOS | additive `supermux_activity` travels for project-associated and global workspaces; the real iPhone `UITableView` row mounts `SupermuxWorkspaceActivityDot` and shows the amber working spinner whenever any tab's agent is running or waiting on its background work (upstream's "Waiting") |
| 13 | File explorer ops | ✅ on iOS | `SupermuxFileBrowserScreen` (browse, new file/folder, rename, duplicate, trash — never `rm`) over root-confined `files.*`; doubles as the project editor's folder picker |
| 14 | Project association / nesting | ✅ on iOS | additive `supermux_project_id` field nests loose project-owned workspaces right under their project as the shell's own workspace rows (swipes, menu, unread, preview, selection all upstream's), pinned first, then by Mac; a workspace in a cmux group stays in its group; a search or a filter-menu filter flattens the list. One function (`SupermuxProjectsListLayout.nestedWorkspaceIDs`) decides both the nesting and the flat-list hide, so each workspace shows once; nested rows are not reorderable (#700). A project's open workspaces are also listed in its detail screen |
| 15 | Empty-home behavior | mac-side only — **deliberate decision** | pure macOS window behavior; the mobile close path is already handled by touchpoint #71. No iOS surface (recorded mission decision) |
| 16 | Sidebar polish (font scale, switcher cards, list filter) | mac-side only | pure macOS sidebar cosmetics with no mobile analogue; the phone's Projects section has its own mobile-native styling |
| 17 | Unread badge (one design, both devices) | ✅ on iOS | additive `supermux_unread_count` field + `SupermuxUnreadBadgeStyle`/`SupermuxUnreadBadgeContent` in `SupermuxMobileCore`, wrapped per platform (`SupermuxUnreadBadgeView` on the Mac, `SupermuxMobileUnreadBadge` on the phone) and mirrored by the AppKit sidebar's Core Graphics renderer. Both apps now draw the same gradient capsule with localized overflow; the phone wrapper follows Dynamic Type, and its old permanently reserved unread gutter is gone. Touchpoints #261–#284, #291, #297–#298 |
| 18 | Agent-completion push notifications | ✅ on iOS | The fixed `com.supermux.ios` build mirrors its sandbox APNs token to the paired Mac over `mobile.supermux.phone_push.register`. The Mac signs topic-restricted ES256 provider requests from a local-only key and forwards through the same `TerminalNotificationStore` admission, focus-suppression, forwarding-mode, and hide-content policy as cloud push. Visible alerts work while the app is foregrounded, backgrounded, locked, or terminated; the phone suppresses a foreground banner only when it already shows the exact target terminal. Touchpoints #331–#333 |

| 19 | Usage limits (Claude Code + Codex) | ✅ on iOS, read-only by design | a gauge ring in the workspace-list toolbar, filled to the tightest limit across both providers, opening `SupermuxUsageScreen`: window meters with reset countdowns and the ahead-of-pace marker, the other cswap accounts, provider notes (not configured / re-login / offline session log), and the honest oldest-measurement footer. The Mac projects its EXISTING `SupermuxUsageModel` — the same one the sidebar popover renders — over `mobile.supermux.usage.state`; credentials, polling, and the rate-limit floor all stay Mac-side. **cswap account switching is deliberately not ported**: it mutates which account Claude Code is logged in as, and that decision belongs at the machine doing the work. Touchpoints #340–#341 |
| 20 | Start Claude from the New Worktree sheet | ✅ on iOS | the iOS `SupermuxNewWorktreeSheet` gains a prompt field and a Claude section (`SupermuxNewWorktreeClaudeSection`) over `mobile.supermux.agent.options` / `agent.start`, gated on `supermux.agent_launch.v1`; store `SupermuxMobileAgentLaunchStore` (MobileKit), loaded alongside the branch snapshot in `requestNewWorktree` / the detail screen's prepare. No extra entry points: every existing New Worktree affordance reaches it. Commands, catalogs, naming, git, and the terminal launch stay Mac-side (the phone cannot edit the command list; do that in the Mac sheet) |
| 21 | Projects and worktrees on every connected Mac | ✅ on iOS | per-Mac seams (`supermuxConnectionSeams`, #580–#586), one Supermux session per Mac, projects merged across Macs with the Mac sidebar's rule (`SupermuxPhoneProjectMerge`: unique git origin, else name + standardized root; one location per Mac) and a Mac marker on nested rows only when a project spans Macs (no per-Mac headers on iPhone), the Mac title picker scoping the block to that Mac, a Mac picker in New Worktree for Macs with the same repo (same merge rule), navigation that maps Mac-local ids to the right Mac's row, push registration with every Mac |

**Recorded non-goals** (deliberate, may be revisited later):

- **iOS GUI Agent Chat / Focus Mode** — upstream removed the transcript/composer UI in #10576;
  Supermux follows upstream and does not restore the dependent Focus Mode feature. Retained
  artifact/event and `mobile.chat.*` infrastructure remains upstream-owned plumbing, not a fork UI.
- `files.read` (file **preview** on the phone) — stretch goal, not required for parity; the file
  browser manages entries without reading contents.
- Push/pull **job-progress events** — reserved; v1 serves `changes.push`/`changes.pull` over a
  single RPC with an extended phone-side deadline (180 s, `SupermuxChangesSyncDeadline`).
- Live device pairing is validated by the user's manual per-milestone demos, not automation.

### Localization

All supermux user-facing strings use `String(localized: "supermux.<area>.<name>", defaultValue:
"English")`, with `en` + `ja` entries (cmux's two required locales). Interpolated strings
(`\(path)`, counts) are stored as `%@` / `%lld` format strings.

There are **two** catalogs, not one:

1. `Resources/Localizable.xcstrings` (the app catalog) holds every macOS key, **including keys
   used from macOS packages** — cmux packages resolve `String(localized:)` against the **app**
   bundle (`Bundle.main`), so a package string still needs its entry here (e.g. the #62c settings
   display names).
2. `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/Resources/Localizable.xcstrings` — the
   iOS screens package resolves against its own bundle and owns ~207 `supermux.*` keys. A package
   test parses it and fails on any missing/empty translation.

When adding an iOS-visible string, put it in catalog 2; a macOS one in catalog 1. Do not assume a
single catalog — an earlier version of this note claimed one and it was wrong.

To refresh after adding/changing supermux strings, re-run the audit tooling kept under
`scripts/` (`supermux-extract-loc-keys.py` → format → translate → `supermux-merge-loc.py`); the
merge is idempotent and only ever touches `supermux.*` keys, so the existing catalog stays
byte-stable.

### Worktree scripts & project config

A project carries `setupCommands` / `teardownCommands` (alongside `runCommands` / `actions`).

- **Setup** runs once, right after a worktree is created. `SupermuxTabManagerOpener` opens the
  worktree workspace with a clean main terminal and spawns **one dedicated, focused setup terminal**
  that runs the script through the interactive shell (so aliases resolve, and a trailing `exit`
  closes only that tab). Re-opening an existing worktree never re-runs setup.
- **Teardown** runs headless in `SupermuxGitWorktreeService.removeWorktree`, *after* the dirty
  guard and *before* `git worktree remove`, as `env KEY=VALUE … $SHELL -lc <script>` (login shell
  for `PATH`/tooling; non-interactive, so `.zshrc` aliases are absent). It is best-effort — a
  non-zero exit or timeout (120 s) is logged and never blocks removal.

**Environment** exported into both scripts (`SupermuxWorktreeEnvironment`):

| Variable | Value |
|----------|-------|
| `SUPERSET_ROOT_PATH` | main project checkout (kept for superset/piggycode script compatibility) |
| `SUPERMUX_ROOT_PATH` | same as above (fork-native alias) |
| `SUPERMUX_WORKTREE_PATH` | the new worktree's absolute path |

This is what makes `cp "$SUPERSET_ROOT_PATH/.env" .env` work inside a fresh worktree.

**Config import.** If a project root contains `.supermux/config.json` (preferred) or
`.superset/config.json`, `SupermuxProjectsModel` imports it — overwriting `setup`/`teardown`/`run`/
`actions` (config is the source of truth) — on add, on load, and before each worktree
create/remove. When a config is present those four fields are **read-only in the editor** (a note
points at the file). Config shape:

```json
{
  "setup": ["bun install\ncp \"$SUPERSET_ROOT_PATH/.env\" .env\nexit"],
  "teardown": ["./.superset/teardown.sh"],
  "run": ["bun run dev"],
  "actions": [{ "id": "…", "name": "Open GitHub", "command": "open …", "icon": "deploy" }]
}
```

Action `icon` accepts superset keywords (`bolt`, `build`, `deploy`, …) mapped to SF Symbols, or a
raw SF Symbol; action `id` keeps a valid UUID, otherwise derives a deterministic one so re-imports
stay idempotent. All of this lives in supermux-owned files — no new upstream touchpoints.

### Remote Macs (devices)

The user's other Macs (same account, same app identity) are linked by upstream's Mac-to-Mac
Devices layer (`Sources/Devices/*`, iroh). Supermux turns that into first-class workspaces:

- **Auto-mirror.** `SupermuxDeviceMirrorCoordinator` keeps exactly one local mirror workspace per
  remote workspace (setting "Show other Macs' workspaces in the sidebar"). Mirrors land in the
  window already holding that Mac's mirrors, survive restarts (bindings keyed by
  `Workspace.stableId`), close by themselves when the remote workspace closes, and are never
  re-exported by this Mac's mobile host (the loop guard; the phone talks to every Mac directly).
- **Closing a mirror** works like closing a local workspace: only this Mac's own confirmations
  (pinned, running process, the close settings, the batch "Close workspaces?"), no prompt of the
  fork's; then the mirror closes here at once and the real workspace closes on its Mac (with
  `force`; a workspace pinned there is unpinned there first). While that Mac is offline the close
  waits (persisted, so also across a relaunch) and auto-mirror does not show the workspace again;
  it is sent once that Mac is back. A refusal beeps and the mirror comes back. Mirror rows' menus
  also offer **Hide Here** (keeps it running there; "Show Hidden Remote Workspaces" brings it back);
  socket/CLI/AppleScript closes of a mirror stay Hide Here. Closing a mirrored tab ends that
  terminal on the owning Mac like a local tab, even when a program runs there (always `force`); a
  tab closed while that Mac is unreachable disappears at once and its close is sent first when the
  link is back (#530, #640–#644). The phone's workspace close forces too, after its own
  "Delete Workspace?" (#695).
- **Agent activity** (#715–#719): the amber working spinner shows while an agent runs and while it is
  "Waiting" (its turn ended with background shells, subagents or crons still running; upstream's grey
  Waiting pill stays beside it and the done notification still waits for the work to finish), on
  every row, mirror and the phone. Each terminal or Claude harness tab that is working shows
  Bonsplit's own tab spinner (in the tab's text colour; the unread dot is unchanged), in workspaces,
  the Dock and mirrors (the other Mac sends `supermux_working_panel_ids`; an older Mac's mirror tabs
  show none). A working tab keeps spinning when it moves to another workspace, into the Dock, or
  appears in a mirror after the agent started.
- **Sidebar rows:** inside a project, this Mac's workspaces come first, then each Mac's mirrors;
  every mirror row (nested or flat) marks its Mac with a small Mac + cloud icon right before its
  branch name (the Mac's name in its tooltip); nested rows show no `cmux set-status` pills or
  progress (the working spinner is their status), flat rows do.
- **Projects** merge across Macs by normalized git origin (`SupermuxGitRemoteIdentity`), else by
  identical name + path. Project sync (setting) registers a Mac's projects on the other Mac when the
  same repo already exists at the same path; it never clones or deletes. "Set Up on <Mac>…" adds an
  existing folder or clones there.
- **Creating remotely** is always an explicit choice: the New Worktree sheet's device picker (the
  last Mac the user chose for a worktree is preselected in every project, link states live while the
  sheet is open) and "New Workspace on ▸ <Mac>" in every New Workspace menu and in the sidebar empty
  area's context menu (#622). A workspace created there without a directory starts in that Mac's home
  folder, not in whatever that Mac has selected (#621). The new workspace's mirror opens and is
  selected in the clicking window; the owning Mac opens the workspace in the background
  (`select: false`), so its window never switches under whoever is using it. A link that drops after
  the create went out says the outcome is unknown and to check that Mac's worktrees, instead of
  inviting a duplicate. The submenu starts with This Mac.
- **A selected mirror is context, not a target:** a plain `+`, ⌘N, File > New Workspace and a
  double-click on the sidebar's empty area create on THIS Mac even while a mirror is selected (#571,
  #620), exactly as before mirrors existed (the empty area: last row, root of the list, home /
  Ghostty-default directory), so the `+` menu checks This Mac and the `+` tooltip is upstream's. A
  local workspace never inherits a selected mirror's directory (a path on the other Mac, #577).
- **Typing in a mirror is typing on that Mac** (#630–#639, capability `supermux.terminal_input.v1`):
  every key press travels to the owning Mac as a key event and is encoded there by that Mac's own
  Ghostty (kitty keyboard flags, cursor-key mode), in order with the mirror's paste, mouse and
  binding bytes, which reach the PTY exactly; the mirror's own answers to terminal queries are
  dropped. A pending Ghostty key sequence stays local. An older Mac on either side keeps upstream's
  text path.
- **Terminal size follows the Mac you look from** (upstream's shared sizing, #633, #665–#669): every
  terminal starts as Priority with this Mac first (its own pane for a local terminal, so a phone
  defers to a Mac pane on screen); a mirror claims the other Mac's terminal when it is shown, first
  attaches while shown, or reconnects, pushing once per connection and never in answer to that Mac's
  size events, so of two viewing Macs the one that showed it last wins. The mode, fixed size and
  priority order chosen in the size panel or the tab menu are one sticky choice per Mac
  (`supermux.terminalSizing.preference`; the panel says "Applies to all terminals on this Mac."),
  applied to every local terminal and mirror, now and after a relaunch. Cloud terminals,
  `terminal.size_policy.set`, a phone's or another Mac's choice, Size to My Window and Don't Resize
  from This Mac stay per terminal. A viewing Mac's pane counts up to 500x200 (a phone's, 300x120). A
  pane that is not on screen (a tab never shown on its Mac, a mirror in a background workspace, a hidden
  or fully covered window) does not count, so a tab opened from a mirror takes the mirror's size at
  once; a terminal that starts after its grid was decided gets it when it becomes ready. A
  terminal's tab draws no avatar for the attached Macs (#720); its context menu keeps Size to My
  Window, Terminal Size and Disconnect Others, and the size panel lists who is attached.
- **A mirror uses this Mac's terminal appearance** (#650–#653): the owning Mac's replay carries no
  theme colors, so a mirror pane shares the window's (translucent) backdrop exactly like a local
  pane; only colors a program on the other Mac set itself (OSC 4/10/11/12) are mirrored, and its
  reset gives the backdrop back.
- **New tabs append, on both Macs** (#660–#664): every new tab goes to the end of its tab strip
  (workspaces and the Dock; upstream inserted after the selected tab, which a Mac hosting a mirrored
  workspace never moves off its first tab, so tabs opened from a mirror landed second). "New
  Terminal to the Right" in a mirror lands right of its tab there and on the owning Mac (capability
  `supermux.terminal_placement.v1`; an older owning Mac appends it).
- **Inside a mirror**, ⌘G/Run, presets, project actions and the Changes panel act on the owning Mac
  over `mobile.supermux.*` (Generate & Commit follows that Mac's own AI-key rule); Finder/editor
  actions and the full diff view, which need a local path, are disabled with an "On <Mac>" hint.
- **The Files panel in a mirror is that Mac's folder** (#675–#681, capability
  `supermux.files_read.v1`): the workspace's current folder there (it follows a `cd`), hidden files
  listed as the local panel lists them (`.git` included; git internals are readable, never
  mutable), that Mac's git colors, Find (ripgrep over there), live refresh, a read-only preview on
  double-click/Return/search hit (downloaded, 8 MB cap), and New
  File/New Folder/Rename/Duplicate/Move to Trash run there. Every call is confined to that folder
  (`..`, symlinks out of it and a stale folder are refused). That Mac answers every call within a
  bound (30 s; 300 s for Duplicate and Move to Trash, which keep running there) and the link's
  reply deadline outlasts it, runs one `git status` per folder at a time, and refuses previews and
  Find while its `DisableFileTransfer` policy is on. Not offered: editing a preview, Open
  Externally, Reveal in Finder, drag out; a symlink out of the folder lists but does not open; a
  folder over 10,000 entries lists the first 10,000. The panel names the Mac when it cannot browse:
  not connected, loading, "Update Supermux on <Mac> to browse its files here." (an older Mac), or no
  folder reported yet.
  Live refresh follows the local panel's rule: the panel leases `files.watch` on that Mac, a
  watcher on the folder's own entries (the local panel's `FileWatcher`, not the recursive Changes
  watcher), and an entry added, removed or renamed there (or a reconnect, which re-leases) refreshes
  it **in place**: the root and expanded folders are listed again and merged into the rows shown,
  so it never empties or shows the spinner, expansion, selection and scroll stay, rows are rebuilt
  only when a listing changed and git colors are published only when they changed. As locally,
  edits deeper in the tree (`.git/` included) do not refresh it, so their git colors update on the
  next root-entry change, `cd` or reconnect. Both Macs need this build (an earlier
  `files_read.v1` host refuses `files.watch`; the panel then refreshes only on reconnect and `cd`).
- **Notifications:** the owning Mac pushes to the phone (the viewer never forwards `.deviceMac`
  rows, so no duplicates); the phone badges the total over every pairable Mac build; read state
  flows both ways, and mirrored notifications (read state and Mark as Unread included) survive a
  relaunch of the viewer; a notification for the pane you are looking at (a mirror's or a local
  one) rings and badges like any other until you click or type in it, with no banner, and is not
  pushed to the phone while you are at the Mac (an away or locked Mac still pushes it); Macs share the direct-APNs setup and phone tokens
  with each other (setting, default on; the key only travels to a same-account Mac over the
  authenticated link and never overwrites a different key).
- **Enablement:** the Supermux release identity seeds Beta › Cloud Machines, "Discover other Macs"
  and "Make this Mac discoverable" on once (#520). Both Macs must run the same app identity
  (`com.supermux.app`, tag `default`), be signed in to the same account and team, and stay awake
  with Supermux running on the Mac that hosts the work.
- **Testing:** real links need two machines, so DEBUG builds have a loopback device
  (`SUPERMUX_DEBUG_LOOPBACK_DEVICE=1`) whose link talks in-process to the same app's host. Run
  `CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh` against a `--supermux-profile` tagged
  build; see `plans/supermux-remote-workspaces/LOOPBACK-HARNESS.md`.

## Fork management — THE RULES

The single most important constraint: **upstream merges must stay cheap.** The user regularly
pulls cmux upstream and hates conflicts. Every line of supermux code is written to minimize the
conflict surface:

1. **New code lives in new files.** Supermux features are implemented in:
   - `Packages/SupermuxKit/` — macOS domain models, services, persistence (Swift Package).
   - `Sources/Supermux/` — app-target UI + glue that needs app types (new files only).
   - `Packages/Shared/SupermuxMobileCore/` — the `mobile.supermux.*` wire contract.
   - `Packages/iOS/SupermuxMobileKit/` — iOS domain layer (Mac client, stores, capability gate).
   - `Packages/iOS/SupermuxMobileUI/` — iOS screens + its own localization catalog.
   New files never conflict on merge. (The `supermux-check-touchpoints.sh` fence-registration scan
   skips only `Packages/SupermuxKit/` and `Sources/Supermux/`, so the three mobile packages still
   need registered fences if they ever edit upstream code — today they do not.)
2. **Upstream files are touched only at registered touchpoints.** When wiring into an upstream
   file is unavoidable (composition root, sidebar mount, menu/shortcut registration), the edit
   must be:
   - **as small as possible** (ideally 1–3 lines calling out to supermux code),
   - **fenced** with `// SUPERMUX:begin <id>` … `// SUPERMUX:end <id>` comments,
   - **registered** in [`SUPERMUX-TOUCHPOINTS.md`](SUPERMUX-TOUCHPOINTS.md) with the file, the
     fence id, what it does, and how to re-apply it by hand.
   If a merge conflict destroys a touchpoint, it can be re-applied mechanically from that file.
3. **Prefer extensions over edits.** Swift extensions in *new* files (`Foo+Supermux.swift`) can
   add behavior to upstream types without touching their files. Use this wherever possible.
4. **Never refactor upstream code** for style, naming, or cleanliness. Even good refactors
   create merge debt. If upstream code blocks a feature, write the smallest fenced hook and put
   the logic in supermux files.
5. **`git rerere` is enabled** in this repo (`rerere.enabled=true`, `rerere.autoupdate=true`) so
   resolved conflicts are remembered and auto-replayed on future merges.

## Upstream merge playbook

When the user says "pull from upstream" / "merge cmux updates", do this:

```bash
# 0. Clean tree required
git status --porcelain          # must be empty; stash/commit first otherwise

# 1. Fetch and inspect what's coming
git fetch upstream
git log --oneline HEAD..upstream/main | head -50   # eyeball the incoming changes
#    Which touchpoint files did upstream touch? Those need attention.
#    (The old one-liner here was broken: its /^\| `/ pattern matched ZERO registry rows — rows
#     start "| 17 | `path`" — and $2 is the row NUMBER, so it printed pbxproj hex UUIDs. This
#     form reads the path out of field 3 of every numbered row; ~350 unique paths today.)
git diff --stat HEAD...upstream/main -- \
  $(awk -F'|' '/^\| *[0-9]/{gsub(/[ `]/,"",$3); if ($3 != "") print $3}' SUPERMUX-TOUCHPOINTS.md | sort -u)

# 2. Merge (NOT rebase — merge keeps our history stable and rerere effective)
git merge upstream/main

# 3. If conflicts:
#    - For files NOT in SUPERMUX-TOUCHPOINTS.md: take upstream's side unless the conflict is in a
#      fork-owned dir (ours): Sources/Supermux/, Packages/SupermuxKit/,
#      Packages/Shared/SupermuxMobileCore/, Packages/iOS/SupermuxMobile{Kit,UI}/.
#    - For touchpoint files: take upstream's version of the surrounding code, then re-apply the
#      fenced SUPERMUX block per SUPERMUX-TOUCHPOINTS.md instructions.
#    - git grep -n "SUPERMUX:begin" -- ':!SUPERMUX*.md' — verify every registered fence still
#      exists. Do NOT scope this to Sources/ Packages/ cmux.xcodeproj/ (the old advice): live
#      fences also sit in CLI/, cmuxTests/, cmuxCLITestSupport/, cmuxUITests/, web/data/,
#      .github/workflows/ (ci.yml, ci-macos.yml, ci-guards.yml, …), scripts/ (incl. scripts/ci/),
#      ios/, docs/, skills/, tests/, .gitignore, CLAUDE.md and every README.<lang>.md.

# 4. Verify integrity
./scripts/supermux-check-touchpoints.sh    # all fences present + manifest in sync

# 5. Submodules may have moved
git submodule update --init --recursive
./scripts/ensure-ghosttykit.sh

# 6. Build + test
./scripts/reload.sh --tag upstream-merge
# run the supermux unit tests too (see Building below)

# 7. Commit the merge, summarize for the user what came in and what needed manual resolution.

# 8. Add a section to SUPERMUX-UPGRADES.md: what a supermux USER notices after this update
#    (changed shortcut defaults, changed behavior, new upstream features, fixes they will feel,
#    what should feel identical, watch-outs, and any open decision the merge surfaced).
#    Mechanical detail stays in SUPERMUX-TOUCHPOINTS.md; this is the human-readable log.
```

Conflict heuristics:
- `project.pbxproj` conflicts: keep upstream's changes AND our package/file references. Our
  pbxproj additions are registered as touchpoints. Re-run `scripts/normalize-pbxproj.py` and
  `scripts/check-pbxproj.sh` after resolving.
- `Resources/Localizable.xcstrings` conflicts: it's JSON; union both sides' keys. Fork keys almost
  all start with `supermux.`, but there is ONE deliberate exception the fork rewrites in place —
  `settings.search.alias.setting.app.workspace-inherit-working-directory` (touchpoint #84,
  registered under #4b). Take the fork side for that one; union everything else. (The former second
  exception, `…workspaceInheritWorkingDirectory.subtitleOff`, retired with #82 at the 2026-09-30
  merge — upstream deleted the key.) Never keep a fork-side deletion of a key upstream code still
  reads.
- If upstream added a feature that overlaps a supermux feature (e.g. they build their own
  projects concept), STOP and present options to the user instead of auto-resolving.

## Repo layout (supermux-owned)

| Path | Purpose |
|------|---------|
| `SUPERMUX.md` | This file — fork context, rules, merge playbook |
| `SUPERMUX-TOUCHPOINTS.md` | Registry of every modified upstream file |
| `SUPERMUX-UPGRADES.md` | User-facing "what changes for you" notes, one section per upstream merge |
| `Packages/SupermuxKit/` | Supermux macOS domain package (models, services, persistence) |
| `Sources/Supermux/` | App-target UI and glue code (new files only) |
| `Packages/Shared/SupermuxMobileCore/` | `mobile.supermux.*` wire contract shared by Mac + phone |
| `Packages/iOS/SupermuxMobileKit/` | iOS domain layer (Mac client, stores, capability gate) |
| `Packages/iOS/SupermuxMobileUI/` | iOS screens + its own `Localizable.xcstrings` |
| `scripts/supermux-check-touchpoints.sh` | CI/manual check that fences and manifest agree |
| `cmuxTests/Supermux*` | Unit tests for supermux code |
| `Sources/Supermux/Devices/`, `Mirrors/`, `Projects/` | Remote Macs: device facade, auto-mirror, mirror behaviors, projects across Macs |
| `tests/supermux/` | Loopback-device E2E suites + `run_all_loopback_e2e.sh` (reports under `tests/supermux/artifacts/`, gitignored) |
| `plans/supermux-remote-workspaces/` | Design and API notes for remote Macs (DESIGN, FOUNDATION-API, PROJECTS-API, LOOPBACK-HARNESS) |

## Building

### ⚠️ NEVER run app-hosted test suites on the user's machine

`xcodebuild test` on the `cmux-unit` / `cmux` schemes launches the **real cmux app as the test
host in the user's login session**. Suites like `TabManagerUnitTests`,
`WorkspaceContentViewVisibilityTests`, and most of `cmuxTests` create real `NSWindow`s and
workspaces — a single run opens dozens of windows on the user's desktop and pegs the machine;
running the suite twice doubles it. This has burned the user more than once. Hard rules:

1. **Do not run `cmuxTests` / `cmuxUITests` locally** (any `-only-testing:` subset included)
   unless the user explicitly asks for a local run in this session.
2. To verify app-target tests still **compile** after a change/merge, use
   `xcodebuild build-for-testing -scheme cmux-unit -derivedDataPath /tmp/cmux-<tag>` — it
   compiles the test target with zero app launches.
3. To verify **behavior**, run the SPM package tests (`swift test` in `Packages/SupermuxKit`,
   `Packages/macOS/CmuxSettings`, `Packages/macOS/CmuxSettingsUI`, …) — they are headless — and
   let GitHub Actions run the app-hosted suites.
4. To inspect a past run's failures, read the `.xcresult` bundle with `xcrun xcresulttool`
   instead of re-running the tests.

Same as cmux (see `AGENTS.md`): `./scripts/setup.sh` once, then

> **Toolchain note:** the app build's "Ghostty CLI helper" script phase pins an **exact** zig
> version, and `scripts/build-ghostty-cli-helper.sh` derives it from
> `ghostty/build.zig.zon`'s `.minimum_zig_version` (**0.16.0** since the 0.65 merge — this note
> previously hardcoded 0.15.2, which the submodule bump invalidated). Homebrew's zig is used only
> if its `zig version` matches exactly. Read the required value with
> `grep minimum_zig_version ghostty/build.zig.zon`; if a build fails with
> "zig <version> is required", install that exact version (or run
> `ZIG_REQUIRED=<version> ./scripts/install-zig-ci.sh`) and make sure it is on the helper's probe
> path. Also note: prebuilt GhosttyKit is fetched by `./scripts/ensure-ghosttykit.sh` (no zig
> needed for that).
>
> **Rust (since the 0.64.20 upstream merge):** upstream's diff viewer builds a Rust sidecar
> (`Native/DiffSidecar`, "Build Diff Sidecar" script phase) and requires **rustup** with the
> pinned toolchain from `Native/DiffSidecar/rust-toolchain.toml` (currently 1.88.0). On this
> machine rustup is installed user-locally in `~/.cargo`/`~/.rustup` (no shell-profile edits;
> the build phase finds it via its own PATH fallback). If a build fails with "rustup is
> required", run: `rustup toolchain install 1.88.0 --profile minimal --component clippy,rustfmt
> && rustup target add --toolchain 1.88.0 aarch64-apple-darwin x86_64-apple-darwin`.

```bash
./scripts/reload.sh --tag <your-tag>            # build Debug app
./scripts/reload.sh --tag <your-tag> --launch   # build + launch
```

Constraints inherited from upstream that supermux code MUST follow:
- Keep Swift files small (~500 lines is still the house style from
  `skills/cmux-architecture/SKILL.md`), but note this is **no longer CI-enforced**: upstream
  removed the whole Swift file-length budget system at the 0.65 merge
  (`.github/swift-file-length-budget.tsv` and `scripts/swift_file_length_budget.py` are both
  deleted — see SUPERMUX-TOUCHPOINTS.md #4, RETIRED). The only remaining budget gate in
  `.github/workflows/` (`ci-macos.yml` / `ci-guards.yml` since upstream split `ci.yml` at the
  2026-09-30 merge) is `scripts/swift_warning_budget.py`, which caps Swift **warnings**,
  not file length (CI runs the script itself plus its regression wrapper
  `./tests/test_ci_swift_warning_budget.sh`).
- All user-facing strings localized via `String(localized:)` with keys in
  `Resources/Localizable.xcstrings` (supermux keys are prefixed `supermux.`).
- New code follows `skills/cmux-architecture/SKILL.md`: Swift 6 concurrency (`actor`,
  `@Observable`, `async/await`), no singletons, constructor injection, one major type per file,
  packages form a DAG.
- Never run bare `xcodebuild` to launch; always tagged `reload.sh` builds. **Exception: the iOS
  app on the user's physical iPhone.** A tagged DEV iOS build pairs only with the same-tag Mac DEV
  build, which the user cannot sign in to, so phone dogfood is a Release build with `CMUX_DEV_TAG=`
  empty — see the `ios-dogfood-release-build` fence in `CLAUDE.md` (touchpoint #244) for the exact
  invocation and the build settings never to pass on it.
- The fixed-identity phone build is built with the development profile, then RE-SIGNED Ad Hoc
  (`Apple Distribution` + the `Supermux iPhone Ad Hoc` profile) so it carries
  `aps-environment = production` — sandbox APNs proved best-effort and silently dropped pushes to
  the backgrounded app. The paired Mac's direct provider reads
  the production key `supermux-apns.json`/`supermux-apns-auth-key.p8` from the cmux state directory
  (`~/.local/state/cmux`, via `CmuxStateDirectory` — NOT `~/Library/Application Support/cmux`);
  both files must be mode `0600`, the directory `0700`, and the `.p8` must never be committed or
  copied to the phone. `scripts/supermux-ios-release.sh` builds with the installed `Supermux iPhone
  Development` profile (`aps-environment = development`; both profile names are overrideable by
  environment), then re-signs with the `Supermux iPhone Ad Hoc` profile and verifies that the
  EMBEDDED profile and the final signature — the Ad Hoc pair, not the build-stage one — both carry
  `aps-environment = production` before installing.
- Agent pushes carry `"interruption-level": "time-sensitive"` so they break through Focus and
  Scheduled Summary — the phone matters precisely when nobody is at the Mac. That needs the App ID's
  Time Sensitive Notifications capability (a free checkbox on a paid team, unlike Critical Alerts).
  Because the re-sign derives entitlements FROM the Ad Hoc profile, enabling any App ID capability
  invalidates both profiles: regenerate and reinstall them, or the next build silently drops it.
  The release script fails loudly if either the profile or the final signature lacks the
  entitlement, since iOS would otherwise keep delivering the push at the active level and only the
  Focus/Scheduled Summary bypass would disappear.
- The local Mac Release is Developer ID-signed without a provisioning profile, so
  `scripts/supermux-release.sh` defines `SUPERMUX_LOCAL_RELEASE` and reuses upstream's DEBUG
  bundle-scoped `0600` file store for the mobile host's v2 identity (`MobileHostV2Installation`,
  touchpoint #334; the old `MobileHostIrohRuntime` files are gone upstream). Without that condition
  the data-protection Keychain rejects identity creation with `errSecMissingEntitlement`, leaving the
  mobile host offline even though the app launches.

## Known limitations / deliberate deviations

- **`$schema` resolves to upstream.** `web/data/cmux.schema.json` includes `supermuxToggleRun`, but
  a user's `cmux.json` `$schema` points at `raw.githubusercontent.com/manaflow-ai/cmux/main/...`
  (upstream), so editor schema validation only recognizes the new action once supermux publishes
  its own schema and repoints the URL. The app honors the binding at runtime regardless.
- **Socket `right_sidebar set` usage string** still lists `<files|find|vault|sessions|feed|dock>`
  without `changes`. The mode itself works (`RightSidebarMode.from(cliArgument:)` accepts it); only
  the help text omits it, because the displayed string comes from an upstream
  `Localizable.xcstrings` key and editing a non-`supermux.*` catalog key would add upstream merge
  surface for a cosmetic gain. Tracked as a known low-priority gap.
- **Changes panel is single-window-active-workspace.** Each window's mount owns its own
  `SupermuxChangesModel` tracking that window's selected workspace directory. In a device mirror it
  talks to the owning Mac (`mobile.supermux.changes.*`); the full-diff and PR viewers stay local-only.
- **Remote Macs were verified with the loopback device, not two physical Macs.** The loopback
  exercises the whole viewer + host pipeline in one process, but not iroh admission, real network
  loss, two filesystems, or pushes from the remote Mac. Mirrors pin the remote terminal's grid
  size (upstream never resizes the owning Mac's terminal), remote browser/markdown panels are not
  mirrored, and the Mac name in the flat-row icon's tooltip comes from upstream's "Workspace on %@" label.

### Open decisions from the 0.64.21 (v0.65) upstream merge

These are **unresolved questions for the fork owner**, recorded so a future merge does not
silently decide them. None of them is a bug to fix in-place; each needs a product call.

1. **Touchpoint #110 (`supermux-mobile-hide-search`) is now inert — phone search is LIVE again.**
   The fork had removed `.searchable(text: $searchText)` from `WorkspaceListView`. Upstream moved
   phone search into two NEW files —
   `Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListSearchHost.swift`
   (pre-iOS 26) and `…/MobilePrimaryTabScaffold.swift` (the iOS 26 `role: .search` Tab) — and
   `WorkspaceListView.searchText` is now an **injected property** rather than `@State`, so the
   query filters for real. The fence that remains in `WorkspaceListView.swift` is a comment-only
   marker; there is nothing left in that file to remove — confirm with
   `git grep -n '\.searchable(' -- Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/WorkspaceListView.swift`
   (must print nothing; scoping the grep to the whole package instead just hits the new hosts).
   Options: re-apply the
   removal at the new host(s) — which would now also amputate the iOS 26 search Tab, a much more
   visible change than the old bottom-bar field; retire the touchpoint and accept upstream's
   search; or keep the marker and document that the fork no longer removes search. **The fork
   currently ships upstream's search.**

2. **Upstream now ships its own mobile diff viewer, overlapping the fork's Changes screen.**
   Upstream advertises `workspace.changes.v1` (gated on `CmuxFeatureFlags.mobileWorkspaceChangesFlag`,
   filtered by `mobileHostCapabilities(includingWorkspaceChanges:)`), which covers the same ground
   as the fork's `supermux.changes.v1` (touchpoints #93/#108, `SupermuxChangesScreen` /
   `SupermuxDiffScreen`). **Both are advertised simultaneously whenever `mobileWorkspaceChangesFlag`
   is on** — when it is off, `mobileHostCapabilities(includingWorkspaceChanges:)` strips upstream's
   entry and only the fork's remains. So a fork phone paired with a flag-enabled fork Mac is
   offered two different diff UIs. Options: keep both (they are
   independently capability-gated), suppress one, or converge the fork's Changes screen onto
   upstream's viewer. Note the hard constraint from #93: the fork capability list must **never**
   contain the literal `workspace.changes.v1`, or upstream's
   `cmuxTests/MobileHostConnectionLifecycleTests.swift` equality assertion breaks.

3. **Dock terminals do not get the fork's new-tab browser-link placement.** Upstream's
   `TerminalLinkOpenContainer` extraction produced two conformances. `Workspace`'s
   (`Sources/Workspace+TerminalLinkOpening.swift`) carries the fork's `browser-link-new-tab` fence;
   `DockSplitStore`'s (`Sources/DockSplitStore+TerminalLinkOpening.swift`) is deliberately left
   upstream-shaped, so a Command-clicked link from a **dock** terminal still opens as a split, not
   a new tab. Deliberate for now (smaller touchpoint surface), and recorded so a merger does not
   read the missing fence as clobbered. Question: should dock terminals match?

4. **Three pre-existing red tests contradict touchpoint #130 — NOT caused by this merge.**
   Confirmed byte-identical to pre-merge `HEAD`
   (`git show HEAD:cmuxTests/PostHogAnalyticsPropertiesTests.swift`), so this is standing fork
   debt, not merge damage. In `cmuxTests/PostHogAnalyticsPropertiesTests.swift`:
   - `appKitSidebarFeatureFlagDefaultsOn` asserts `flag.defaultWhenUnavailable` for
     `sidebar-appkit-list-experiment`, which the fork flipped to `false`.
   - `featureFlagResolutionPrecedence` sets a remote `true` for that key and asserts
     `flags.remoteValue(for: flag) == true` — the fork's gate filters it to `nil`.
   - `remoteControlledFlagsRejectNewLocalOverrideWrites` sets a remote `true` for that key and
     asserts `setOverride(false, …)` is rejected — with the gate there is no remote value to
     reject against.

   All three need a fence (or a retarget onto a different, non-fork-pinned flag key — the tests
   are about the generic precedence machinery, not about the sidebar experiment specifically) plus
   a SUPERMUX-TOUCHPOINTS.md row. Until then the fork's `cmuxTests` run is knowingly red on these
   three. **Open question:** retarget the tests to a neutral flag key (cleanest, smallest fence),
   or fence the three expectations to the fork's values (bigger fence, keeps the key coverage)?

5. **Touchpoint #130 has no regression test — and this merge proves that is dangerous.** Nothing
   asserts the ingestion invariant (a remote `true` for `sidebar-appkit-list-experiment` is never
   ingested at any `remoteValuesByKey` write site; a remote `false` still is). Upstream moved
   production ingestion from `applyLoadedFlags()` onto a new `applyRemoteFlagValues(_:)` in a
   change that **automerged cleanly** — the fork's single gate would have silently stopped
   protecting the production path with no test failure. Suggested fork-owned coverage
   (`cmuxTests/SupermuxAppKitSidebarFlagGateTests.swift`): drive each of the three write paths
   (`init` cache seeding, `applyRemoteFlagValues`, `applyLoadedFlags`) with remote `true` and
   assert `remoteValue(for:) == nil` **and** the `cmux.flags.remote.…` defaults key is absent;
   then drive each with remote `false` and assert it ingests. **Wiring caveat:** a new file in
   `cmuxTests/` needs four `cmux.xcodeproj/project.pbxproj` entries (`PBXFileReference`,
   `PBXBuildFile`, group `children`, target Sources phase) or it silently never runs — see the
   pbxproj-test-wiring pitfall in `CLAUDE.md`, and use a reserved `50BE0001…` id per
   SUPERMUX-TOUCHPOINTS.md #3.

6. **Under state sync v2, fork-field freshness depends on the fork's own observer poke.** The
   phone no longer refetches `mobile.workspace.list`; it consumes `mobile.sync.delta`. So the four
   additive §6 fields are only as fresh as whatever ticks the v2 host.
   `Sources/Supermux/SupermuxMobileActivityObserver.swift` (supermux-owned, no fence needed) now
   ticks `MobileStateSyncHost.shared.broadcastIfSubscribed()` alongside its `workspace.updated`
   emit, via an injectable `pokeStateSync` parameter, so activity and association changes
   propagate. Unopened **worktree** PR badges are covered too, by
   `SupermuxMobileWorktreesObserver` (`Sources/Supermux/SupermuxMobileObservers.swift`), which
   hashes `pullRequestsByWorktreePath`. **Remaining gap — narrower than it first looks:** there is
   no fork observer for branch-only or PR-only mutations on an **open `Workspace`**, so those
   values refresh only when some other tracked field trips upstream's
   `Sources/Mobile/MobileWorkspaceListObserver.swift`. Pre-existing (already true of the legacy
   path) but **more visible under v2**, because the phone no longer papers over it with periodic
   refetches. Fix would be a fork observer on open-workspace branch/PR state; not done.

### Fork-owned files that track upstream API churn

These are supermux-owned files (no fence, no registry row) that had to change **only** to keep
compiling against upstream 0.64.21. Recorded so the next merger knows where upstream API drift
lands first. All three are verified by a successful
`xcodebuild build-for-testing -scheme cmux-unit`:

- `Sources/Supermux/SupermuxAppGlue.swift` — two
  `@ObservedObject private var shortcutObserver = KeyboardShortcutSettingsObserver.shared`
  became `@State`, because upstream migrated that observer from `ObservableObject` to
  `@Observable` (Swift Observation). Every upstream call site uses `@State` too.
- `Sources/Supermux/SupermuxFileExplorerCommands.swift` — the two `extension NSMenu` builders are
  now `@MainActor`, because upstream made `FileExplorerStore` main-actor-isolated. Both call sites
  in `Sources/FileExplorerView.swift` are already on the main actor.
- `Sources/Supermux/SupermuxMobileActivityObserver.swift` — gained an injectable `pokeStateSync`
  (default `MobileStateSyncHost.shared.broadcastIfSubscribed()`) called alongside its
  `workspace.updated` emit; this is what keeps the fork's §6 fields fresh under state sync v2
  (see open decision 6 above). Its doc comment explains the rationale in place.

## Branch/remote model

- `upstream` remote → `manaflow-ai/cmux`, branch `main`.
- `origin` remote → `rajinsyed/supermux` (public GitHub repo), the fork's home.
- Local `main` → supermux trunk (cmux main + supermux commits), pushed to `origin/main`.
