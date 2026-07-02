#!/usr/bin/env bash
#
# supermux-release.sh — build a Release "Supermux" app, sign it with your
# Developer ID, and install it to /Applications so it runs like a normal,
# double-clickable app.
#
# Edits NO upstream files: the build is produced UNSIGNED with cmux's native
# bundle ids, then the COPIED bundle is rebranded (Info.plist patches) and
# re-signed inside-out with your Developer ID Application certificate.
#
# Why native ids + post-build patch (not a build-time bundle-id override):
# forcing PRODUCT_BUNDLE_IDENTIFIER applies to every target, which would make
# the embedded Dock Tile plugin collide with the host id. Building native keeps
# the embedded ids validly prefixed; we then rename the copy.
#
# Why a distinct identity: the real cmux (com.cmuxterm.app) is also installed.
# Supermux ships as "Supermux" (com.supermux.app) with its own sidebar
# extension-point id and isolated runtime sockets so the two never collide.
# Sparkle auto-update is disabled so the fork doesn't update itself back to
# upstream cmux — rerun this script after pulling updates instead.
#
# Usage:
#   ./scripts/supermux-release.sh                # build, install, launch
#   ./scripts/supermux-release.sh --no-launch
#   SUPERMUX_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./scripts/supermux-release.sh
#
set -euo pipefail

APP_NAME="Supermux"
BUNDLE_ID="com.supermux.app"
DOCKTILE_BUNDLE_ID="${BUNDLE_ID}.docktileplugin"
SIDEBAR_EXTENSION_POINT_ID="${BUNDLE_ID}.cmux.sidebar"
BASE_APP_NAME="cmux"          # PRODUCT_NAME stays "cmux"; we rename the bundle on copy.
INSTALL_APP="/Applications/${APP_NAME}.app"
DERIVED_DATA="${HOME}/Library/Developer/Xcode/DerivedData/cmux-supermux-release"
SIGN_IDENTITY="${SUPERMUX_SIGN_IDENTITY:-Developer ID Application: Syed Ramijuzzaman Rajin (NRGUG8GVV4)}"
LAUNCH=1

# Isolated runtime sockets so Supermux never fights an installed/running cmux.
APP_SUPPORT_DIR="${HOME}/Library/Application Support/cmux"
CMUXD_SOCKET="${APP_SUPPORT_DIR}/cmuxd-supermux.sock"
CMUX_SOCKET_PATH_VALUE="/tmp/supermux.sock"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"
APP_ENT="${REPO_ROOT}/supermux.release.entitlements"
HELPER_ENT="${REPO_ROOT}/cmux-helper.entitlements"

if ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
  echo "error: signing identity not found in keychain: ${SIGN_IDENTITY}" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

echo "==> Building Release (unsigned, native ids)"
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CMUX_SIDEBAR_EXTENSION_POINT_ID="${SIDEBAR_EXTENSION_POINT_ID}" \
  build

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${BASE_APP_NAME}.app"
[[ -d "${BUILT_APP}" ]] || { echo "error: built app not found at ${BUILT_APP}" >&2; exit 1; }

if [[ -d "${REPO_ROOT}/cmuxd" ]]; then
  echo "==> Building cmuxd (ReleaseFast)"
  (cd "${REPO_ROOT}/cmuxd" && zig build -Doptimize=ReleaseFast)
fi

# Patch, sign, and verify a STAGED copy first; /Applications is only touched
# after the staged bundle fully verifies. A codesign failure (e.g. a transient
# timestamp-server error) must never leave an unsigned app installed — an
# unsigned app can't hold TCC grants, so macOS re-prompts for Documents/Desktop
# access on every launch and Allow never sticks.
echo "==> Staging bundle"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supermux-release.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGED_APP="${STAGE_DIR}/${APP_NAME}.app"
cp -R "${BUILT_APP}" "${STAGED_APP}"

INFO_PLIST="${STAGED_APP}/Contents/Info.plist"
plist_set() {
  local key="$1" type="$2" value="$3" plist="${4:-$INFO_PLIST}"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "${plist}"
}

# Rebrand the host bundle.
plist_set "CFBundleIdentifier" string "${BUNDLE_ID}"
plist_set "CFBundleName" string "${APP_NAME}"
plist_set "CFBundleDisplayName" string "${APP_NAME}"
# Stop the fork from auto-updating itself back to upstream cmux.
plist_set "SUEnableAutomaticChecks" bool false
# Isolated sockets via LSEnvironment. CMUX_ALLOW_SOCKET_OVERRIDE is REQUIRED:
# without it a non-debug/non-staging release id ignores CMUX_SOCKET_PATH and
# falls back to the shared stable socket (SocketControlSettings.swift).
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "${INFO_PLIST}" 2>/dev/null || true
plist_set "LSEnvironment:CMUX_BUNDLE_ID" string "${BUNDLE_ID}"
plist_set "LSEnvironment:CMUXD_UNIX_PATH" string "${CMUXD_SOCKET}"
plist_set "LSEnvironment:CMUX_SOCKET_PATH" string "${CMUX_SOCKET_PATH_VALUE}"
plist_set "LSEnvironment:CMUX_ALLOW_SOCKET_OVERRIDE" string "1"

