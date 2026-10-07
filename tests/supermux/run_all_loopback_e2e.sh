#!/usr/bin/env bash
# Runs every remote-workspaces loopback E2E suite against ONE tagged DEBUG build
# and writes a combined JSON summary.
#
#   CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <tag>   # agent-only build
#   CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh            # launch, run, quit
#   CMUX_E2E_SUITES="loopback_terminal_input_e2e" CMUX_TAG=<tag> tests/supermux/run_all_loopback_e2e.sh
#
# Only an agent-only build: never --supermux-profile or --prod-auth. Those copy the
# user's release defaults and sign-in and talk to production cmux.com, so the build
# shows up on the user's account. require_isolated_app.py refuses such an app (or a
# tag that was seeded once) before anything launches; the loopback device is
# in-process and needs no sign-in.
#
# Every suite talks to this tag's socket, passed explicitly: a shell inside a
# Supermux terminal exports CMUX_SOCKET_PATH (the user's running app).
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

# Never a build that can reach the user's real account, Macs or app (see the header).
python3 "$ROOT/tests/supermux/require_isolated_app.py" --app "$APP" --tag "$TAG" || exit 1

app_running() {
  [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == "true" ]]
}

quit_app() {
  # Do not wait for the quit's reply: a hung app never answers, and AppleScript would wait out its 120 s reply
  # timeout before the 30 s wait below even starts.
  osascript -e "ignoring application responses" -e "tell application id \"$BUNDLE_ID\" to quit" \
    -e "end ignoring" >/dev/null 2>&1 || true
  # Quit defers for the session save and agent-process scan (often ~10 s), and
  # the socket goes before the process: relaunching then makes `open` reuse the
  # dying app without the environment. Wait for the process itself.
  for _ in $(seq 1 150); do app_running || [[ -S "$SOCKET" ]] || return 0; sleep 0.2; done
  stop_hung_app
}

# A tagged build that does not quit within 30 s is hung. Never leave it behind: macOS keeps taking hang
# reports (spindump) of a hung app, and a spindump busy for hours is the likely cause of a Mac where every
# new process stalls in dyld before main (LOOPBACK-HARNESS.md "A slow simctl"). Only this tagged build's
# executable (the app and its simulator workers) is stopped, never another app.
stop_hung_app() {
  local exe="$APP/Contents/MacOS/"
  pgrep -f "$exe" >/dev/null || return 0
  echo "the tagged app did not quit within 30 s (hung?); stopping it: $(pgrep -f "$exe" | tr '\n' ' ')" >&2
  pkill -TERM -f "$exe" 2>/dev/null || true
  for _ in $(seq 1 25); do pgrep -f "$exe" >/dev/null || return 0; sleep 0.2; done
  pkill -KILL -f "$exe" 2>/dev/null || true
}

launch_app() {
  # CMUX_E2E_SLOW_SIMCTL=<seconds> arms the app's DEBUG slow-simctl hook from launch on (every simctl spawn of
  # its Simulator panels waits that long; the simulator suite also arms it itself, see --slow-simctl there).
  local slow=()
  [[ -n "${CMUX_E2E_SLOW_SIMCTL:-}" ]] && slow=(--env "SUPERMUX_DEBUG_SIMCTL_DELAY_SECONDS=$CMUX_E2E_SLOW_SIMCTL")
  open -g \
    --env SUPERMUX_DEBUG_LOOPBACK_DEVICE=1 \
    --env "SUPERMUX_PROJECTS_FILE=$SCRATCH/projects.json" \
    --env "SUPERMUX_PHONE_PUSH_STATE_DIR=$SCRATCH/push-state" \
    "${slow[@]+"${slow[@]}"}" \
    "$APP"
  for _ in $(seq 1 100); do [[ -S "$SOCKET" ]] && break; sleep 0.2; done
  [[ -S "$SOCKET" ]] || { echo "app did not open $SOCKET" >&2; exit 1; }
  sleep 4 # let the loopback link connect and auto-mirror settle
  require_window_on_screen
}

