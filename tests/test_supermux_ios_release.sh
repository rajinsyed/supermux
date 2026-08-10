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
mkdir -p "$app"
printf 'binary\n' > "$app/cmux"
chmod +x "$app/cmux"
printf 'plist\n' > "$app/Info.plist"
printf 'profile\n' > "$app/embedded.mobileprovision"
mkdir -p "$app/Frameworks"
printf 'fake iOS Release build\n'
SH
chmod +x "$BIN_DIR/xcodebuild"

cat > "$BIN_DIR/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_XCRUN_LOG:?}"
case "$*" in
  'devicectl device info details --device test-phone') exit 0 ;;
  'devicectl device install app --device test-phone '*) exit 0 ;;
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
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>'
fi
SH
chmod +x "$BIN_DIR/codesign"

cat > "$BIN_DIR/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "cms" ]]; then
  cat <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>Name</key><string>Supermux iPhone Ad Hoc</string>
<key>Entitlements</key><dict>
<key>aps-environment</key><string>production</string>
<key>application-identifier</key><string>ABCD123456.com.supermux.ios</string>
<key>com.apple.developer.team-identifier</key><string>ABCD123456</string>
</dict>
</dict></plist>
PLIST
  exit 0
fi
echo "unexpected security invocation: $*" >&2
exit 2
SH
chmod +x "$BIN_DIR/security"

cat > "$BIN_DIR/plistbuddy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-x" ]]; then shift; fi
command="${2:-}"
case "$command" in
  'Print :CFBundleIdentifier') printf 'com.supermux.ios\n' ;;
  'Print :CFBundleDisplayName') printf 'Supermux\n' ;;
  'Print :CMUXDevTag') printf '\n' ;;
  'Print :CMUXAuthEnvironment') printf 'production\n' ;;
  'Print :TeamIdentifier:0') printf 'ABCD123456\n' ;;
  'Print :Entitlements:application-identifier') printf 'ABCD123456.com.supermux.ios\n' ;;
  'Print :Entitlements:aps-environment') printf 'production\n' ;;
  'Print :com.apple.developer.team-identifier') printf 'ABCD123456\n' ;;
  'Print :application-identifier') printf 'ABCD123456.com.supermux.ios\n' ;;
  'Print :aps-environment') printf 'production\n' ;;
  'Print :Name') printf 'Supermux iPhone Ad Hoc\n' ;;
  'Print :Entitlements')
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>' ;;
  *) echo "unexpected PlistBuddy command: $command" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN_DIR/plistbuddy"

DERIVED_DATA="$HOME_DIR/Library/Developer/Xcode/DerivedData/cmux-ios-supermux-release"
STALE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/cmux.app"
STALE_PCM="$DERIVED_DATA/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/stale.pcm"
mkdir -p "$STALE_APP" "$(dirname "$STALE_PCM")"
PROFILES_DIR="$HOME_DIR/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
printf 'fake adhoc profile\n' > "$PROFILES_DIR/fake-adhoc.mobileprovision"
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
grep -F -- 'PRODUCT_BUNDLE_IDENTIFIER=com.supermux.ios' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_DEV_TAG=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_PRESENCE_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_API_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_IROH_BROKER_BASE_URL=' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CMUX_IOS_AUTH_ENV=production' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'DEVELOPMENT_TEAM=ABCD123456' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'CODE_SIGN_STYLE=Manual' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- 'PROVISIONING_PROFILE_SPECIFIER=Supermux iPhone Development' "$TMP_DIR/xcodebuild.log" >/dev/null
grep -F -- '--force --sign Apple Distribution' "$TMP_DIR/codesign.log" >/dev/null
grep -F -- 'CODE_SIGN_ENTITLEMENTS=Config/supermux.entitlements' "$TMP_DIR/xcodebuild.log" >/dev/null
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
grep -F -- '--verify --strict --verbose=2 ' "$TMP_DIR/codesign.log" >/dev/null
grep -F -- '==> Verified iOS signature and production APNs entitlement for team ABCD123456' "$OUTPUT_FILE" >/dev/null
grep -F -- '==> Installed Supermux (com.supermux.ios)' "$OUTPUT_FILE" >/dev/null
grep -F -- '==> Launched Supermux on iPhone' "$OUTPUT_FILE" >/dev/null

BUILD_LOGS=("$LOG_DIR"/ios-release-build-*.log)
if [[ "${#BUILD_LOGS[@]}" -ne 1 || ! -f "${BUILD_LOGS[0]}" ]]; then
  cat "$OUTPUT_FILE"
  echo 'FAIL: iOS release did not persist exactly one build log' >&2
  exit 1
fi
grep -F -- 'status=0' "${BUILD_LOGS[0]}" >/dev/null

echo 'PASS: supermux iOS release is untagged, production-auth, fixed-identity, team-signed, verified, installed, and launched'