# Keep the embedded Dock Tile plugin's id prefixed by the (new) host id; its
# filename stays CmuxDockTilePlugin.plugin (NSDockTilePlugIn is filename-based).
DOCKTILE_PLIST="${STAGED_APP}/Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/Info.plist"
[[ -f "${DOCKTILE_PLIST}" ]] && plist_set "CFBundleIdentifier" string "${DOCKTILE_BUNDLE_ID}" "${DOCKTILE_PLIST}"

# Bundle the freshly built daemon.
CMUXD_SRC="${REPO_ROOT}/cmuxd/zig-out/bin/cmuxd"
if [[ -x "${CMUXD_SRC}" ]]; then
  BIN_DIR="${STAGED_APP}/Contents/Resources/bin"
  mkdir -p "${BIN_DIR}"
  cp "${CMUXD_SRC}" "${BIN_DIR}/cmuxd"
  chmod +x "${BIN_DIR}/cmuxd"
fi

# Drop Sparkle's sandboxed XPC services before signing (matches release tooling).
[[ -x "${REPO_ROOT}/scripts/remove-sparkle-sandbox-xpc-services.sh" ]] \
  && "${REPO_ROOT}/scripts/remove-sparkle-sandbox-xpc-services.sh" "${STAGED_APP}" || true

echo "==> Signing with: ${SIGN_IDENTITY}"
# Retry each codesign a few times: the --timestamp flag needs Apple's timestamp
# server, and a transient network failure there is exactly what stranded a
# half-signed install once.
sign_one() {
  local attempt
  for attempt in 1 2 3; do
    if codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "$@"; then
      return 0
    fi
    echo "warn: codesign failed (attempt ${attempt}/3): $*" >&2
    sleep 2
  done
  echo "error: codesign failed after 3 attempts: $*" >&2
  return 1
}

# Inside-out: frameworks (deep handles their own nested code, e.g. Sparkle's
# Updater.app), loose dylibs, the dock plugin, the Mach-O helpers (with helper
# entitlements), then the host app LAST with the app entitlements. The final
# app sign is NOT --deep, so it cannot clobber the nested signatures above.
for fw in "${STAGED_APP}"/Contents/Frameworks/*.framework; do
  [[ -d "${fw}" ]] && sign_one --deep "${fw}"
done
for dy in "${STAGED_APP}"/Contents/Frameworks/*.dylib; do
  [[ -f "${dy}" ]] && sign_one "${dy}"
done
for pl in "${STAGED_APP}"/Contents/PlugIns/*.plugin; do
  [[ -d "${pl}" ]] && sign_one "${pl}"
done
for h in cmux ghostty cmuxd; do
  f="${STAGED_APP}/Contents/Resources/bin/${h}"
  [[ -f "${f}" ]] && file -b "${f}" | grep -q "Mach-O" \
    && sign_one --entitlements "${HELPER_ENT}" "${f}"
done
sign_one --entitlements "${APP_ENT}" "${STAGED_APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}" || {
  echo "error: signature verification failed" >&2; exit 1; }

echo "==> Installing to ${INSTALL_APP}"
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
pkill -f "${INSTALL_APP}/Contents/MacOS/${BASE_APP_NAME}" 2>/dev/null || true
sleep 0.3
rm -rf "${INSTALL_APP}"
mv "${STAGED_APP}" "${INSTALL_APP}"

# Informational: a non-notarized Developer ID app is 'rejected' by spctl but
# still runs locally (it is not quarantined). Notarize later to clear this.
spctl -a -vv --type execute "${INSTALL_APP}" 2>&1 | sed 's/^/    spctl: /' || true

# Clear any stale isolated sockets from a previous run.
if [[ -S "${CMUXD_SOCKET}" ]]; then
  for PID in $(lsof -t "${CMUXD_SOCKET}" 2>/dev/null); do kill "${PID}" 2>/dev/null || true; done
  rm -f "${CMUXD_SOCKET}"
fi
[[ -S "${CMUX_SOCKET_PATH_VALUE}" ]] && rm -f "${CMUX_SOCKET_PATH_VALUE}"

echo "==> Installed: ${INSTALL_APP}"

if [[ "${LAUNCH}" -eq 1 ]]; then
  env \
    -u CMUX_SOCKET_PATH -u CMUX_TAB_ID -u CMUX_PANEL_ID -u CMUXD_UNIX_PATH \
    -u CMUX_TAG -u CMUX_BUNDLE_ID -u CMUX_SHELL_INTEGRATION \
    -u GHOSTTY_BIN_DIR -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_SHELL_FEATURES \
    CMUX_BUNDLE_ID="${BUNDLE_ID}" \
    CMUX_ALLOW_SOCKET_OVERRIDE="1" \
    CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH_VALUE}" \
    CMUXD_UNIX_PATH="${CMUXD_SOCKET}" \
    open "${INSTALL_APP}"
  echo "==> Launched ${APP_NAME}"
fi