# Suites check what the user sees (panes that count, drawn frames, Simulator
# streams, screenshots), so the app's window must really be on screen. `open -g`
# puts it on the desktop Space: while another app is in native full screen on
# the display (its Space is the one shown), or the screen is locked or asleep,
# the window reports itself covered and every visual check fails for nothing.
# CMUX_E2E_ALLOW_COVERED_WINDOW=1 runs anyway (for suites that check no pixels).
require_window_on_screen() {
  [[ "${CMUX_E2E_ALLOW_COVERED_WINDOW:-}" == "1" ]] && return 0
  python3 - "$SOCKET" <<'PY' || exit 1
import json, socket, sys, time
deadline = time.monotonic() + 15
while True:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sys.argv[1])
    s.sendall(b'{"id":1,"method":"debug.terminals","params":{}}\n')
    buf = b""
    while b"\n" not in buf:
        buf += s.recv(1 << 20)
    s.close()
    terminals = (json.loads(buf.split(b"\n", 1)[0]).get("result") or {}).get("terminals") or []
    if any(t.get("window_visible") and t.get("window_occluded") is False for t in terminals):
        sys.exit(0)
    if time.monotonic() > deadline:
        print("the app's window is not on screen: is another app in native full screen on this display (show the "
              "desktop Space), or is the screen locked or asleep? CMUX_E2E_ALLOW_COVERED_WINDOW=1 runs anyway.",
              file=sys.stderr)
        sys.exit(1)
    time.sleep(0.5)
PY
}

# On a Mac where new processes stall in dyld before main (every `simctl` took 20-22 s on 2026-10-03 while ls and
# xcrun stayed fast), the simulator suite's own `simctl` calls (create, boot, bootstatus, the stir that makes the
# simulator draw, screenshots) time out, so its result would say nothing about the app; the app itself keeps
# working (steps 20-21 check it with the app's simctl slowed down). So check `simctl help` before that suite and stop
# with the cause. CMUX_E2E_ALLOW_SLOW_SIMCTL=1 runs anyway; CMUX_E2E_SIMCTL_THRESHOLD (seconds, default 2) sets the bar.
require_fast_simctl() {
  [[ "${CMUX_E2E_ALLOW_SLOW_SIMCTL:-}" == "1" ]] && return 0
  local check
  check="$("$ROOT/tests/supermux/simctl_stall_monitor.sh" --once --threshold "${CMUX_E2E_SIMCTL_THRESHOLD:-2}" 2>&1)" \
    && return 0
  echo "STOPPED before loopback_mirror_simulator_e2e: simctl is slow on this Mac ($check)." >&2
  echo "New processes are stalling in dyld before main: an image-load observer (likely spindump or a stray sample)" \
    "holds up every launch it attaches to, so this suite's own simctl calls would time out and its failures would" \
    "not be the app's. Evidence was captured in the dir above. A reboot clears it (see LOOPBACK-HARNESS.md" \
    "\"A slow simctl\"); CMUX_E2E_ALLOW_SLOW_SIMCTL=1 runs the suite anyway." >&2
  quit_app
  exit 1
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
    loopback_background_worktree_e2e) printf '%s\n' --scratch "$SCRATCH/background" ;;
    loopback_worktree_disclosure_e2e) printf '%s\n' --scratch "$SCRATCH/disclosure" ;;
    loopback_notifications_e2e) printf '%s\n' --push-state-dir "$SCRATCH/push-state" --work-dir "$SCRATCH/notifications" ;;
    loopback_auto_mirror_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" --git-repo "$SCRATCH/auto-mirror-repo" ;;
    loopback_mirror_render_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_mirror_appearance_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_sidebar_rows_e2e) printf '%s\n' --scratch "$SCRATCH/rows" ;;
    loopback_nested_reorder_e2e) printf '%s\n' --scratch "$SCRATCH/reorder" ;;
    loopback_terminal_input_e2e) printf '%s\n' --scratch "$SCRATCH/terminal-input" ;;
    loopback_terminal_input_pipeline_e2e) printf '%s\n' --scratch "$SCRATCH/terminal-input-pipeline" ;;
    loopback_degraded_link_e2e) printf '%s\n' --scratch "$SCRATCH/degraded-link" ;;
    loopback_device_route_e2e) printf '%s\n' --projects-file "$SCRATCH/projects.json" ;;
    loopback_terminal_clipboard_e2e) printf '%s\n' --scratch "$SCRATCH/terminal-clipboard" ;;
    loopback_terminal_polish_e2e) printf '%s\n' --scratch "$SCRATCH/terminal-polish" ;;
    loopback_terminal_sizing_policy_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_new_tab_order_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_agent_activity_e2e) printf '%s\n' --scratch "$SCRATCH/activity" ;;
    loopback_agent_answer_e2e) printf '%s\n' --scratch "$SCRATCH/answer" ;;
    loopback_mirror_files_e2e) printf '%s\n' --scratch "$SCRATCH/files" --app-path "$APP" --projects-file "$SCRATCH/projects.json" --push-state-dir "$SCRATCH/push-state" ;;
    loopback_mirror_workspace_close_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_mirror_simulator_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" ;;
    loopback_remote_host_mode_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" --push-state-dir "$SCRATCH/push-state" ;;
    right_sidebar_width_e2e|sidebar_font_scale_e2e) printf '%s\n' --app-path "$APP" --projects-file "$SCRATCH/projects.json" --push-state-dir "$SCRATCH/push-state" ;;
    project_action_target_e2e) printf '%s\n' --app-path "$APP" --push-state-dir "$SCRATCH/push-state" ;;
  esac
}

