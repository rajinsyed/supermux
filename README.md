<!-- SUPERMUX:begin readme-fork-rewrite -->
<!-- This README is wholesale fork-owned. On upstream merge conflicts, keep ours.
     Upstream cmux's README (and the README.<lang>.md translations) describe the
     base app: https://github.com/manaflow-ai/cmux -->

<p align="center">
  <img src="AppIcon.icon/Assets/supermux.jpg" alt="supermux" width="128" />
</p>

<h1 align="center">supermux</h1>

<p align="center"><a href="https://github.com/manaflow-ai/cmux">cmux</a>, plus the layer above the terminal: your repos.</p>

supermux is a fork of [cmux](https://github.com/manaflow-ai/cmux), the Ghostty-based macOS terminal built around AI coding agents. cmux covers the terminal side of agent work extremely well: vertical tabs, splits, notification rings when an agent needs input, an embedded browser, a socket API. This fork adds the repo side: registered projects, git worktrees without the ritual, and enough git in the sidebar that you rarely need a separate git client.

## Why this exists

I run a few Claude Code and Codex sessions in parallel, which means I live in git worktrees, and the ritual never changes: `git worktree add`, `cd`, install dependencies, copy the `.env` over, open a workspace, start the dev server. Later, tear it all down and prune the branch. cmux made everything inside the terminal great and left that outer loop entirely to me.

There are tools that own the outer loop (worktree managers like Superset), but they bring their own terminal, and I wasn't giving up cmux's. So this fork bolts the project/worktree model onto cmux directly, in a way that keeps `git merge upstream/main` cheap.

## What it adds

**Projects.** Register a repo once and it stays in the sidebar forever, even with no workspace open. From the project row you open the repo locally or spin up a worktree. Projects get an icon (auto-detected from the repo's logo or favicon, or pick your own file) and a color, and their open workspaces nest under them.

**Worktrees.** Name a branch and you get an isolated checkout with its own workspace. Leave the branch field blank and a small model names it from your workspace description. A per-project setup script runs inside the fresh worktree (`bun install`, `cp "$SUPERMUX_ROOT_PATH/.env" .env`, whatever your repo needs), and a teardown script runs before removal. Removal is dirty-checked so you don't nuke uncommitted work, and worktree rows show live PR badges.

**Changes panel.** A git panel in the right sidebar for the active workspace: changed files, diffs, stage/unstage/discard, commit (⌘↩), push and pull. If the message box is empty, the commit button turns into "Generate & Commit".

**Run actions.** Per-project dev-server commands on ⌘G, with running state shown in the sidebar. Hit ⌘G again to stop.

**Terminal presets and custom actions.** Named terminal setups (command + working directory) and arbitrary per-project actions (open your editor, open a URL, run a script) from the project row.

**Repo-shipped config.** Drop a `.supermux/config.json` in a repo and every machine that registers it imports setup, teardown, run commands, and actions automatically. The project carries its own onboarding:

```json
{
  "setup": ["bun install", "cp \"$SUPERMUX_ROOT_PATH/.env\" .env"],
  "run": ["bun run dev"],
  "actions": [{ "name": "Open dashboard", "command": "open http://localhost:3000", "icon": "deploy" }]
}
```

`.superset/config.json` is read too, so repos already set up for Superset just work. One thing to be clear about: these are shell commands, and setup runs automatically when you create a worktree — so treat a repo's config the way you'd treat its install scripts, and read it before registering a repo you don't trust.

**AI, kept small.** One Vercel AI Gateway key (Settings → Automation) is all the AI there is: it names branches and writes commit messages. The key sits in a private `0600` file, never in `cmux.json`, and is only ever sent to Vercel's AI Gateway — branch naming sends your workspace description as the prompt, commit messages send the staged diff. Without a key, branch names fall back to generated ones and you write your own commit messages; nothing else changes.

**iOS companion.** The upstream iOS app, extended. Browse projects, create and remove worktrees, stage/commit/push from your phone, kick off run actions, manage files. The Mac stays the source of truth; pair a fork phone with a stock cmux Mac and it behaves exactly like the stock app.

## Building it

The desktop app is Swift (SwiftUI hosted in AppKit), macOS 14 or newer, and there are no binary releases here — you build from source. If you just want cmux, grab the [official DMG](https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg) instead.

You need full Xcode and zig 0.15.2 exactly (the Ghostty CLI helper build phase rejects other versions; `ZIG_REQUIRED=0.15.2 ./scripts/install-zig-ci.sh` puts it in the right place). Setup fetches a prebuilt GhosttyKit when one is available, so the first build is not a from-scratch Ghostty compile.

```bash
git clone https://github.com/rajinsyed/supermux.git
cd supermux
./scripts/setup.sh
./scripts/reload.sh --tag dev --launch
```

That last command is the development loop: it builds a tagged Debug app (named "cmux DEV dev", not "supermux" — nothing went wrong) with its own bundle ID and socket, fully isolated from any installed cmux. For a daily driver, `./scripts/supermux-release.sh` builds Release, signs it with your Developer ID, and installs `/Applications/Supermux.app` with its own bundle ID and sockets, so it runs alongside the real cmux instead of replacing it. Either way your existing Ghostty and cmux configuration (`~/.config/ghostty/config`, `~/.config/cmux/cmux.json`) is picked up as-is.

To update: `git pull`, `git submodule update --init --recursive`, rebuild.

## How the fork stays mergeable

The one rule this fork is built around: pulling upstream cmux must stay cheap.

- Most fork code lives in new files: `Packages/SupermuxKit/` and `Sources/Supermux/` on the Mac, `Packages/Shared/SupermuxMobileCore` and `Packages/iOS/SupermuxMobile*` on the phone side. New files essentially never conflict.
- When wiring into an upstream file is unavoidable, the edit is a few lines fenced with `// SUPERMUX:begin <id>` … `// SUPERMUX:end <id>`, and every fence is registered in [SUPERMUX-TOUCHPOINTS.md](SUPERMUX-TOUCHPOINTS.md) with instructions for re-applying it by hand if a merge eats it.
- `./scripts/supermux-check-touchpoints.sh` fails whenever the fences in the tree and the registry disagree.
- The merge playbook, conflict heuristics, and the full fork contract live in [SUPERMUX.md](SUPERMUX.md).

If you maintain a long-lived fork of anything, this pattern is worth stealing.

## Everything else is cmux

The credit goes to [Manaflow](https://github.com/manaflow-ai): the terminal itself, notifications, the in-app browser, SSH workspaces, session restore, the CLI and socket API, and the iOS app this fork extends. Read the [cmux README](https://github.com/manaflow-ai/cmux#readme) and the [docs](https://cmux.com/docs/getting-started) for all of that. The fork exists to stay mergeable with upstream, not to diverge from it.

This is a personal fork. Issues and PRs for fork features are welcome here; anything about cmux itself belongs upstream at [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux/issues).

## License

The base app is Copyright Manaflow, Inc. and dual-licensed — GPL-3.0-or-later, with a commercial option from Manaflow (see [LICENSE](LICENSE)). This fork and its additions are distributed under GPL-3.0-or-later only.
<!-- SUPERMUX:end readme-fork-rewrite -->
