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

cat > "$BIN_DIR/security" <<'SH'
#!/usr/bin/env bash
printf '  1) TESTHASH "Developer ID Application: Test (TEAM)"\n'
SH
chmod +x "$BIN_DIR/security"

cat > "$BIN_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode 26.3\nBuild version TEST\n'
  exit 0
fi
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

run_release() {
  local home_dir="$1"
  local mode="$2"
  local output_file="$3"
  local sentinel="${4:-unused}"

  set +e
  HOME="$home_dir" \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    FAKE_ENSURE_LOG="$TMP_DIR/ensure.log" \
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
  echo "FAIL: release script did not refresh GhosttyKit before both builds" >&2
  exit 1
fi
if ! grep -Fq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SUPERMUX_LOCAL_RELEASE' "$TMP_DIR/xcodebuild.log"; then
  cat "$TMP_DIR/xcodebuild.log"
  echo "FAIL: local Release build did not enable profileless Iroh storage" >&2
  exit 1
fi

bash "$ROOT_DIR/tests/test_supermux_ios_release.sh"

echo "PASS: supermux release refreshes GhosttyKit, clears stale modules and products, preserves xcodebuild status, logs failures, and validates the iOS production release path"
