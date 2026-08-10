#!/usr/bin/env bash
#
# supermux-ios-release.sh — build the fixed-identity Supermux iOS Release app,
# sign it for direct installation with the owner's Apple development team, and
# install it on a physical iPhone.
#
# This is the main local production build, not tagged dogfood:
#   - Release configuration (official Mac compatibility policy)
#   - fixed bundle id com.supermux.ios (preserves app data across releases)
#   - empty CMUXDevTag and production auth/API settings
#   - automatic device signing under SUPERMUX_IOS_DEVELOPMENT_TEAM
#
# Personal-team direct installs cannot use the App Store app's production push
# capabilities, so this intentionally signs with Config/cmux.entitlements. It
# still runs the production Release code path and production authentication.
#
# Usage:
#   ./scripts/supermux-ios-release.sh
#   ./scripts/supermux-ios-release.sh --no-launch
#   ./scripts/supermux-ios-release.sh --device-id <coredevice-id>
#
set -euo pipefail

APP_NAME="Supermux"
BUNDLE_ID="com.supermux.ios"
BASE_APP_NAME="cmux"
DEVELOPMENT_TEAM="${SUPERMUX_IOS_DEVELOPMENT_TEAM:-NRGUG8GVV4}"
DERIVED_DATA="${SUPERMUX_IOS_DERIVED_DATA:-${HOME}/Library/Developer/Xcode/DerivedData/cmux-ios-supermux-release}"
LAUNCH=1
DEVICE_ID="${SUPERMUX_IOS_DEVICE_ID:-${CMUX_IPHONE_DEVICE_ID:-}}"

XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCRUN="${XCRUN:-xcrun}"
CODESIGN="${CODESIGN:-codesign}"
SECURITY="${SECURITY:-security}"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --device-id)
      [[ -n "${2:-}" && "${2:-}" != --* ]] || die "--device-id requires a value"
      DEVICE_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option $1"
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IOS_DIR="${REPO_ROOT}/ios"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release-iphoneos/${BASE_APP_NAME}.app"
EXPLICIT_MODULE_CACHE="${DERIVED_DATA}/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
BUILD_LOG_DIR="${SUPERMUX_RELEASE_LOG_DIR:-${HOME}/Library/Logs/Supermux}"
mkdir -p "${BUILD_LOG_DIR}"
BUILD_LOG="${BUILD_LOG_DIR}/ios-release-build-$(date +%Y%m%d-%H%M%S)-$$.log"
BUILD_HEAD="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
BUILD_SHA="${SUPERMUX_GIT_SHA:-$(git -C "${REPO_ROOT}" rev-parse --short=10 HEAD 2>/dev/null || printf 'unknown')}"

resolve_device_id() {
  if [[ -n "${DEVICE_ID}" ]]; then
    printf '%s\n' "${DEVICE_ID}"
    return
  fi

  local config_file="${CMUX_CONFIG_DIR:-${HOME}/.config/cmux}/iphone-device-id"
  if [[ -f "${config_file}" ]]; then
    local configured_id
    configured_id="$(tr -d '[:space:]' < "${config_file}")"
    if [[ -n "${configured_id}" ]]; then
      printf '%s\n' "${configured_id}"
      return
    fi
  fi

  local devices_json
  devices_json="$(mktemp "${TMPDIR:-/tmp}/supermux-ios-devices.XXXXXX")"
  if ! "${XCRUN}" devicectl list devices --json-output "${devices_json}" >/dev/null; then
    rm -f "${devices_json}"
    die "could not list connected iPhones"
  fi

  local detected_id
  if ! detected_id="$(python3 - "${devices_json}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)

devices = body.get("result", {}).get("devices", [])
candidates = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if (
        hardware.get("deviceType") == "iPhone"
        and hardware.get("reality") == "physical"
        and properties.get("bootState") == "booted"
        and connection.get("tunnelState") == "connected"
    ):
        candidates.append(device)

if len(candidates) != 1:
    print(
        "error: expected exactly one connected physical iPhone; "
        "pass --device-id, set CMUX_IPHONE_DEVICE_ID, or write "
        "~/.config/cmux/iphone-device-id",
        file=sys.stderr,
    )
    for device in candidates:
        name = device.get("deviceProperties", {}).get("name", "iPhone")
        identifier = device.get("identifier", "<unknown>")
        print(f"  {name}: {identifier}", file=sys.stderr)
    raise SystemExit(1)

print(candidates[0]["identifier"])
PY
  )"; then
    rm -f "${devices_json}"
    exit 1
  fi
  rm -f "${devices_json}"
  printf '%s\n' "${detected_id}"
}

DEVICE_ID="$(resolve_device_id)"
if ! "${XCRUN}" devicectl device info details --device "${DEVICE_ID}" >/dev/null; then
  die "iPhone ${DEVICE_ID} is not reachable"
fi

cd "${REPO_ROOT}"

echo "==> Ensuring GhosttyKit matches the current submodule"
"${REPO_ROOT}/scripts/ensure-ghosttykit.sh"

echo "==> Building iOS production Release for ${APP_NAME}"
echo "    Bundle: ${BUNDLE_ID}"
echo "    Team:   ${DEVELOPMENT_TEAM}"
echo "    Device: ${DEVICE_ID}"
echo "    HEAD:   ${BUILD_HEAD}"
echo "    Log:    ${BUILD_LOG}"
{
  printf 'HEAD=%s\n' "${BUILD_HEAD}"
  printf 'Started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "${XCODEBUILD}" -version
} > "${BUILD_LOG}"

