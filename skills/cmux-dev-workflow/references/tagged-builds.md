# Tagged Builds

Tagged builds isolate app name, bundle ID, debug socket, and DerivedData path so multiple agents and the user's normal app do not collide.

```bash
./scripts/reload.sh --tag <tag>            # build only (default)
./scripts/reload.sh --tag <tag> --launch   # build, then open
```

After a successful build `reload.sh` terminates any running app with the same tag, so opening the printed app path launches the fresh binary.

<!-- SUPERMUX:begin dogfood-direct-launch-link-skill -->
## Direct launch links

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use it for local
verification only. Tagged Debug builds register `cmux-dev-<tag>://`; hand off a build with a direct
Markdown link:

```markdown
[Open <tag>](cmux-dev-<tag>://launch)
```

This launches the app through macOS LaunchServices without opening a browser. If the build was made
without `--launch`, first register the printed app path without launching it:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "<App path printed by reload.sh>"
```

Use the normalized tag slug printed by `reload.sh`. The `launch` host is intentionally inert;
`auth-callback` is reserved for sign-in. Do not use the old `http://127.0.0.1:17320/<tag>` Tag
Opener link, which depends on a local server and opens the embedded browser when that server is
absent. Never put a `file://` URL, raw `.app` or DerivedData path, or `/tmp/cmux-<tag>/...` in chat
output.
<!-- SUPERMUX:end dogfood-direct-launch-link-skill -->

## Tagged CLI and socket

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, uses the matching tagged CLI from DerivedData, scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for that tag.

`/tmp/cmux-cli` points at the most recently reloaded build and can target the user's main app socket, so it is never safe for tagged dogfood.

## Cleanup

Before launching a new tagged run, quit older tagged apps you started this session and remove their stale `/tmp` sockets. Remove derived data only when no active task needs it.
