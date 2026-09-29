# Supermux upgrade notes

What changes for a supermux user each time the fork merges upstream cmux. One section per
upstream merge, newest first.

This is a **user-facing** log: what to expect differently after updating. Mechanical merge
detail (fences, touchpoints, conflict resolutions) belongs in
[`SUPERMUX-TOUCHPOINTS.md`](SUPERMUX-TOUCHPOINTS.md); the merge process itself is in
[`SUPERMUX.md`](SUPERMUX.md). Upstream's own release notes are in
[`CHANGELOG.md`](CHANGELOG.md) — this file only covers what a supermux user notices, including
the places where fork behavior and upstream behavior interact.

Add a section here as the last step of every upstream merge.

---

## cmux main @ `64a1765fcc` → main @ `4e9d779888` (2026-10-01)

Merged 259 first-parent upstream commits (upstream main 2026-09-29 → 2026-09-30). 25 files
conflicted; no fork feature was dropped. Two touchpoints were added (#600, #601).

### Shared terminal sizing (Mac, iPhone, Devices mirrors)

The headline change. A terminal has one grid, and everyone viewing it now agrees on it.

- **The default policy is "Fit everyone".** Opening a Mac terminal on the iPhone, or viewing it
  from another Mac through Devices, sizes the grid to the smallest viewer. Before, a Devices
  mirror never resized the source terminal; now a smaller Mac viewing it shrinks it, the same
  way a phone does.
- A pane larger than the shared grid shows a hatched margin, and a smaller one shows the cut
  edge. Both are drawn in the split divider's color, with a size chip naming the device that
  owns the size (for example `200×60 · Lawrence's Mac Studio`).
- The size panel lists every participant and lets you change the policy or disconnect a viewer.
  A disconnected pane shows a Detached card with Reattach and Reattach as Viewer (which rejoins
  without changing the size).
- New shortcut **⌃⌥⌘=**, Size Terminal to My Window.
- **iPhone:** the workspace title menu gains **Connected Devices…** ("2 others" / "Only this
  device"), which opens the same size sheet as the chip. When the shared grid is larger than the
  phone, the terminal is scaled to fit; pinch to magnify.

### Other upstream changes you will notice (Mac)

- **Closing a busy workspace from the CLI, socket or phone needs `--force`.** When a process is
  running, `cmux workspace close` and the phone's close now reply "retry with --force" instead
  of closing. The fork's empty-home behavior still applies once the close goes through: the last
  workspace leaves an empty window, not a closed one.
- Panes that become visible now clear their own unread notification, including non-focused
  split panes. This complements the fork's focused-pane suppression, which already records a
  notification as read when it arrives for the pane you are looking at.
- Copy built-ins for the working directory, git project root and visible screen (tab bar
  buttons, shortcuts, Command Palette); setting actions, setting presets and `cmux config set`;
  native discovery for configured actions; right-click a terminal link to choose where it opens
  (Command-click still follows the fork's new-tab routing).
- Diff viewer: mark files Viewed with **V**, filter files, and generated or large diffs start
  collapsed. The Changes panel's file diffs open in this viewer.
- A Themes settings page lists every terminal theme; TextBox leaves beta; View → Focus TextBox
  Input.
- Agents: hibernate and wake, `cmux agent message`, auto-resume after retryable provider failures,
  and an opt-in multi-provider Conversations sidebar.
- Predictive local echo is on by default for remote terminals (`terminal.predictiveLocalEcho:
  false` turns it off). Terminal scrollback is checkpointed, so a crash no longer loses it. New
  windows honor the configured sidebar width.

### Other upstream changes you will notice (iOS)

- A new **Feed** tab collects agent events, with replies and full-text reading. Upstream hides the
  Notifications tab when the Feed is on; **Supermux keeps both tabs** by default, because the
  fork's project avatars and grouping render only in Notifications (see the open decision below).
  Settings → Legacy Notifications Tab still hides or shows it.
- The terminal arrow pad is easier to find, pinned group members stay above unpinned rows, and the
  computer picker no longer clips its status.

### What stays the same (fork features)

Projects (Mac and iPhone), the Changes panel and PR viewer, Claude harness panes (now also absent
from the copy actions, as intended), project-aware notifications and phone push, focused-pane
suppression, empty-home windows, the ⌘G run toggle and every other fork shortcut, iOS
Projects/Changes/Files, Mac↔phone selection sync and the scroll-speed setting.

### Watch-outs

- **iPhone scrolling on a scaled-to-fit grid.** The fork's native-scroll path now converts finger
  travel through upstream's displayed cell size, but its bounded scrollback geometry still uses
  the unscaled cell height. Check scrollback on a phone viewing a Mac terminal larger than the
  phone, with and without pinch magnification.
- **A Devices mirror can resize the source terminal.** Under Fit everyone, a smaller viewing Mac
  shrinks the host's grid. If the remote-workspaces work assumes mirrors are passive, expect
  host-side reflow while a mirror is open.
- The fork's persisted notification history now also stores upstream's agent-event flag. Records
  written by the previous build decode as "unknown", which upstream treats as kept.
- The previous merge had left 18 upstream-owned strings at older wording (for example "Couldn't
  reach Stack" on sign-in errors) and 21 strings upstream had deleted. They now match upstream;
  only the fork's one deliberate rewrite (#84) differs.

### Open decisions surfaced by this merge

1. **iOS Feed vs. the fork's project-aware Notifications tab.** Supermux currently shows both
  (#601 flips upstream's default). Options: keep both; move the project avatar and grouping into
  upstream's Feed rows and then drop #601; or hide the Feed.

---

## cmux main @ `91b991496d` → main @ `64a1765fcc` (2026-09-30)

Merged ~2,700 first-parent upstream commits (upstream main 2026-08-23 → 2026-09-30). 141 files
conflicted; 18 fork touchpoints were retired because upstream now ships the same fix, 13 were
added (mostly where upstream moved code the fork hooks into).

### Upstream changes you will notice (Mac)

- **Settings:** one section at a time, one fixed subtitle per row, an Accent Color setting (fork
  chrome now reads it), base keymap presets, native Ghostty option rows, Warn Before Closing
  Workspace, "Don't ask again" on close confirmations, `terminal.confirmUnsafePaste`,
  `notifications.suppressWhenAppFocused`, `app.tabBarVisibility`, `app.equalizeSplitsOnCreate`,
  `app.defaultWorkspacePath`, and an opt-in **Subtle Selection Highlight** (see watch-outs).
- **Right sidebar:** tabs can be reordered and hidden, and `⌃1–9` follows the visible order.
  Upstream's new **Cloud** tab sits beside the fork's **Changes** tab.
- **Terminal:** Ghostty config hot-reload with an error card, a chat view for a pane's
  Claude/Codex session, Paste Last Screenshot, Reveal in Finder, prompt markers, Focus Last,
  a pane swap picker, New Pane (Auto Layout), overlay scrollers, a password-echo indicator.
- **Agents:** agents waiting on background work get their own status, agent-recovery
  workspaces, auto-resume after an update installs, OpenCode v2 plugin, cross-provider token
  usage, "Needs input" clears when a Claude permission is answered in the terminal.
- **Updates now install automatically at a quiet moment** and resume agents afterwards.
- New default shortcut **⌃⌘N** (upstream). The fork's ⌃⌘Z split-zoom rebind is unchanged.

### Upstream changes you will notice (iOS)

- New launch screen (shows the Supermux logo), redesigned notification rows (workspace as
  headline), native UIKit surface picker menu, per-workspace "reopen last tab", phone-served
  demo/SSH workspaces, upstream's own unread count, and iOS 17 as the minimum OS.
- The phone-local browser no longer has an × button; close it from **Close Pane** in the
  workspace title menu (the fork's shared close-confirmation path).

### What stays the same (fork features)

Projects sidebar (Mac + iOS), Changes panel and PR viewer, Claude harness panes, notification
project grouping, focused-pane notification suppression, empty-home windows (in memory),
keep-window-open on last close, browser new-tab link routing, iOS Projects/Changes/Files,
Mac↔phone selection sync, scroll speed and native-scroll port, local-release pairing storage
(now re-homed onto upstream's `MobileHostV2Installation`), and Supermux branding (in-app logo,
sign-in mark, launch logo, `mobile.signIn.title`).

### Watch-outs

- **Empty windows no longer survive a relaunch.** Upstream #14788 drops windows with no
  workspaces on save/restore (a WindowServer hang fix). An emptied window still stays open while
  the app runs.
- **One iOS notification service extension (resolved).** The fork's avatar decoration now runs
  inside upstream's E2EE-decrypting `NotificationService`; the separate
  `SupermuxNotificationService` target is gone — see SUPERMUX-TOUCHPOINTS.md #368–372, #516.
- **The CLAUDE.md phone dogfood (Release) build still fails as written**: its
  `SUPERMUX_NSE_CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements` now claims upstream's
  `group.dev.cmux.ios`, which the dogfood extension id cannot sign. The fixed-identity release
  (`scripts/supermux-ios-release.sh`) is unaffected.
- Upstream #13741 removed Mac-side push targeting: the Mac no longer names `com.supermux.ios` as
  the push target, so phone pushes rely on server fan-out or the fork's direct push path.
  Confirm a push reaches the Supermux iPhone app when dogfooding.
- On iOS 17 (new upstream minimum) the Projects sidebar rows don't swipe; every swipe action is
  still in the row's long-press menu. iOS 18+ is unchanged.
- iOS scroll: upstream's pixel-precise momentum path and the fork's no-momentum #9762 port
  coexist; the fork path wins whenever the primary screen is known. Needs an on-device feel check.
- Local toolchain: this machine's Xcode 27 linker breaks the pinned Rust 1.88 (proc-macros fail
  when `MACOSX_DEPLOYMENT_TARGET` is set; Rust stable works). Upstream CI (Xcode 26) is not
  affected. Plain `reload.sh --tag` outside cmuxterm-hq needs `CMUX_DEV_BACKEND_MODE=local`.
- `cmux-tui/` must stay byte-identical to upstream: tagged reloads fetch the published cmux-tui
  client by exact `cmux-tui/` content, so any fork diff there breaks every reload. The fork's old
  `cmux-tui/dist` deletion and Zig timing relaxation were reverted for this reason.

### Open decisions surfaced by this merge

1. iOS notification extensions: merge the avatar code into upstream's extension (recommended),
   drop upstream's, or ship both.
2. Empty-home windows across relaunch: accept upstream, or add a marked fork exception.
3. Subtle Selection Highlight vs the fork's faint selection.
4. Upstream's unread badge vs the fork's inline badge (iOS).
5. Upstream's "reopen last tab" vs the fork's Mac-authoritative selection sync (iOS).
6. A `⌃digit` shortcut for the Changes tab.
7. Default `CMUX_DEV_BACKEND_MODE=local` in the fork.
8. Retire the fork's drag hover guard (#73–79) now that upstream fixes the same bug.

---

## cmux main @ `6d37f62a47` → main @ `91b991496d` (2026-08-24)

Merged 2,241 upstream commits across 2,765 files, through upstream main from 2026-08-23.

### iOS Agent Chat and Focus Mode

- Upstream removed the iOS GUI Agent Chat transcript/composer. Supermux follows that product
  direction and does not restore the deleted button or chat pane.
- Supermux's dependent **Focus Mode** feature is retired with it: the grouping UI, setting,
  localization, package dependencies, and tests were removed.
- Upstream retained the artifact gallery/event-source infrastructure and `mobile.chat.*` RPC seams;
  those backend/artifact capabilities remain available where upstream still uses them.

### Upstream changes you will notice

- iOS terminal scrolling now uses upstream's pixel-precise renderer-owned fractional viewport.
  Supermux's no-momentum release behavior and scroll-speed preference remain layered on top.
- The iOS workspace Changes view is now a hierarchical file tree, Simulator streams gained richer
  controls, landscape terminal layout clears the Dynamic Island, and the New Task button stays
  outside the keyboard safe area.
- The iOS workspace list preserves its scroll position across workspace enter/exit, default-surface
  fallback is more reliable, and pairing handles multiple Mac DEV builds correctly.
- cmux-tui advanced through `v0.11.0`, including socket-discovery contracts, isolated core tests,
  runtime diagnostics, and the updated headerless sidebar rails.

### Fork integration

- Projects, usage limits, Changes/Files title-menu entries, generic terminal/browser/Simulator
  selection sync, and exact per-pane unread state remain intact on iOS.
- Upstream independently adopted the identity-preserving workspace-list toolbar structure, so
  Supermux touchpoint #250 was retired.
- Upstream's new keyboard host/geometry architecture supersedes the old fork workaround;
  touchpoints #213/#214 were retired rather than re-porting incompatible geometry assertions.
- Tailscale packet-tunnel routes still tolerate a missing local endpoint, but upstream's generation
  guard is restored so route substitution remains fail-closed.
- Fixed the post-merge exact-bundle identity regression that made the fixed Supermux macOS and iOS
  Release apps reject each other during Tailscale pairing. The Mac now targets `com.supermux.ios`,
  the phone admits only `mac:com.supermux.app`, and the release script verifies the exact QR scheme.
- The pane-tab **Disconnect SSH** action now reaches the existing remote disconnect path instead of
  falling through an unhandled bonsplit action.

### Watch-outs

- Upstream main currently has failing standalone package tests in `CMUXMobileCore` diagnostics and
  `CmuxMobileShell` connection-authority suites. Focused runs reproduced the same failures in a clean
  upstream worktree, so they are active upstream regressions rather than Supermux merge regressions.
  The authority failure was narrowed to upstream's computer-instance-identity changes and makes real
  iPhone Mac-selection/pairing dogfood especially important.
- No physical-phone dogfood was performed. Per the standing merge checklist, verify the Projects
  section and Mac selection/pairing on a real iPhone before merging this runtime/UI update.

---

## cmux 0.64.22 → main @ `6d37f62a47` (2026-08-09)

> **Historical note:** this snapshot needed fork touchpoints #213/#214 to keep the iOS terminal
> clear of the keyboard. The 2026-08-24 upstream merge replaced that implementation with upstream's
> `GhosttySurfaceHostView` / `KeyboardDockGeometrySource` architecture, so those touchpoints and
> their fork-only UITest assertions are now retired.
>
> Follow-up on the same branch: fork `origin/main` (PRs #21 + #22 — AI token headroom for
> reasoning models, and the compact AI usage-analytics button beside the usage gauge) was merged
> in right after. The registry row PR #22 claimed as #148 was refiled as **#146b** (this branch
> had already assigned #148–#151 to the iPhone Projects-table restoration); the fence id
> `sidebar-usage-analytics-button` is unchanged.

Merged `manaflow-ai/cmux` main — **~397 commits, ~1,450 files**, the largest update since the
fork began. This is a pre-release snapshot of upstream main (no version tag yet), taken to pick
up a big batch of iOS reliability work.

### New upstream features you will notice

- **Simulator panes with iPhone control.** iPhone/iPad Simulators are first-class panes on the
  Mac, and the *phone app can now stream and control them* — a whole new `mobile.simulator.*`
  capability set the iOS app negotiates automatically.
- **Inline notification replies** on macOS *and* iOS: reply to an agent prompt straight from the
  notification, with a notification debug mode. Notifications also open as a pane tab now.
- **iOS terminal send progress/failures are visible** — no more silently dropped input; the send
  path shows progress and surfaces errors.
- **Phone browsers are unified on the streamed Mac surface** (create, blank-page state,
  discarded-tab restore) and the mobile browser stream is self-healing.
- **iOS keyboard fixes**: the terminal dock stays pinned during keyboard reversals, and focus
  ownership recovers after the photo picker.
- **Push notification reliability** was fixed end-to-end, and same-account discovery refreshes on
  iOS startup, so the phone finds the Mac faster.
- **Workspace niceties**: Move-to-Group from the iOS context menu, custom sort for All Computers,
  search selections open inside the search tab, Cmd+Z works in the browser, Korean NFC/NFD font
  rendering fixed, hibernation SIGHUP fix, CLI burst-typing PTY wedge fix.
- **Model selection lab** in the New Task composer, coderouter team settings dashboard, raw PTY
  byte streaming to smart terminal clients.

### Fixes you will feel on the fork

- Upstream's **iOS “diff viewer scroll momentum survives finger lift”** (#9257) does NOT apply to
  the fork's terminal scrolling — the fork's momentum-free native terminal scroll (your
  fix-mobile-ui work: no coasting after finger lift, TUI scroll budget/quantizer, scroll-speed
  slider) survived the merge intact and all its regression tests still pass.
- The state-sync v2 workspace record now carries upstream's `simulators` array **alongside** the
  fork's four `supermux_*` fields; both decode leniently, so project nesting, activity dots,
  branch subtitles, and PR badges keep working against the new wire format.

### Fork-side (what needed manual resolution)

- **13 conflicted files**, all resolved by taking upstream's code and re-applying the fenced
  SUPERMUX blocks: capability advertising now appends fork capabilities *after* upstream's new
  simulator-capability filter; the `mobile.supermux.*` RPC route sits beside the new
  `mobile.simulator.*` route; `closeWorkspace` keeps the fork's `allowEmptyingWindow` empty-home
  behavior while adopting upstream's new foreign-workspace guard; upstream's last-workspace
  child-exit path (close the window with a respawn-recovery action) is deliberately not taken —
  supermux keeps the window open as the empty home.
- **One new touchpoint (#212)**: upstream added an exhaustive Dock shortcut-routing switch, which
  requires every action (including the fork's ⌘G Run/Stop) to be classified. It routes to the
  main container, never the Dock.
- The localization catalog was merged key-by-key (upstream added Khmer/Ukrainian translations and
  69 new keys; all ~293 fork keys and the two deliberate fork rewrites preserved).
- CI app-host script: upstream parameterized the xcodebuild invocation; the fork's Icon Composer
  exclusion was re-applied on top.

### Watch-outs

- This is **upstream main, not a tagged release** — it includes work upstream has not shipped to
  their users yet.
- Four upstream `CmuxMobileShell` render-grid tests fail identically on pure upstream main
  (verified in a clean worktree) — upstream's own test debt, not a merge regression.
- Per the standing warning in SUPERMUX.md: after any merge touching `WorkspaceListView`, verify
  the **Projects section on a real phone**. The fences all survived and the checker is green, but
  the phone check is the real proof.

### What should feel identical

Everything supermux-specific: Projects, worktrees, Changes panel, run actions, presets, AI
features, the empty-home behavior, and all the fix-mobile-ui scrolling/pairing work.

---

## cmux 0.64.21 → 0.64.22 (2026-08-03)

Merged `manaflow-ai/cmux` main @ `6edf2570b8` — **13 commits, 247 files**. A bugfix release: no
new shortcuts, no changed defaults, nothing to relearn.

### Fixes you will feel

- **Intel Macs no longer crash seconds after launch.** cmux is now the only process-wide crash
  handler, and embedded GhosttyKit no longer links Ghostty's native Sentry initializer. If you run
  cmux on an Intel Mac, this is the reason to take this update.
- **`cmux ssh <host>` works again.** It was failing immediately with a shell syntax error from the
  generated startup script.
- **`close` and `respawn-pane` fail closed on a stale `--surface`.** Passing an explicit surface id
  that no longer exists used to fall through and act on a *different* live surface — i.e. close the
  wrong pane. It now errors instead. Worth knowing if you script cmux.
- **Bash shell integration stops printing `cannot overwrite existing file`** on every prompt under
  `set -o noclobber`.
- **Dock notifications clear when you focus the pane that raised them.**
- **A restored Claude agent stays on its own account** instead of falling back to the ambient one.

### Under the hood

Upstream published four SDKs (including the Rust SDK as `cmux-sdk`) without taking over the `cmux`
CLI package names, and made iOS workspace groups and reconnect dogfood-ready.

### Fork-side

Touchpoint **#142 retired**. The 0.64.21 merge carried a one-line fence working around a compile
break upstream shipped in `84f5755b56` (`#expect` takes a `Comment?`, not a `String`). Upstream
fixed it in `b0b96e7b34`, so the fence is gone and the file is byte-identical to upstream again —
exactly the retirement path that row predicted.

Everything else is unchanged: no fence moved, no supermux behavior needed re-applying, and the
only other conflict was one `@State` block in the iOS workspace list where upstream added group
rename/destructive state next to the fork's projects-section model (kept both).

### What should feel identical

Everything. No fork feature, shortcut, or setting changed in this update.

---

## cmux 0.64.20 → 0.64.21 (2026-08-03)

Merged `manaflow-ai/cmux` main @ `06bc29603c` — **1669 commits, 5065 files**.

### Shortcuts — the thing you hit first

Upstream took **⌃⌘=** for a new workspace-wide terminal font zoom family and moved Equalize
Splits out of the way:

| Chord | Before | Now |
|-------|--------|-----|
| ⌃⌘= | Equalize Splits | **Increase terminal font size** (every terminal in the workspace) |
| ⌃⌘- | — | **Decrease terminal font size** |
| ⌃⌘0 | — | **Reset terminal font size** |
| ⌃⇧⌘= | — | Equalize Splits |
| ⇧⌘T | — | **Reopen last closed item** |
| ⌘[ / ⌘] | — | **Global workspace focus history** (back / forward) |

There is no migration for a *persisted* Equalize Splits binding: if your `cmux.json` pins
`equalizeSplits` to ⌃⌘=, you keep it and cmux will report a conflict against the new font-size
action. Unbind or rebind it. If you never overrode it, you just get the new defaults.

Every supermux chord is unchanged and re-verified collision-free against upstream's expanded
default table: **⌘G** run/stop, **⌘\`** / **⇧⌘\`** workspace switcher, **⌘↩** / **⇧⌘↩** Changes-panel
commit, **⌃⌘Z** pane zoom (the fork's rebind off ⇧⌘↩, which frees that chord for the commit
accelerator).

### Behavior changes worth knowing

- **Closing a workspace group's anchor no longer scatters the group.** Previously the group
  dissolved and its members fell out to the ungrouped root. Now the next member (in sidebar
  order) is promoted to anchor and the group survives; the group is only removed when the anchor
  was its last member. This is the change most likely to feel different day to day, especially
  alongside supermux project nesting.
- **Workspace IDs and Dock panes now survive session restore**, and per-tab terminal zoom
  persists across restarts.
- **Workspace initial commands launch through your login shell**, and agent auto-resume uses the
  normal terminal shell.

### New features

- **Simulator panes** — native iPhone and iPad Simulator inside a pane, with its own commands and
  automation.
- **Mosh transport** for remote workspaces, first-class alongside SSH.
- **Move surfaces between panes** with automatic directional splits; `goto_split:previous` and
  `goto_split:next` cycle every pane with wrapping.
- **Browser** — target profiles from the CLI, and Command-clicking local HTML files opens them in
  a browser pane. Note this also picks up the fork's placement policy: an HTML file opens as a new
  tab in the current pane rather than creating a split.
- **Sidebar** — account and mobile-pairing controls; Markdown links render in workspace metadata.
- **Agent hibernation** now kicks in under critical memory pressure even when routine Agent
  Hibernation is off.
- `cmux restore` runs without a shell.

### Fixes you will feel

- A leaked `openThread` loop that was burning **~90% CPU at idle**.
- Workspace-switch renderer freezes; hidden Ghostty renderer memory is reclaimed; the Vault
  sidebar beachball at large session counts.
- Vim Mode cursor and selection rendering; TextBox IME composition; zsh prompt wrap spacer lines.
- Settings and main-window zombies under AeroSpace.
- Codex, Kimi Code, Grok and Pi sessions restore across relaunch, with no duplicate agent resumes.
- A pile of ssh-tmux, SSH relay and remote-PTY fixes (focus after single-pane promotion, deadlock
  after app restart, stale connection status, `PATH` inherited from cmuxd).

### iOS companion

Upstream rebuilt a lot of the phone: Mac browser panes stream to the phone interactively with
dialogs mirrored, a chronological notification feed, launching agent workspaces from the task
composer, Tailscale connection opt-in with QR-authorized pairing, and a transport rebuilt on one
connectivity authority.

The phone also switched to **mobile state sync v2** — per-record deltas instead of refetching the
whole workspace list. Supermux's four additive workspace fields (`supermux_project_id`,
`supermux_activity`, `supermux_branch`, `supermux_pull_request`) were threaded through that new
path, so project nesting, agent-activity dots, branch subtitles and worktree PR badges keep
working on the phone.

### What should feel identical

Every fork feature: Projects, worktree create/open/remove, the Changes panel, ⌘G run actions,
terminal presets, custom project actions, worktree setup/teardown scripts, AI branch names and
commit messages, the empty-home window behavior, and "new workspaces start in `$HOME`" when
`app.workspaceInheritWorkingDirectory` is off.

That last one is worth calling out: upstream rewrote `TabManager.addWorkspace` to resolve the
working directory through a new policy type and stopped calling the fork's hook, which would have
silently made the setting fall back to Ghostty's `working-directory` config while Settings still
promised the home directory. The fork behavior was re-applied at the new call site.

### Watch-outs

A 1669-commit jump touches a lot. The two areas worth poking first are **session restore** and
**workspace groups** (see the anchor-close change above). The pre-merge commit is tagged
`supermux-pre-merge-0.64.21` if you need to compare or roll back.

### Open decisions this merge surfaced

Neither is decided; both are recorded in `SUPERMUX-TOUCHPOINTS.md`.

- **Retire touchpoints #80–#88?** Upstream has now closed the working-directory inheritance leak
  that motivated them — but with *its* semantics (honor Ghostty's `working-directory`) rather than
  the fork's ("off = always home"). The fork currently keeps its own semantics.
- **Touchpoint #110 is inert.** The fork removes `.searchable` from the iOS workspace list, but
  upstream moved phone search into new files, so the search bar is live again on iOS.

### Known pre-existing debt (not caused by this merge)

- `cmuxTests/PostHogAnalyticsPropertiesTests.swift` has three tests that contradict touchpoint
  #130 (the fork's AppKit-sidebar flag default). They were already red before this merge and need
  a fence.
- `cmuxTests/SSHPTYAttachNoProgressRetryTests.swift` carries a one-line fenced fix
  (`upstream-expect-comment-fix`) for a compile break upstream shipped in `84f5755b56`: `#expect`
  takes a `Comment?`, not a `String`. Delete the fence once upstream fixes it.
