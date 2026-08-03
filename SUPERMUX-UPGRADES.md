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
