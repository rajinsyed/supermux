#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_REPO="$TMP_DIR/repo"
BIN_DIR="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/ios" "$BIN_DIR" "$HOME_DIR" "$LOG_DIR"
cp "$ROOT_DIR/scripts/supermux-ios-release.sh" "$TEST_REPO/scripts/supermux-ios-release.sh"
chmod +x "$TEST_REPO/scripts/supermux-ios-release.sh"

cat > "$TEST_REPO/scripts/ensure-ghosttykit.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ensure\n' >> "${FAKE_ENSURE_LOG:?}"
SH
chmod +x "$TEST_REPO/scripts/ensure-ghosttykit.sh"

cat > "$BIN_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode 26.3\nBuild version TEST\n'
  exit 0
fi
printf '%s\n' "$*" >> "${FAKE_XCODEBUILD_LOG:?}"
derived_data=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == "-derivedDataPath" ]]; then
    derived_data="${args[$((index + 1))]}"
    break
  fi
done
[[ -n "$derived_data" ]] || { echo 'missing -derivedDataPath' >&2; exit 2; }
app="$derived_data/Build/Products/Release-iphoneos/cmux.app"
if [[ -e "$app/stale-product" ]]; then
  echo 'stale iOS product reached xcodebuild' >&2
  exit 70
fi
nse="$app/PlugIns/SupermuxNotificationService.appex"
mkdir -p "$nse"
printf 'binary\n' > "$app/cmux"
chmod +x "$app/cmux"
/usr/bin/python3 - "$app/Info.plist" "$nse/Info.plist" <<'PY'
import plistlib
import sys

app_path, nse_path = sys.argv[1:]
with open(app_path, "wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "com.supermux.ios",
            "CFBundleDisplayName": "Supermux",
            "CMUXDevTag": "",
            "CMUXAuthEnvironment": "production",
            "CFBundleURLTypes": [
                {"CFBundleURLSchemes": ["cmux-ios-com.supermux.ios"]},
            ],
            "NSUserActivityTypes": ["INSendMessageIntent"],
        },
        handle,
    )
with open(nse_path, "wb") as handle:
    plistlib.dump(
        {
            "CFBundleIdentifier": "com.supermux.ios.notification-service",
            "NSExtension": {
                "NSExtensionPointIdentifier": "com.apple.usernotifications.service",
                "NSExtensionPrincipalClass": "NotificationService",
            },
        },
        handle,
    )
PY
printf 'fake iOS Release build\n'
SH
chmod +x "$BIN_DIR/xcodebuild"

# The fake phone is reachable until an install fails. A failing install (the
# first FAKE_INSTALL_FAILURES calls, exiting with FAKE_INSTALL_ERROR on stderr)
# drops the tunnel for FAKE_UNREACHABLE_POLLS readiness probes, then the phone
# comes back and the next install succeeds. Counters live in FAKE_XCRUN_STATE.
cat > "$BIN_DIR/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_XCRUN_LOG:?}"
state="${FAKE_XCRUN_STATE:-}"
counter() { [[ -n "$state" && -f "$state/$1" ]] && cat "$state/$1" || printf '0'; }
case "$*" in
  'devicectl device info details --device test-phone')
    remaining="$(counter unreachable-polls)"
    if [[ "$remaining" -gt 0 ]]; then
      printf '%s' "$((remaining - 1))" > "$state/unreachable-polls"
      echo 'ERROR: The device is not able to fulfill the requested usage assertion requirements. (com.apple.dt.CoreDeviceError error 4016)' >&2
      exit 1
    fi
    exit 0 ;;
  'devicectl device install app --device test-phone '*)
    remaining="$(counter install-failures)"
    if [[ "$remaining" -gt 0 ]]; then
      printf '%s' "$((remaining - 1))" > "$state/install-failures"
      printf '%s' "${FAKE_UNREACHABLE_POLLS:-0}" > "$state/unreachable-polls"
      echo "${FAKE_INSTALL_ERROR:?}" >&2
      exit 1
    fi
    exit 0 ;;
  'devicectl device process launch --terminate-existing --device test-phone com.supermux.ios') exit 0 ;;
  *) echo "unexpected xcrun invocation: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN_DIR/xcrun"

