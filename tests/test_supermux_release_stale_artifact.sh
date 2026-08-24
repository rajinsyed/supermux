#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_REPO="$TMP_DIR/repo"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$TEST_REPO/scripts" "$BIN_DIR"
cp "$ROOT_DIR/scripts/supermux-release.sh" "$TEST_REPO/scripts/supermux-release.sh"
chmod +x "$TEST_REPO/scripts/supermux-release.sh"

cat > "$TEST_REPO/scripts/ensure-ghosttykit.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ensure\n' >> "${FAKE_ENSURE_LOG:?}"
SH
chmod +x "$TEST_REPO/scripts/ensure-ghosttykit.sh"

cat > "$TEST_REPO/scripts/supermux-ios-release.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if grep -Eq '^(quit|pkill|open)( |$)' "${FAKE_RELEASE_EVENT_LOG:?}" 2>/dev/null; then
  echo 'iOS release started after the Mac app shutdown boundary' >&2
  exit 90
fi
printf 'ios %s\n' "$*" >> "${FAKE_RELEASE_EVENT_LOG}"
echo '==> Stub iOS release complete'
SH
chmod +x "$TEST_REPO/scripts/supermux-ios-release.sh"

cat > "$BIN_DIR/security" <<'SH'
#!/usr/bin/env bash
printf '  1) TESTHASH "Developer ID Application: Test (TEAM)"\n'
SH
chmod +x "$BIN_DIR/security"

cat > "$BIN_DIR/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'rev-parse HEAD') printf '0123456789abcdef\n' ;;
  'submodule update --init --recursive') printf 'submodule\n' >> "${FAKE_RELEASE_PREBUILD_LOG:?}" ;;
  *) echo "unexpected git invocation: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN_DIR/git"

cat > "$BIN_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode 26.3\nBuild version TEST\n'
  exit 0
fi
printf 'xcodebuild\n' >> "${FAKE_RELEASE_PREBUILD_LOG:?}"
printf '%s\n' "$*" >> "${FAKE_XCODEBUILD_LOG:?}"
PCM_MARKER="$HOME/Library/Developer/Xcode/DerivedData/cmux-supermux-release/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/stale.pcm"
if [[ -e "$PCM_MARKER" ]]; then
  echo "stale explicit module cache reached xcodebuild" >&2
  exit 70
fi
case "${FAKE_XCODEBUILD_MODE:?}" in
  success-without-product)
    printf 'fake xcodebuild completed without a product\n'
    exit 0
    ;;
  success-with-product)
    app="$HOME/Library/Developer/Xcode/DerivedData/cmux-supermux-release/Build/Products/Release/cmux.app"
    mkdir -p "$app/Contents/MacOS"
    printf 'binary\n' > "$app/Contents/MacOS/cmux"
    chmod +x "$app/Contents/MacOS/cmux"
    printf 'plist\n' > "$app/Contents/Info.plist"
    printf 'fake xcodebuild completed with a product\n'
    exit 0
    ;;
  fail)
    printf '%s\n' "${FAKE_XCODEBUILD_SENTINEL:?}" >&2
    exit 65
    ;;
  *)
    echo "unexpected fake xcodebuild mode: $FAKE_XCODEBUILD_MODE" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN_DIR/xcodebuild"

cat > "$BIN_DIR/plistbuddy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_PLISTBUDDY_LOG:?}"
SH
chmod +x "$BIN_DIR/plistbuddy"

cat > "$BIN_DIR/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CODESIGN_LOG:?}"
SH
chmod +x "$BIN_DIR/codesign"

cat > "$BIN_DIR/osascript" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'quit %s\n' "$*" >> "${FAKE_RELEASE_EVENT_LOG:?}"
SH
chmod +x "$BIN_DIR/osascript"

cat > "$BIN_DIR/pkill" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'pkill %s\n' "$*" >> "${FAKE_RELEASE_EVENT_LOG:?}"
SH
chmod +x "$BIN_DIR/pkill"

cat > "$BIN_DIR/open" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'open %s\n' "$*" >> "${FAKE_RELEASE_EVENT_LOG:?}"
SH
chmod +x "$BIN_DIR/open"

cat > "$BIN_DIR/spctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN_DIR/spctl"

