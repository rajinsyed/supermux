# supermux-mcp

A lightweight remote MCP server (Streamable HTTP) for supermux automation:
create git worktrees in registered projects and spawn Claude Code sessions
(the `ccx` launcher) in new supermux workspaces.

It composes two things that already exist:

- **`supermux-projects.json`** (read-only) — the app's registered projects,
  their root paths, worktrees dir, and setup commands.
- **The supermux control socket** (`/tmp/supermux.sock`) — the same v2
  `workspace.create` / `workspace.list` methods the `cmux` CLI uses, so
  spawned sessions appear as real workspaces in the running app.

Worktree creation mirrors `SupermuxGitWorktreeService` semantics: sanitized +
deduplicated branch names, `<root>/<worktreesDirName>/<branch>`,
`git worktree add --no-track -b`, `push.autoSetupRemote=true`, and
`branch.<name>.base` recorded.

## Run

```bash
cd supermux-mcp
bun install
SUPERMUX_MCP_TOKEN=<secret> bun start
# → http://127.0.0.1:8787/mcp
```

Environment:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SUPERMUX_MCP_HOST` | `127.0.0.1` | Bind address. Set to `0.0.0.0` (behind a tunnel/VPN) to make it remote. |
| `SUPERMUX_MCP_PORT` | `8787` | HTTP port. |
| `SUPERMUX_MCP_TOKEN` | generated per run (printed once) | Bearer token required on every request. |
| `SUPERMUX_SOCKET_PATH` | `/tmp/supermux.sock` | supermux control socket. |
| `SUPERMUX_PROJECTS_FILE` | `~/Library/Application Support/cmux/supermux-projects.json` | Projects registry. |
| `SUPERMUX_MCP_CCX_BIN` | `ccx` | Claude Code launcher executable. |

## Connect a client

```bash
claude mcp add --transport http supermux http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <secret>"
```

## Tools

| Tool | What it does |
| --- | --- |
| `list_projects` | Registered supermux projects (id, name, root, worktrees dir). |
| `list_worktrees` | `git worktree list` for a project, flagged supermux-managed or not. |
| `create_worktree` | New worktree + branch in a project (no workspace opened). |
| `spawn_claude_session` | Create a worktree (or use `cwd`), open a supermux workspace there, run the project's setup commands, then launch `ccx [model] [prompt]` in the terminal. On app builds with the `mobile.supermux` local-socket bridge, the worktree + workspace are created through the app's own project opener, so the workspace **nests under its project** in the sidebar (`nested: true` in the result); older builds fall back to a flat-list workspace (`nested: false` + note). |
| `list_workspaces` | Open workspaces in the running app. |

`spawn_claude_session` accepts `model` (`sol` \| `opus` \| `fable` \| any
`claude-*`/`gpt-*` id) and an optional initial `prompt`. The workspace gets
`SUPERMUX_ROOT_PATH` / `SUPERSET_ROOT_PATH` / `SUPERMUX_WORKTREE_PATH` in its
environment, matching the app's own worktree setup-script contract.

## Remote exposure (Tailscale Funnel)

The deployed setup on this Mac:

- launchd agent `com.syedrajin.supermux-mcp` runs
  `~/.config/supermux-mcp/run.sh`, which sources `~/.config/supermux-mcp/env`
  (`0600`: bearer token, socket capability, port, ccx path) and execs
  `bun run src/index.ts`. Logs: `~/Library/Logs/supermux-mcp/`.
- `tailscale funnel --bg 8787` publishes it at
  `https://macbook-pro.<tailnet>.ts.net/mcp` (TLS terminated by Tailscale).
- The capability token in the env file was captured by spawning a workspace
  whose terminal ran `printenv CMUX_SOCKET_CAPABILITY`; a launchd-started
  server is not a descendant of the app, so it needs this envelope for every
  socket command. If the app's capability secret rotates, re-capture it.

Manage: `launchctl kickstart -k gui/$UID/com.syedrajin.supermux-mcp` to
restart, `tailscale funnel --https=443 off` to unpublish.

## Notes

- The Supermux app must be running (the socket serves `workspace.create`).
- **Socket access:** the app's default `cmuxOnly` mode admits a client only if
  it is a descendant of the app process or wraps each command in a capability
  envelope. Start this server from a terminal inside Supermux and it just
  works (it inherits descendant status; the terminal also carries
  `CMUX_SOCKET_CAPABILITY`, which the client auto-uses). For a daemonized /
  launchd-started server, capture that token once from a supermux terminal and
  set it as `SUPERMUX_MCP_CAPABILITY` (release builds sign it with a persistent
  key, so it survives app restarts; DEV builds mint an ephemeral key per run).
- This server never writes `supermux-projects.json`; the app owns it.
  Worktrees created here appear in the app's project disclosure on its next
  refresh because the app lists them straight from `git worktree list`.
- Auth is a single bearer token checked with a constant-time compare. For
  actual remote exposure, put it behind Tailscale/`cloudflared` rather than
  opening the port to the internet.
