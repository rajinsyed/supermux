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
   - **create a git worktree** (quick: name a branch, get an isolated checkout + workspace).
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
| Open local / create worktree from a project | ✅ | `SupermuxGitWorktreeService` (piggycode semantics: `--no-track -b`, `push.autoSetupRemote`, `branch.<n>.base`, dedup, exclude) |
| List / open / delete worktrees (dirty-checked) | ✅ | `SupermuxGitWorktreeService.listWorktrees/removeWorktree`, project row disclosure |
| Worktree PR badges (clickable, state-colored) | ✅ | opened worktrees reuse cmux's per-workspace `SidebarPullRequestState` (carried on `SupermuxOpenWorkspace.pullRequest`); unopened ones via `SupermuxWorktreePullRequestModel` + `SupermuxPullRequestProbe` (wrapping `CmuxGit.PullRequestProbeService`); both render `SupermuxPullRequestBadge`. SupermuxKit now depends on `CmuxGit`. |
| Changes (git) panel | ✅ | right-sidebar `changes` mode (`right-sidebar-changes-mode-*` touchpoints) → `SupermuxChangesPanelView` / `SupermuxChangesModel` / `SupermuxGitChangesService` |
| Run actions (⌘G start/stop) | ✅ | `supermuxToggleRun` shortcut (shares ⌘G with Find Next) → `SupermuxRunCoordinator` |
| Custom app actions + terminal presets (per project) | ✅ | `SupermuxProjectAction`, editor Actions section, project-row Actions submenu |
| Worktree setup/teardown + `config.json` import | ✅ | `SupermuxProjectConfig`(+`Loader`), `SupermuxWorktreeScript`/`SupermuxWorktreeEnvironment`; setup runs in a dedicated terminal via `SupermuxTabManagerOpener`, teardown headless in `SupermuxGitWorktreeService.removeWorktree`; import wired in `SupermuxProjectsModel` |
| AI integration (Vercel AI Gateway key + branch names + commit messages) | ✅ | `Packages/SupermuxKit/Sources/SupermuxKit/AI/` (`SupermuxAIConfig`, `SupermuxAIGatewayClient`, `SupermuxAIBranchNamer`, `SupermuxAICommitMessenger`); key UI via the `ai-settings` touchpoint (#18) → `SupermuxAISettingsCard`; wired in `SupermuxComposition`. Key in a `0600` secret file under the cmux state dir; model id (default `openai/gpt-5.4-mini`) editable in Settings, persisted in UserDefaults (`supermux.ai.model`). |
| Localization (en + ja) | ✅ | all `supermux.*` keys in `Resources/Localizable.xcstrings`; regenerate with the scripts under "Localization" below |

Both phases are verified against a live tagged build (worktree creation, the Changes panel on
real git status, and the full ⌘G run→stop→restart cycle confirmed by an actually-listening dev
server port).

### Localization

All supermux user-facing strings use `String(localized: "supermux.<area>.<name>", defaultValue:
"English")`. Because cmux packages resolve `String(localized:)` against the **app** bundle
(`Bundle.main`), every supermux key — package or app-target — lives in the app catalog at
`Resources/Localizable.xcstrings` with `en` + `ja` entries (matching cmux's two required
locales). Interpolated strings (`\(path)`, counts) are stored as `%@` / `%lld` format strings.

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
   - `Packages/SupermuxKit/` — domain models, services, persistence (Swift Package).
   - `Sources/Supermux/` — app-target UI + glue that needs app types (new files only).
   New files never conflict on merge.
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
git diff --stat HEAD...upstream/main -- $(awk '/^\| `/{gsub(/`/,"",$2); print $2}' SUPERMUX-TOUCHPOINTS.md) 
#    ^ shows whether upstream touched any of our touchpoint files — those need attention

# 2. Merge (NOT rebase — merge keeps our history stable and rerere effective)
git merge upstream/main

# 3. If conflicts:
#    - For files NOT in SUPERMUX-TOUCHPOINTS.md: take upstream's side unless the conflict is in
#      a Sources/Supermux/ or Packages/SupermuxKit/ file (ours).
#    - For touchpoint files: take upstream's version of the surrounding code, then re-apply the
#      fenced SUPERMUX block per SUPERMUX-TOUCHPOINTS.md instructions.
#    - grep -rn "SUPERMUX:begin" Sources/ Packages/ cmux.xcodeproj/ — verify every registered
#      fence still exists after resolution.

# 4. Verify integrity
./scripts/supermux-check-touchpoints.sh    # all fences present + manifest in sync

# 5. Submodules may have moved
git submodule update --init --recursive
./scripts/ensure-ghosttykit.sh

# 6. Build + test
./scripts/reload.sh --tag upstream-merge
# run the supermux unit tests too (see Building below)

# 7. Commit the merge, summarize for the user what came in and what needed manual resolution.
```

Conflict heuristics:
- `project.pbxproj` conflicts: keep upstream's changes AND our package/file references. Our
  pbxproj additions are registered as touchpoints. Re-run `scripts/normalize-pbxproj.py` and
  `scripts/check-pbxproj.sh` after resolving.
- `Resources/Localizable.xcstrings` conflicts: it's JSON; union both sides' keys (ours all start
  with `supermux.`).
- If upstream added a feature that overlaps a supermux feature (e.g. they build their own
  projects concept), STOP and present options to the user instead of auto-resolving.

## Repo layout (supermux-owned)

| Path | Purpose |
|------|---------|
| `SUPERMUX.md` | This file — fork context, rules, merge playbook |
| `SUPERMUX-TOUCHPOINTS.md` | Registry of every modified upstream file |
| `Packages/SupermuxKit/` | Supermux domain package (models, services, persistence) |
| `Sources/Supermux/` | App-target UI and glue code (new files only) |
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

> **Toolchain note:** the app build's "Ghostty CLI helper" script phase requires **zig 0.15.2
> exactly** (Homebrew's newer zig will not be used). On this machine zig 0.15.2 is installed at
> `/usr/local/bin/zig` (checksum-verified from ziglang.org), which the helper script probes
> after `/opt/homebrew/bin/zig`. If a build fails with "zig 0.15.2 is required", re-install it
> there or run `ZIG_REQUIRED=0.15.2 ./scripts/install-zig-ci.sh`. Also note: prebuilt
> GhosttyKit is fetched by `./scripts/ensure-ghosttykit.sh` (no zig needed for that).

```bash
./scripts/reload.sh --tag <your-tag>            # build Debug app
./scripts/reload.sh --tag <your-tag> --launch   # build + launch
```

Constraints inherited from upstream that supermux code MUST follow:
- Swift files < 500 lines (`scripts/swift_file_length_budget.py`, CI-enforced).
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

## Branch/remote model

- `upstream` remote → `manaflow-ai/cmux`, branch `main`.
- Local `main` → supermux trunk (cmux main + supermux commits).
- No `origin` is configured yet; if the user wants a GitHub repo, add it as `origin` and keep
  `upstream` pointing at cmux.