cat > "$BIN_DIR/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CODESIGN_LOG:?}"
if [[ "$*" == *'--entitlements :- --xml'* ]]; then
  target="${@: -1}"
  if [[ "$target" == *.appex ]]; then
    cat <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>application-identifier</key><string>ABCD123456.com.supermux.ios.notification-service</string>
<key>com.apple.developer.team-identifier</key><string>ABCD123456</string>
<key>com.apple.security.application-groups</key><array><string>group.com.supermux.ios</string></array>
</dict></plist>
PLIST
  else
    cat <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>aps-environment</key><string>production</string>
<key>application-identifier</key><string>ABCD123456.com.supermux.ios</string>
<key>com.apple.developer.team-identifier</key><string>ABCD123456</string>
<key>com.apple.developer.usernotifications.time-sensitive</key><true/>
<key>com.apple.developer.usernotifications.communication</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.com.supermux.ios</string></array>
</dict></plist>
PLIST
  fi
fi
SH
chmod +x "$BIN_DIR/codesign"

cat > "$BIN_DIR/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "cms" ]]; then
  input=""
  args=("$@")
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[$index]}" == "-i" ]]; then
      input="${args[$((index + 1))]}"
      break
    fi
  done
  [[ -n "$input" && -f "$input" ]] || { echo 'missing profile input' >&2; exit 2; }
  if grep -Fq 'nse-profile' "$input"; then
    cat <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>Name</key><string>Supermux Notification Service Ad Hoc</string>
<key>TeamIdentifier</key><array><string>ABCD123456</string></array>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>ABCD123456.com.supermux.ios.notification-service</string>
<key>com.apple.developer.team-identifier</key><string>ABCD123456</string>
<key>com.apple.security.application-groups</key><array><string>group.com.supermux.ios</string></array>
</dict>
</dict></plist>
PLIST
  else
    cat <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>Name</key><string>Supermux iPhone Ad Hoc</string>
<key>TeamIdentifier</key><array><string>ABCD123456</string></array>
<key>Entitlements</key><dict>
<key>aps-environment</key><string>production</string>
<key>application-identifier</key><string>ABCD123456.com.supermux.ios</string>
<key>com.apple.developer.team-identifier</key><string>ABCD123456</string>
<key>com.apple.developer.usernotifications.time-sensitive</key><true/>
<key>com.apple.developer.usernotifications.communication</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.com.supermux.ios</string></array>
</dict>
</dict></plist>
PLIST
  fi
  exit 0
fi
echo "unexpected security invocation: $*" >&2
exit 2
SH
chmod +x "$BIN_DIR/security"

cat > "$BIN_DIR/plistbuddy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
xml=0
if [[ "${1:-}" == "-x" ]]; then xml=1; shift; fi
[[ "${1:-}" == "-c" ]] || { echo 'missing -c' >&2; exit 2; }
command="${2:-}"
file="${3:-}"
/usr/bin/python3 - "$file" "$command" "$xml" <<'PY'
import plistlib
import sys

path, command, xml = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, "rb") as handle:
    value = plistlib.load(handle)
for component in command.removeprefix("Print :").split(":"):
    value = value[int(component)] if isinstance(value, list) else value[component]
if xml:
    sys.stdout.buffer.write(plistlib.dumps(value, fmt=plistlib.FMT_XML))
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
SH
chmod +x "$BIN_DIR/plistbuddy"

DERIVED_DATA="$HOME_DIR/Library/Developer/Xcode/DerivedData/cmux-ios-supermux-release"
STALE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/cmux.app"
STALE_PCM="$DERIVED_DATA/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/stale.pcm"
mkdir -p "$STALE_APP" "$(dirname "$STALE_PCM")"
PROFILES_DIR="$HOME_DIR/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
printf 'app-profile\n' > "$PROFILES_DIR/app-adhoc.mobileprovision"
printf 'nse-profile\n' > "$PROFILES_DIR/nse-adhoc.mobileprovision"
printf 'stale\n' > "$STALE_APP/stale-product"
printf 'stale module\n' > "$STALE_PCM"