# The remote-host-mode, mirror-render and auto-mirror suites run last: they quit and relaunch the app for their restart checks;
# right_sidebar_width_e2e and sidebar_font_scale_e2e relaunch it with preferences set before launch;
# project_action_target_e2e relaunches it with a projects document of its own.
# CMUX_E2E_SUITES="a b" runs only those suites (same order rules). loopback_degraded_link_e2e (~5 min) is not in the
# default list: it is the red regression for the slow-link latency fixes; run it by name until they land.
SUITES=(${CMUX_E2E_SUITES:-loopback_device_smoke loopback_device_route_e2e loopback_device_route_switch_e2e loopback_device_sleep_wake_e2e loopback_projects_e2e loopback_worktree_disclosure_e2e loopback_new_worktree_picker_e2e loopback_background_worktree_e2e loopback_workspace_behaviors_e2e loopback_notifications_e2e loopback_tab_sync_e2e loopback_remote_macs_settings_e2e loopback_sidebar_rows_e2e loopback_nested_reorder_e2e loopback_terminal_input_e2e loopback_terminal_input_pipeline_e2e loopback_terminal_clipboard_e2e loopback_mirror_tab_close_e2e loopback_mirror_workspace_close_e2e loopback_mirror_appearance_e2e loopback_new_tab_order_e2e loopback_terminal_sizing_policy_e2e loopback_terminal_sizing_recovery_e2e loopback_mirror_files_e2e loopback_agent_activity_e2e loopback_agent_answer_e2e loopback_mirror_simulator_e2e loopback_port_forward_e2e loopback_mirror_local_panels_e2e loopback_mirror_browser_e2e loopback_device_tunnel_e2e loopback_mirror_render_e2e loopback_auto_mirror_e2e loopback_terminal_streaming_e2e loopback_terminal_resize_integrity_e2e loopback_terminal_polish_e2e right_sidebar_width_e2e sidebar_font_scale_e2e project_action_target_e2e loopback_remote_host_mode_e2e})

status=0
for name in "${SUITES[@]}"; do
  args=()
  while IFS= read -r line; do [[ -n "$line" ]] && args+=("$line"); done < <(suite_args "$name")
  [[ "$name" == loopback_mirror_simulator_e2e ]] && require_fast_simctl
  quit_app
  launch_app
  echo "==> $name"
  if CMUX_TAG="$TAG" CMUX_SOCKET_PATH="$SOCKET" python3 "tests/supermux/$name.py" --socket "$SOCKET" \
      "${args[@]+"${args[@]}"}" --report "$REPORTS/$name.json" >"$REPORTS/$name.log" 2>&1; then
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