run_release() {
  local home_dir="$1"
  local mode="$2"
  local output_file="$3"
  local sentinel="${4:-unused}"

  set +e
  HOME="$home_dir" \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    FAKE_ENSURE_LOG="$TMP_DIR/ensure.log" \
    FAKE_RELEASE_PREBUILD_LOG="$TMP_DIR/release-prebuild.log" \
    FAKE_XCODEBUILD_LOG="$TMP_DIR/xcodebuild.log" \
    FAKE_XCODEBUILD_MODE="$mode" \
    FAKE_XCODEBUILD_SENTINEL="$sentinel" \
    bash "$TEST_REPO/scripts/supermux-release.sh" --no-launch --no-ios \
      > "$output_file" 2>&1
  RELEASE_STATUS=$?
  set -e
}

SUCCESS_HOME="$TMP_DIR/home-success"
STALE_APP="$SUCCESS_HOME/Library/Developer/Xcode/DerivedData/cmux-supermux-release/Build/Products/Release/cmux.app"
STALE_PCM="$SUCCESS_HOME/Library/Developer/Xcode/DerivedData/cmux-supermux-release/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/stale.pcm"
mkdir -p "$STALE_APP/Contents/MacOS" "$(dirname "$STALE_PCM")"
printf 'stale\n' > "$STALE_APP/Contents/MacOS/cmux"
printf 'stale module\n' > "$STALE_PCM"
chmod +x "$STALE_APP/Contents/MacOS/cmux"

run_release "$SUCCESS_HOME" success-without-product "$TMP_DIR/success-output.log"
if [[ "$RELEASE_STATUS" -eq 0 ]]; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: release script accepted a stale app after xcodebuild produced nothing" >&2
  exit 1
fi
if [[ -e "$STALE_APP" ]]; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: release script did not remove the stale app before building" >&2
  exit 1
fi
if [[ -e "$STALE_PCM" ]]; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: release script did not remove the stale explicit module cache" >&2
  exit 1
fi
if ! grep -Fq "newly built app executable not found" "$TMP_DIR/success-output.log"; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: missing-product failure did not identify the newly built executable" >&2
  exit 1
fi
if grep -Fq "==> Staging bundle" "$TMP_DIR/success-output.log"; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: release script staged after xcodebuild produced no app" >&2
  exit 1
fi
SUCCESS_LOGS=("$SUCCESS_HOME/Library/Logs/Supermux"/release-build-*.log)
if [[ "${#SUCCESS_LOGS[@]}" -ne 1 || ! -f "${SUCCESS_LOGS[0]}" ]]; then
  cat "$TMP_DIR/success-output.log"
  echo "FAIL: release script did not persist exactly one build log" >&2
  exit 1
fi

FAIL_HOME="$TMP_DIR/home-fail"
FAIL_SENTINEL="sentinel release compiler failure"
run_release "$FAIL_HOME" fail "$TMP_DIR/fail-output.log" "$FAIL_SENTINEL"
if [[ "$RELEASE_STATUS" -ne 65 ]]; then
  cat "$TMP_DIR/fail-output.log"
  echo "FAIL: expected xcodebuild status 65, got $RELEASE_STATUS" >&2
  exit 1
fi
if grep -Fq "==> Staging bundle" "$TMP_DIR/fail-output.log"; then
  cat "$TMP_DIR/fail-output.log"
  echo "FAIL: release script staged after xcodebuild failed" >&2
  exit 1
fi
FAIL_LOGS=("$FAIL_HOME/Library/Logs/Supermux"/release-build-*.log)
if [[ "${#FAIL_LOGS[@]}" -ne 1 || ! -f "${FAIL_LOGS[0]}" ]]; then
  cat "$TMP_DIR/fail-output.log"
  echo "FAIL: failed release did not persist exactly one build log" >&2
  exit 1
fi
if ! grep -Fq "$FAIL_SENTINEL" "${FAIL_LOGS[0]}"; then
  cat "${FAIL_LOGS[0]}"
  echo "FAIL: persistent build log omitted the xcodebuild diagnostic" >&2
  exit 1
fi
if ! grep -Fq "Finished=" "${FAIL_LOGS[0]}" || ! grep -Fq "status=65" "${FAIL_LOGS[0]}"; then
  cat "${FAIL_LOGS[0]}"
  echo "FAIL: persistent build log omitted the xcodebuild exit status" >&2
  exit 1
fi

if [[ "$(grep -c '^ensure$' "$TMP_DIR/ensure.log")" -ne 2 ]]; then
  cat "$TMP_DIR/ensure.log"
  echo "FAIL: release script did not refresh GhosttyKit before both build attempts" >&2
  exit 1