OUTPUT_FILE="$TMP_DIR/output.log"
HOME="$HOME_DIR" \
PATH="$BIN_DIR:/usr/bin:/bin" \
SUPERMUX_IOS_DEVELOPMENT_TEAM=ABCD123456 \
SUPERMUX_RELEASE_LOG_DIR="$LOG_DIR" \
SUPERMUX_GIT_SHA=0123456789 \
XCODEBUILD="$BIN_DIR/xcodebuild" \
XCRUN="$BIN_DIR/xcrun" \
CODESIGN="$BIN_DIR/codesign" \
SECURITY="$BIN_DIR/security" \
PLISTBUDDY="$BIN_DIR/plistbuddy" \
FAKE_ENSURE_LOG="$TMP_DIR/ensure.log" \
FAKE_XCODEBUILD_LOG="$TMP_DIR/xcodebuild.log" \
FAKE_XCRUN_LOG="$TMP_DIR/xcrun.log" \
FAKE_CODESIGN_LOG="$TMP_DIR/codesign.log" \
  bash "$TEST_REPO/scripts/supermux-ios-release.sh" --device-id test-phone \
    > "$OUTPUT_FILE" 2>&1

[[ "$(grep -c '^ensure$' "$TMP_DIR/ensure.log")" -eq 1 ]] \
  || { cat "$OUTPUT_FILE"; echo 'FAIL: iOS release did not refresh GhosttyKit exactly once' >&2; exit 1; }
[[ ! -e "$STALE_PCM" ]] \
  || { cat "$OUTPUT_FILE"; echo 'FAIL: iOS release did not clear the stale explicit module cache' >&2; exit 1; }

grep -F -- '-workspace ' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- '-scheme cmux-ios' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- '-configuration Release' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- '-destination generic/platform=iOS' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'SUPERMUX_APP_BUNDLE_ID=com.supermux.ios' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_DEV_TAG=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_PRESENCE_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_API_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_IROH_BROKER_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_IOS_AUTH_ENV=production' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'DEVELOPMENT_TEAM=ABCD123456' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CODE_SIGN_STYLE=Manual' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'SUPERMUX_APP_DEV_PROFILE_SPECIFIER=Supermux iPhone Development' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'SUPERMUX_NSE_DEV_PROFILE_SPECIFIER=Supermux Notification Service Development' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'SUPERMUX_APP_CODE_SIGN_ENTITLEMENTS=Config/supermux.entitlements' "$TMP_DIR/xcodebuild.log" >/dev/null
if grep -Eq '(^| )PRODUCT_BUNDLE_IDENTIFIER=' "$TMP_DIR/xcodebuild.log"; then
  cat "$TMP_DIR/xcodebuild.log"
  echo 'FAIL: iOS release must use per-target bundle-id indirection' >&2
  exit 1
fi
if grep -Eq '(^| )PROVISIONING_PROFILE_SPECIFIER=' "$TMP_DIR/xcodebuild.log"; then
  cat "$TMP_DIR/xcodebuild.log"
  echo 'FAIL: iOS release must use per-target profile indirection' >&2
  exit 1
fi
if grep -Eq '(^| )CODE_SIGN_ENTITLEMENTS=' "$TMP_DIR/xcodebuild.log"; then
  cat "$TMP_DIR/xcodebuild.log"
  echo 'FAIL: iOS release must use per-target entitlement indirection' >&2
  exit 1
fi
if grep -F -- 'PRODUCT_DISPLAY_NAME=' "$TMP_DIR/xcodebuild.log" >/dev/null; then
  cat "$TMP_DIR/xcodebuild.log"
  echo 'FAIL: iOS release must inherit the Supermux display name from xcconfig' >&2
  exit 1
fi
if grep -F -- 'ASSETCATALOG_COMPILER_APPICON_NAME=' "$TMP_DIR/xcodebuild.log" >/dev/null; then
  cat "$TMP_DIR/xcodebuild.log"
  echo 'FAIL: iOS release must not override the app icon for every workspace target' >&2
  exit 1
fi