# External xcframework headers can change without invalidating Xcode's explicit
# module cache. A previous product must also never satisfy post-build checks.
rm -rf "${EXPLICIT_MODULE_CACHE}" "${BUILT_APP}"

set +e
NSUnbufferedIO=YES "${XCODEBUILD}" \
  -workspace "${IOS_DIR}/cmux.xcworkspace" \
  -scheme cmux-ios \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  CMUX_GIT_SHA="${BUILD_SHA}" \
  CMUX_DEV_TAG= \
  CMUX_PRESENCE_BASE_URL= \
  CMUX_API_BASE_URL= \
  CMUX_IROH_BROKER_BASE_URL= \
  CMUX_IOS_AUTH_ENV=production \
  EXCLUDED_SOURCE_FILE_NAMES=Info.plist \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_ENTITLEMENTS=Config/cmux.entitlements \
  build 2>&1 | tee -a "${BUILD_LOG}"
pipeline_status=("${PIPESTATUS[@]}")
build_status=${pipeline_status[0]}
tee_status=${pipeline_status[1]}
set -e
printf 'Finished=%s status=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${build_status}" | tee -a "${BUILD_LOG}"
if [[ "${build_status}" -ne 0 ]]; then
  exit "${build_status}"
fi
if [[ "${tee_status}" -ne 0 ]]; then
  die "failed to write iOS Release build log: ${BUILD_LOG}"
fi

INFO_PLIST="${BUILT_APP}/Info.plist"
APP_EXECUTABLE="${BUILT_APP}/${BASE_APP_NAME}"
[[ -x "${APP_EXECUTABLE}" ]] || die "newly built iOS app executable not found at ${BUILT_APP}"
[[ -f "${INFO_PLIST}" ]] || die "newly built iOS app Info.plist not found at ${BUILT_APP}"

plist_value() {
  "${PLISTBUDDY}" -c "Print :$1" "$2" 2>/dev/null || true
}

actual_bundle_id="$(plist_value CFBundleIdentifier "${INFO_PLIST}")"
actual_display_name="$(plist_value CFBundleDisplayName "${INFO_PLIST}")"
actual_dev_tag="$(plist_value CMUXDevTag "${INFO_PLIST}")"
actual_auth_environment="$(plist_value CMUXAuthEnvironment "${INFO_PLIST}")"

[[ "${actual_bundle_id}" == "${BUNDLE_ID}" ]] \
  || die "built iOS bundle id is '${actual_bundle_id:-<absent>}', expected ${BUNDLE_ID}"
[[ "${actual_display_name}" == "${APP_NAME}" ]] \
  || die "built iOS display name is '${actual_display_name:-<absent>}', expected ${APP_NAME}"
[[ -z "${actual_dev_tag}" ]] \
  || die "built iOS app carries dogfood tag '${actual_dev_tag}'"
[[ "${actual_auth_environment}" == "production" ]] \
  || die "built iOS auth environment is '${actual_auth_environment:-<absent>}', expected production"

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supermux-ios-verify.XXXXXX")"
trap 'rm -rf "${VERIFY_DIR}"' EXIT
PROFILE_PLIST="${VERIFY_DIR}/profile.plist"
SIGNED_ENTITLEMENTS="${VERIFY_DIR}/signed-entitlements.plist"

"${CODESIGN}" --verify --strict --verbose=2 "${BUILT_APP}"
"${SECURITY}" cms -D -i "${BUILT_APP}/embedded.mobileprovision" > "${PROFILE_PLIST}"
"${CODESIGN}" -d --entitlements :- --xml "${BUILT_APP}" > "${SIGNED_ENTITLEMENTS}" 2>/dev/null

expected_application_id="${DEVELOPMENT_TEAM}.${BUNDLE_ID}"
profile_team="$(plist_value TeamIdentifier:0 "${PROFILE_PLIST}")"
profile_application_id="$(plist_value Entitlements:application-identifier "${PROFILE_PLIST}")"
signed_team="$(plist_value com.apple.developer.team-identifier "${SIGNED_ENTITLEMENTS}")"
signed_application_id="$(plist_value application-identifier "${SIGNED_ENTITLEMENTS}")"

[[ "${profile_team}" == "${DEVELOPMENT_TEAM}" ]] \
  || die "provisioning profile team is '${profile_team:-<absent>}', expected ${DEVELOPMENT_TEAM}"
[[ "${profile_application_id}" == "${expected_application_id}" ]] \
  || die "provisioning profile app id is '${profile_application_id:-<absent>}', expected ${expected_application_id}"
[[ "${signed_team}" == "${DEVELOPMENT_TEAM}" ]] \
  || die "signed app team is '${signed_team:-<absent>}', expected ${DEVELOPMENT_TEAM}"
[[ "${signed_application_id}" == "${expected_application_id}" ]] \
  || die "signed app id is '${signed_application_id:-<absent>}', expected ${expected_application_id}"

echo "==> Verified iOS signature for team ${DEVELOPMENT_TEAM}"
echo "==> Installing ${APP_NAME} on iPhone ${DEVICE_ID}"
"${XCRUN}" devicectl device install app --device "${DEVICE_ID}" "${BUILT_APP}"
echo "==> Installed ${APP_NAME} (${BUNDLE_ID})"

if [[ "${LAUNCH}" -eq 1 ]]; then
  if "${XCRUN}" devicectl device process launch --terminate-existing \
      --device "${DEVICE_ID}" "${BUNDLE_ID}" >/dev/null 2>&1; then
    echo "==> Launched ${APP_NAME} on iPhone"
  else
    echo "warning: installed ${APP_NAME}, but the iPhone could not launch it (device locked? tap the app to open)" >&2
  fi
fi
