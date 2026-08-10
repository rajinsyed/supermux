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

Where cmux already has a primitive (workspace groups, Dock, `actions`/`commands` in cmux.json,
diff viewer, per-workspace git branch/dirty tracking), supermux **extends** it rather than
building a parallel system.

### Implementation status

| Goal | Status | Where |
|------|--------|-------|
| Sticky Projects (sidebar section, icons, colors, persisted) | ✅ | `SupermuxProjectsModel`, `SupermuxProjectStore`, `SupermuxProjectsSectionView`; mounted via the `sidebar-projects-section` touchpoint |
| Open local / create worktree from a project | ✅ | `SupermuxGitWorktreeService` (selectable starting branch; piggycode semantics: `--no-track -b`, `push.autoSetupRemote`, `branch.<n>.base`, dedup, exclude) |
| List / open / delete worktrees (dirty-checked) | ✅ | `SupermuxGitWorktreeService.listWorktrees/removeWorktree`, project row disclosure |
| Worktree PR badges (clickable, state-colored) | ✅ | opened worktrees reuse cmux's per-workspace `SidebarPullRequestState` (carried on `SupermuxOpenWorkspace.pullRequest`); unopened ones via `SupermuxWorktreePullRequestModel` + `SupermuxPullRequestProbe` (wrapping `CmuxGit.PullRequestProbeService`); both render `SupermuxPullRequestBadge`. SupermuxKit now depends on `CmuxGit`. |
| Changes (git) panel | ✅ | right-sidebar `changes` mode (`right-sidebar-changes-mode-*` touchpoints) → `SupermuxChangesPanelView` / `SupermuxChangesModel` / `SupermuxGitChangesService` |
| Run actions (⌘G start/stop) | ✅ | `supermuxToggleRun` shortcut (shares ⌘G with Find Next) → `SupermuxRunCoordinator` |
| Custom app actions + terminal presets (per project) | ✅ | `SupermuxProjectAction`, editor Actions section, project-row Actions submenu |
| Worktree setup/teardown + `config.json` import | ✅ | `SupermuxProjectConfig`(+`Loader`), `SupermuxWorktreeScript`/`SupermuxWorktreeEnvironment`; setup runs in a dedicated terminal via `SupermuxTabManagerOpener`, teardown headless in `SupermuxGitWorktreeService.removeWorktree`; import wired in `SupermuxProjectsModel` |
| AI integration (Vercel AI Gateway key + branch names + commit messages) | ✅ | `Packages/SupermuxKit/Sources/SupermuxKit/AI/` (`SupermuxAIConfig`, `SupermuxAIGatewayClient`, `SupermuxAIBranchNamer`, `SupermuxAICommitMessenger`); key UI via the `ai-settings` touchpoint (#18) → `SupermuxAISettingsCard`; wired in `SupermuxComposition`. Key in a `0600` secret file under the cmux state dir; model id (default `openai/gpt-5.4-mini`) editable in Settings, persisted in UserDefaults (`supermux.ai.model`). |
| Localization (en + ja) | ✅ | macOS/app-target `supermux.*` keys in `Resources/Localizable.xcstrings`; the iOS screens package owns a SECOND catalog, `Packages/iOS/SupermuxMobileUI/Sources/SupermuxMobileUI/Resources/Localizable.xcstrings` (~207 keys). Regenerate with the scripts under "Localization" below |

Both phases are verified against a live tagged build (worktree creation, the Changes panel on
real git status, and the full ⌘G run→stop→restart cycle confirmed by an actually-listening dev
server port).

### Mobile (iOS companion) parity status

The iOS companion app remote-controls a paired supermux Mac over additive `mobile.supermux.*`
JSON-RPC methods (wire contract in `Packages/Shared/SupermuxMobileCore`; phone stores in
`Packages/iOS/SupermuxMobileKit`; screens in `Packages/iOS/SupermuxMobileUI`; Mac handlers in
`Sources/Supermux/SupermuxMobileHost+*.swift`). The Mac stays the sole source of truth (projects
file, git, AI keys). Every iOS entry point is capability-gated (`supermux.*.v1`), so a fork phone
paired with an upstream cmux Mac renders exactly upstream's UI. Status per fork feature area:

| # | Fork feature area | Mobile status | How / where |
|---|-------------------|---------------|-------------|
| 1 | Projects (sticky, full CRUD) | ✅ on iOS | `SupermuxProjectsMobileSection` + `SupermuxProjectDetailScreen` + `SupermuxProjectEditorSheet` over `projects.list` / `project.create/update/delete/open` |
| 2 | Project icons & colors | ✅ on iOS | custom icon via `project.icon` (base64 PNG, etag-cached `SupermuxProjectIconCache`) → SF Symbol → letter avatar tinted by `color_hex` |
| 3 | Worktrees (create/open/remove, starting branch, AI branch suggest) | ✅ on iOS | `SupermuxNewWorktreeSheet` + project-detail worktree rows over lazy `worktrees.list` branch snapshots (`include_branches`) / `worktree.suggest_branch/create/open/remove` (dirty removals require `force` after a phone-side confirm) |
| 4 | Worktree PR badges | ✅ on iOS | `SupermuxPullRequestDTO` (number/state/url; title optional-nil, matching the desktop probe) on `worktrees.list` rows |
| 5 | Changes (git) panel | ✅ on iOS | `SupermuxChangesScreen` / `SupermuxDiffScreen`: status, diffs, stage/unstage/discard, commit, AI commit message, push/pull, stash/pop, history over `changes.*` |
| 6 | Run actions | ✅ on iOS | project-row run menu + running indicator over `run.state/start/stop` |
| 7 | Terminal presets | ✅ on iOS | preset manager + editors (m2) and launcher (m4) over `preset.create/update/delete/launch` |
| 8 | Custom app actions | ✅ on iOS | `action.run`; `open_url`-classified actions return the URL and the phone opens it locally |
| 9 | Worktree setup/teardown scripts | ✅ mac-side execution, phone-triggered | scripts always run on the Mac when worktrees are created/removed from the phone; script lists editable in the phone's project editor (config-imported projects render read-only) |
| 10 | AI integration | ✅ mac-side only (by design) | the AI key/model never leave the Mac; the phone consumes results (`worktree.suggest_branch`, `changes.generate_commit_message`) and surfaces the `ai_unavailable` error when unconfigured |
| 11 | Workspace switcher | ✅ covered by existing surface — **deliberate decision** | the existing iOS workspace list already is the mobile switcher; no new switcher UI was built (recorded mission decision) |
| 12 | Agent activity indicators | ✅ on iOS | additive `supermux_activity` workspace-list field → `SupermuxWorkspaceActivityDot` (`working`/`needs_input`/`ready`, palette mirrors the Mac's `SupermuxActivityPalette`) |
| 13 | File explorer ops | ✅ on iOS | `SupermuxFileBrowserScreen` (browse, new file/folder, rename, duplicate, trash — never `rm`) over root-confined `files.*`; doubles as the project editor's folder picker |
| 14 | Project association / nesting | ✅ on iOS | additive `supermux_project_id` field folds loose project-owned rows under the Projects section; a project's open workspaces are listed in its detail screen |
| 15 | Empty-home behavior | mac-side only — **deliberate decision** | pure macOS window behavior; the mobile close path is already handled by touchpoint #71. No iOS surface (recorded mission decision) |
| 16 | Sidebar polish (font scale, switcher cards, list filter) | mac-side only | pure macOS sidebar cosmetics with no mobile analogue; the phone's Projects section has its own mobile-native styling |

**Recorded non-goals** (deliberate, may be revisited later):

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
#     form reads the path out of field 3 of every numbered row; ~116 unique paths today.)
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
#      fences also sit in CLI/, cmuxTests/, cmuxUITests/, web/data/, .github/workflows/,
#      scripts/, ios/, .gitignore, CLAUDE.md and every README.<lang>.md.

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
  all start with `supermux.`, but there are TWO deliberate exceptions the fork rewrites in place —
  `settings.app.workspaceInheritWorkingDirectory.subtitleOff` and
  `settings.search.alias.setting.app.workspace-inherit-working-directory` (touchpoints #82/#84,
  registered under #4b). Take the fork side for those two; union everything else.
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
  `.github/workflows/ci.yml` is `scripts/swift_warning_budget.py`, which caps Swift **warnings**,
  not file length (CI runs the script itself plus its regression wrapper
  `./tests/test_ci_swift_warning_budget.sh`).
- All user-facing strings localized via `String(localized:)` with keys in
  `Resources/Localizable.xcstrings` (supermux keys are prefixed `supermux.`).
- New code follows `skills/cmux-architecture/SKILL.md`: Swift 6 concurrency (`actor`,
  `@Observable`, `async/await`), no singletons, constructor injection, one major type per file,
  packages form a DAG.
- Never run bare `xcodebuild` to launch; always tagged `reload.sh` builds.

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
  `SupermuxChangesModel` tracking that window's selected workspace directory.

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
