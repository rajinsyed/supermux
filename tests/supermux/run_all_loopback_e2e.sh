#!/usr/bin/env bash
# Runs every remote-workspaces loopback E2E suite against ONE tagged DEBUG build
# and writes a combined JSON summary.
#
#   ./scripts/reload.sh --tag <tag> --supermux-profile      # build (never sign out in it)
#   CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh    # launch, run, quit
#   CMUX_E2E_SUITES="loopback_terminal_input_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
#
# Scratch state lives in /tmp/<tag>-e2e (projects file, push state, repos), so
# the user's real project list and push credentials are never touched.
set -euo pipefail

TAG="${CMUX_TAG:?set CMUX_TAG to the tagged build}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${CMUX_APP_PATH:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG}/Build/Products/Debug/cmux DEV ${TAG}.app}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
SCRATCH="/tmp/${TAG}-e2e"
SOCKET="/tmp/cmux-debug-${TAG}.sock"
REPORTS="$SCRATCH/reports"

app_running() {
  [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == "true" ]]
}

quit_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  # Quit defers for the session save and agent-process scan (often ~10 s), and
  # the socket goes before the process: relaunching then makes `open` reuse the
  # dying app without the environment. Wait for the process itself.
  for _ in $(seq 1 150); do app_running || [[ -S "$SOCKET" ]] || return 0; sleep 0.2; done
}

launch_app() {
  open -g \
    --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 \
    --env "SUPERMUX_PROJECTS_FILE=$SCRATCH/projects.json" \
    --env "SUPERMUX_PHONE_PUSH_STATE_DIR=$SCRATCH/push-state" \
    "$APP"
  for _ in $(seq 1 100); do [[ -S "$SOCKET" ]] && break; sleep 0.2; done
  [[ -S "$SOCKET" ]] || { echo "app did not open $SOCKET" >&2; exit 1; }
  sleep 4 # let the loopback link connect and auto-mirror settle
}

quit_app
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/push-state" "$REPORTS"
chmod 700 "$SCRATCH/push-state"
# The auto-mirror suite's branch check opens a workspace in this repository, so it must exist.
git init -q -b main "$SCRATCH/auto-mirror-repo"
git -C "$SCRATCH/auto-mirror-repo" -c user.email=e2e@example.com -c user.name="Supermux E2E" \
  commit -q --allow-empty -m init
cd "$ROOT"

# One line per suite: name, then its extra arguments (one per line in the case).
suite_args() {
  case "$1" in
    loopback_projects_e2e) printf '%s\n' --scratch "$SCRATCH/projects" --projects-file "$SCRATCH/projects.json" --app-path "$APP" --push-state-dir "$SCRATCH/push-state" ;;
    loopback_new_worktree_picker_e2e) printf '%s\n' --scratch "$SCRATCH/picker" ;;
    loopback_worktree_disclosure_e2e) printf '%s\n' --scratch "$SCRATCH/disclosure" ;;
    loopback_notifications_e2e) printf '%s\n' --push-state-dir "$SCRATCH/push-state" --work-dir "$SCRATCH/notifications" ;;
    loopback_auto_mirror_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" --git-repo "$SCRATCH/auto-mirror-repo" ;;
    loopback_mirror_render_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_mirror_appearance_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_sidebar_rows_e2e) printf '%s\n' --scratch "$SCRATCH/rows" ;;
    loopback_terminal_input_e2e) printf '%s\n' --scratch "$SCRATCH/terminal-input" ;;
    loopback_terminal_sizing_policy_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_new_tab_order_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_agent_activity_e2e) printf '%s\n' --scratch "$SCRATCH/activity" ;;
    loopback_mirror_files_e2e) printf '%s\n' --scratch "$SCRATCH/files" --app-path "$APP" --projects-file "$SCRATCH/projects.json" --push-state-dir "$SCRATCH/push-state" ;;
    loopback_mirror_workspace_close_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
  esac
}

# The mirror-render and auto-mirror suites run last: they quit and relaunch the app for their restart checks.
# CMUX_E2E_SUITES="a b" runs only those suites (same order rules).
SUITES=(${CMUX_E2E_SUITES:-loopback_device_smoke loopback_projects_e2e loopback_worktree_disclosure_e2e loopback_new_worktree_picker_e2e loopback_workspace_behaviors_e2e loopback_notifications_e2e loopback_tab_sync_e2e loopback_remote_macs_settings_e2e loopback_sidebar_rows_e2e loopback_terminal_input_e2e loopback_mirror_tab_close_e2e loopback_mirror_workspace_close_e2e loopback_mirror_appearance_e2e loopback_new_tab_order_e2e loopback_terminal_sizing_policy_e2e loopback_mirror_files_e2e loopback_agent_activity_e2e loopback_mirror_local_panels_e2e loopback_mirror_browser_e2e loopback_device_tunnel_e2e loopback_mirror_render_e2e loopback_auto_mirror_e2e})

status=0
for name in "${SUITES[@]}"; do
  args=()
  while IFS= read -r line; do [[ -n "$line" ]] && args+=("$line"); done < <(suite_args "$name")
  quit_app
  launch_app
  echo "==> $name"
  if CMUX_TAG="$TAG" python3 "tests/supermux/$name.py" "${args[@]+"${args[@]}"}" --report "$REPORTS/$name.json" >"$REPORTS/$name.log" 2>&1; then
    echo "    PASS"
  else
    echo "    FAIL (see $REPORTS/$name.log)"
    status=1
  fi
done
quit_app

python3 - "$REPORTS" "$SCRATCH/summary.json" <<'PY'
import json, pathlib, sys
reports, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
summary = {}
for path in sorted(reports.glob("*.json")):
    data = json.loads(path.read_text())
    steps = data.get("steps", [])
    summary[path.stem] = {
        "passed": bool(data.get("passed")),
        "steps": len(steps),
        "failed_steps": [s.get("name") for s in steps if not s.get("ok") and not s.get("skipped")],
        "skipped_steps": [s.get("name") for s in steps if s.get("skipped")],
    }
out.write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY
exit $status