grep -F -- 'devicectl device info details --device test-phone' "$TMP_DIR/xcrun.log" >/dev/null
grep -F -- 'devicectl device install app --device test-phone ' "$TMP_DIR/xcrun.log" >/dev/null
grep -F -- 'devicectl device process launch --terminate-existing --device test-phone com.supermux.ios' "$TMP_DIR/xcrun.log" >/dev/null
grep -F -- '--force --sign Apple Distribution' "$TMP_DIR/codesign.log" >/dev/null
grep -F -- 'SupermuxNotificationService.appex' "$TMP_DIR/codesign.log" >/dev/null
grep -F -- '--verify --deep --strict --verbose=2 ' "$TMP_DIR/codesign.log" >/dev/null
grep -F -- '==> Verified app + notification-extension signatures, production APNs, Time Sensitive, and Communication Notifications for team ABCD123456' "$OUTPUT_FILE" >/dev/null
grep -F -- '==> Installed Supermux (com.supermux.ios)' "$OUTPUT_FILE" >/dev/null
grep -F -- '==> Launched Supermux on iPhone' "$OUTPUT_FILE" >/dev/null

BUILD_LOGS=("$LOG_DIR"/ios-release-build-*.log)
if [[ "${#BUILD_LOGS[@]}" -ne 1 || ! -f "${BUILD_LOGS[0]}" ]]; then
  cat "$OUTPUT_FILE"
  echo 'FAIL: iOS release did not persist exactly one build log' >&2
  exit 1
fi
grep -F -- 'status=0' "${BUILD_LOGS[0]}" >/dev/null

OVERRIDE_OUTPUT_FILE="$TMP_DIR/unsupported-app-group.log"
if HOME="$HOME_DIR" \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  SUPERMUX_IOS_APP_GROUP=group.example.unsupported \
  SUPERMUX_IOS_DEVELOPMENT_TEAM=ABCD123456 \
  SUPERMUX_RELEASE_LOG_DIR="$LOG_DIR" \
  SUPERMUX_GIT_SHA=0123456789 \
  XCODEBUILD="$BIN_DIR/xcodebuild" \
  XCRUN="$BIN_DIR/xcrun" \
  CODESIGN="$BIN_DIR/codesign" \
  SECURITY="$BIN_DIR/security" \
  PLISTBUDDY="$BIN_DIR/plistbuddy" \
  FAKE_ENSURE_LOG="$TMP_DIR/override-ensure.log" \
  FAKE_XCODEBUILD_LOG="$TMP_DIR/override-xcodebuild.log" \
  FAKE_XCRUN_LOG="$TMP_DIR/override-xcrun.log" \
  FAKE_CODESIGN_LOG="$TMP_DIR/override-codesign.log" \
    bash "$TEST_REPO/scripts/supermux-ios-release.sh" --device-id test-phone \
      > "$OVERRIDE_OUTPUT_FILE" 2>&1; then
  cat "$OVERRIDE_OUTPUT_FILE"
  echo 'FAIL: unsupported app-group override unexpectedly succeeded' >&2
  exit 1
fi
grep -F -- 'SUPERMUX_IOS_APP_GROUP is fixed at group.com.supermux.ios' "$OVERRIDE_OUTPUT_FILE" >/dev/null \
  || { cat "$OVERRIDE_OUTPUT_FILE"; echo 'FAIL: unsupported app-group override did not fail with the fixed-contract error' >&2; exit 1; }
[[ ! -e "$TMP_DIR/override-xcodebuild.log" ]] \
  || { cat "$OVERRIDE_OUTPUT_FILE"; echo 'FAIL: unsupported app-group override reached xcodebuild' >&2; exit 1; }

# Run the release against the fake phone with the given scenario name and
# extra environment; returns the script's exit status.
run_release() {
  local scenario="$1"; shift
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  SUPERMUX_IOS_DEVELOPMENT_TEAM=ABCD123456 \
  SUPERMUX_RELEASE_LOG_DIR="$LOG_DIR" \
  SUPERMUX_GIT_SHA=0123456789 \
  XCODEBUILD="$BIN_DIR/xcodebuild" \
  XCRUN="$BIN_DIR/xcrun" \
  CODESIGN="$BIN_DIR/codesign" \
  SECURITY="$BIN_DIR/security" \
  PLISTBUDDY="$BIN_DIR/plistbuddy" \
  FAKE_ENSURE_LOG="$TMP_DIR/$scenario-ensure.log" \
  FAKE_XCODEBUILD_LOG="$TMP_DIR/$scenario-xcodebuild.log" \
  FAKE_XCRUN_LOG="$TMP_DIR/$scenario-xcrun.log" \
  FAKE_CODESIGN_LOG="$TMP_DIR/$scenario-codesign.log" \
  FAKE_XCRUN_STATE="$TMP_DIR/$scenario-state" \
    env "$@" bash "$TEST_REPO/scripts/supermux-ios-release.sh" --device-id test-phone \
      > "$TMP_DIR/$scenario.log" 2>&1
}