fi
if ! grep -Fq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SUPERMUX_LOCAL_RELEASE' "$TMP_DIR/xcodebuild.log"; then
  cat "$TMP_DIR/xcodebuild.log"
  echo "FAIL: local Release build did not enable profileless Iroh storage" >&2
  exit 1
fi

COMBINED_HOME="$TMP_DIR/home-combined"
COMBINED_INSTALL="$TMP_DIR/install/Supermux.app"
COMBINED_OUTPUT="$TMP_DIR/combined-output.log"
EVENT_LOG="$TMP_DIR/release-events.log"
mkdir -p "$COMBINED_INSTALL/Contents/MacOS"
printf 'old app\n' > "$COMBINED_INSTALL/Contents/MacOS/cmux"
chmod +x "$COMBINED_INSTALL/Contents/MacOS/cmux"
: > "$EVENT_LOG"

set +e
HOME="$COMBINED_HOME" \
PATH="$BIN_DIR:/usr/bin:/bin" \
SUPERMUX_INSTALL_APP="$COMBINED_INSTALL" \
PLISTBUDDY="$BIN_DIR/plistbuddy" \
OSASCRIPT="$BIN_DIR/osascript" \
FAKE_ENSURE_LOG="$TMP_DIR/ensure.log" \
FAKE_RELEASE_PREBUILD_LOG="$TMP_DIR/release-prebuild.log" \
FAKE_XCODEBUILD_LOG="$TMP_DIR/xcodebuild.log" \
FAKE_XCODEBUILD_MODE=success-with-product \
FAKE_XCODEBUILD_SENTINEL=unused \
FAKE_PLISTBUDDY_LOG="$TMP_DIR/plistbuddy.log" \
FAKE_CODESIGN_LOG="$TMP_DIR/codesign.log" \
FAKE_RELEASE_EVENT_LOG="$EVENT_LOG" \
  bash "$TEST_REPO/scripts/supermux-release.sh" --ios-device-id test-phone \
    > "$COMBINED_OUTPUT" 2>&1
COMBINED_STATUS=$?
set -e
if [[ "$COMBINED_STATUS" -ne 0 ]]; then
  cat "$COMBINED_OUTPUT"
  echo "FAIL: combined release exited with status $COMBINED_STATUS" >&2
  exit 1
fi

event_order="$(cut -d' ' -f1 "$EVENT_LOG" | paste -sd, -)"
if [[ "$event_order" != "ios,quit,pkill,open" ]]; then
  cat "$EVENT_LOG"
  cat "$COMBINED_OUTPUT"
  echo "FAIL: expected iOS to finish before the Mac app shutdown boundary, got $event_order" >&2
  exit 1
fi
if ! grep -Fq 'ios --device-id test-phone' "$EVENT_LOG"; then
  cat "$EVENT_LOG"
  echo "FAIL: combined release did not forward the selected iPhone" >&2
  exit 1
fi
if [[ ! -x "$COMBINED_INSTALL/Contents/MacOS/cmux" ]]; then
  cat "$COMBINED_OUTPUT"
  echo "FAIL: combined release did not install the newly built Mac app" >&2
  exit 1
fi
if ! grep -Fq '==> Release complete: macOS + iOS' "$COMBINED_OUTPUT"; then
  cat "$COMBINED_OUTPUT"
  echo "FAIL: combined release did not record overall completion" >&2
  exit 1
fi
if [[ "$(grep -c '^ensure$' "$TMP_DIR/ensure.log")" -ne 3 ]]; then
  cat "$TMP_DIR/ensure.log"
  echo "FAIL: combined release did not refresh GhosttyKit" >&2
  exit 1
fi

prebuild_order="$(paste -sd, "$TMP_DIR/release-prebuild.log")"
if [[ "$prebuild_order" != "submodule,xcodebuild,submodule,xcodebuild,submodule,xcodebuild" ]]; then
  cat "$TMP_DIR/release-prebuild.log"
  echo "FAIL: each Release build must synchronize submodules before xcodebuild; got $prebuild_order" >&2
  exit 1
fi

bash "$ROOT_DIR/tests/test_supermux_ios_release.sh"

echo "PASS: supermux release clears stale artifacts, preserves build failures, completes iOS before self-restarting the Mac app, and validates current iOS signing"
