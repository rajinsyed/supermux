#!/usr/bin/env bash
#
# supermux-seed-dev-profile.sh — copy the main Supermux release install's
# signed-in profile into a tagged dev build's isolated identity, so a dogfood
# build launches already signed in to the same production Stack account with
# the same settings.
#
# What it copies (source: the com.supermux.app release install):
#   1. The full UserDefaults domain (settings, cmux.auth.cachedUser,
#      cmux.auth.hasTokens, cmux.auth.selectedTeamID, ...), imported into the
#      tag's domain. cmux.auth.stackProjectID is then force-written to the
#      production project id so MacAuthComposition.detectAuthProjectSwitch
#      does not clear the seeded session on the tag's first production-auth
#      launch.
#   2. ~/Library/Application Support/cmux/com.supermux.app/credentials.json
#      (the Stack Auth file token store — the release build uses the file
#      fallback because its Developer ID signature has no keychain
#      entitlement), copied 0600-atomic into the tag's directory. Tagged Debug
#      builds are ad-hoc signed, so they use the same file fallback and pick
#      this up directly.
#
# Why sharing the token file is safe: the Stack Auth backend does not rotate
# refresh tokens (alwaysIssueNewRefreshToken: false), so two apps can mint
# access tokens off one session concurrently. The ONE shared hazard is
# sign-out: revoking the session from EITHER app signs out BOTH. Never sign
# out inside a seeded dogfood build.
#
# Usage:
#   supermux-seed-dev-profile.sh --target-bundle-id com.cmuxterm.app.debug.<tag> \
#     [--source-bundle-id com.supermux.app] [--wait-for-exit <executable-path>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

SOURCE_BUNDLE_ID="com.supermux.app"
TARGET_BUNDLE_ID=""
WAIT_FOR_EXIT_PATH=""

die() {
  echo "supermux-seed-dev-profile: error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-bundle-id)
      TARGET_BUNDLE_ID="${2:-}"
      [[ -n "$TARGET_BUNDLE_ID" ]] || die "--target-bundle-id requires a value"
      shift 2
      ;;
    --source-bundle-id)
      SOURCE_BUNDLE_ID="${2:-}"
      [[ -n "$SOURCE_BUNDLE_ID" ]] || die "--source-bundle-id requires a value"
      shift 2
      ;;
    --wait-for-exit)
      WAIT_FOR_EXIT_PATH="${2:-}"
      [[ -n "$WAIT_FOR_EXIT_PATH" ]] || die "--wait-for-exit requires a value"
      shift 2
      ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "unknown option $1"
      ;;
  esac
done

[[ -n "$TARGET_BUNDLE_ID" ]] || die "--target-bundle-id is required"
[[ "$TARGET_BUNDLE_ID" != "$SOURCE_BUNDLE_ID" ]] \
  || die "target bundle id equals source bundle id ($SOURCE_BUNDLE_ID)"

# The production Stack project id, kept in sync with productionStackProjectID
# in Sources/Auth/AuthEnvironment.swift (grepped so the two can't drift; the
# literal is the last-resort fallback).
PRODUCTION_STACK_PROJECT_ID="$(sed -n \
  's/.*productionStackProjectID = "\([^"]*\)".*/\1/p' \
  "$REPO_ROOT/Sources/Auth/AuthEnvironment.swift" 2>/dev/null | head -1)"
PRODUCTION_STACK_PROJECT_ID="${PRODUCTION_STACK_PROJECT_ID:-9790718f-14cd-4f7e-824d-eaf527a82b82}"

APP_SUPPORT_CMUX="$HOME/Library/Application Support/cmux"
SRC_CRED="$APP_SUPPORT_CMUX/$SOURCE_BUNDLE_ID/credentials.json"
DST_DIR="$APP_SUPPORT_CMUX/$TARGET_BUNDLE_ID"
DST_CRED="$DST_DIR/credentials.json"

# Wait for the previous same-tag app instance to actually exit before seeding,
# otherwise its shutdown could rewrite the seeded credentials file. reload.sh
# already asked it to quit; this only bounds the race. The pattern is also in
# this script's own argv, so filter out our own PID and parent to be safe
# against a pgrep -f self-match.
matching_app_pids() {
  pgrep -f "$WAIT_FOR_EXIT_PATH" 2>/dev/null | grep -vx -e "$$" -e "$PPID" || true
}
if [[ -n "$WAIT_FOR_EXIT_PATH" ]]; then
  for _ in $(seq 1 50); do
    [[ -n "$(matching_app_pids)" ]] || break
    sleep 0.1
  done
  if [[ -n "$(matching_app_pids)" ]]; then
    die "previous tagged app is still running ($WAIT_FOR_EXIT_PATH); not seeding over a live process"
  fi
fi

# --- Validate the source credentials file -----------------------------------
[[ -f "$SRC_CRED" && ! -L "$SRC_CRED" ]] \
  || die "no credentials file at $SRC_CRED — is the main Supermux app installed and signed in?"
src_uid="$(stat -f %u "$SRC_CRED")"
[[ "$src_uid" == "$(id -u)" ]] || die "$SRC_CRED is not owned by the current user"
python3 - "$SRC_CRED" <<'PY' || die "credentials file is invalid or has no refresh token — sign in to the main Supermux app first"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    body = json.load(handle)
refresh = body.get("refreshToken")
if not isinstance(refresh, str) or not refresh.strip():
    raise SystemExit(1)
PY

# --- Seed UserDefaults ------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/supermux-seed-profile.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
DEFAULTS_PLIST="$TMP_DIR/source-defaults.plist"
defaults export "$SOURCE_BUNDLE_ID" "$DEFAULTS_PLIST" \
  || die "could not export defaults for $SOURCE_BUNDLE_ID — has the main Supermux app ever launched?"
defaults import "$TARGET_BUNDLE_ID" "$DEFAULTS_PLIST" \
  || die "could not import defaults into $TARGET_BUNDLE_ID"
# Pin the auth project so detectAuthProjectSwitch sees production == production
# on the seeded build's first launch and keeps the copied tokens.
defaults write "$TARGET_BUNDLE_ID" cmux.auth.stackProjectID -string "$PRODUCTION_STACK_PROJECT_ID"
defaults write "$TARGET_BUNDLE_ID" cmux.auth.hasTokens -bool true

# --- Seed the credentials file (0600 file, atomic rename, 0700 dir) ---------
umask 077
mkdir -p "$DST_DIR"
chmod 700 "$DST_DIR"
TMP_CRED="$DST_DIR/.credentials.json.seed-$$"
cp "$SRC_CRED" "$TMP_CRED"
chmod 600 "$TMP_CRED"
mv -f "$TMP_CRED" "$DST_CRED"

echo "==> seeded $TARGET_BUNDLE_ID from $SOURCE_BUNDLE_ID (settings + production sign-in)"
echo "==> WARNING: this build shares the main Supermux app's login session."
echo "    Do NOT sign out inside the dogfood build — it would sign out the main app too."