# A transient 4016 install failure must wait for the phone to answer again
# (readiness probes between the two installs) instead of sleeping a fixed
# interval, then retry once it is reachable.
TRANSIENT_ERROR='ERROR: The device is not able to fulfill the requested usage assertion requirements. (com.apple.dt.CoreDeviceError error 4016)'
mkdir -p "$TMP_DIR/transient-state"
printf '1' > "$TMP_DIR/transient-state/install-failures"
TRANSIENT_STARTED="$SECONDS"
run_release transient \
  FAKE_INSTALL_ERROR="$TRANSIENT_ERROR" FAKE_UNREACHABLE_POLLS=2 \
  SUPERMUX_IOS_INSTALL_READINESS_POLL_SECONDS=0 \
  || { cat "$TMP_DIR/transient.log"; echo 'FAIL: transient install failure was not retried' >&2; exit 1; }
TRANSIENT_ELAPSED="$((SECONDS - TRANSIENT_STARTED))"
DEVICE_CALLS="$(grep -E '^devicectl device (install app|info details) ' "$TMP_DIR/transient-xcrun.log" | sed -E 's/ --device test-phone.*//')"
EXPECTED_CALLS="$(printf '%s\n' \
  'devicectl device info details' \
  'devicectl device install app' \
  'devicectl device info details' \
  'devicectl device info details' \
  'devicectl device info details' \
  'devicectl device install app')"
[[ "$DEVICE_CALLS" == "$EXPECTED_CALLS" ]] \
  || { cat "$TMP_DIR/transient-xcrun.log"; echo 'FAIL: transient install retry did not wait on device readiness probes before retrying' >&2; exit 1; }
[[ "$TRANSIENT_ELAPSED" -lt 3 ]] \
  || { echo "FAIL: transient install retry blocked on a fixed sleep (${TRANSIENT_ELAPSED}s)" >&2; exit 1; }
grep -F -- '==> Installed Supermux (com.supermux.ios)' "$TMP_DIR/transient.log" >/dev/null \
  || { cat "$TMP_DIR/transient.log"; echo 'FAIL: transient install retry did not report the install' >&2; exit 1; }

# A permanent install failure is reported once with devicectl's own message; it
# is neither retried nor diagnosed as a reachability problem.
PERMANENT_ERROR='ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002) The application does not have a valid signature.'
mkdir -p "$TMP_DIR/permanent-state"
printf '9' > "$TMP_DIR/permanent-state/install-failures"
if run_release permanent FAKE_INSTALL_ERROR="$PERMANENT_ERROR" SUPERMUX_IOS_INSTALL_READINESS_POLL_SECONDS=0; then
  cat "$TMP_DIR/permanent.log"
  echo 'FAIL: permanent install failure unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(grep -c '^devicectl device install app ' "$TMP_DIR/permanent-xcrun.log")" -eq 1 ]] \
  || { cat "$TMP_DIR/permanent-xcrun.log"; echo 'FAIL: permanent install failure was retried' >&2; exit 1; }
grep -F -- 'error 3002' "$TMP_DIR/permanent.log" >/dev/null \
  || { cat "$TMP_DIR/permanent.log"; echo 'FAIL: permanent install failure lost the original devicectl error' >&2; exit 1; }
if grep -F -- 'error 4016' "$TMP_DIR/permanent.log" >/dev/null; then
  cat "$TMP_DIR/permanent.log"
  echo 'FAIL: permanent install failure was misreported as a reachability problem' >&2
  exit 1
fi

echo 'PASS: supermux iOS release builds the app and notification extension, re-signs both with production capabilities, installs, launches, rejects unsupported app-group overrides, retries transient installs on device readiness, and reports permanent install failures once'
