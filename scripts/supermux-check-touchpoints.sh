#!/usr/bin/env bash
# Verify SUPERMUX-TOUCHPOINTS.md and the SUPERMUX fences in the tree agree.
# Run after every upstream merge. Exits non-zero on any drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$REPO_ROOT/SUPERMUX-TOUCHPOINTS.md"

cd "$REPO_ROOT"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: SUPERMUX-TOUCHPOINTS.md missing" >&2
  exit 1
fi

fail=0

# 1. Every registry row's fence id must exist in its file (begin AND end).
#    Registry rows look like: | 1 | `path` | `fence-id` | description |
while IFS='|' read -r _ _ file fence _; do
  file="$(echo "$file" | tr -d ' \`')"
  fence="$(echo "$fence" | tr -d ' \`')"
  [[ -z "$file" || -z "$fence" || "$file" == "File" || "$file" == *"---"* ]] && continue
  # Rows marked `unfenced` (e.g. project.pbxproj, where comments are unsafe)
  # only check file existence; re-apply instructions live in the manifest.
  if [[ "$fence" == "unfenced" ]]; then
    if [[ ! -e "$file" ]]; then
      echo "FAIL: registered file missing: $file (unfenced)" >&2
      fail=1
    fi
    continue
  fi
  if [[ ! -e "$file" ]]; then
    echo "FAIL: registered file missing: $file (fence: $fence)" >&2
    fail=1
    continue
  fi
  # A trailing '*' registers a family of fences sharing the prefix; the file
  # must contain at least one begin/end pair with that prefix.
  if [[ "$fence" == *'*' ]]; then
    prefix="${fence%\*}"
    if ! grep -q "SUPERMUX:begin $prefix" "$file"; then
      echo "FAIL: $file has no fence matching 'SUPERMUX:begin $prefix*' (clobbered by a merge?)" >&2
      fail=1
    fi
    if ! grep -q "SUPERMUX:end $prefix" "$file"; then
      echo "FAIL: $file has no fence matching 'SUPERMUX:end $prefix*'" >&2
      fail=1
    fi
    continue
  fi
  if ! grep -q "SUPERMUX:begin $fence" "$file"; then
    echo "FAIL: $file is missing fence 'SUPERMUX:begin $fence' (clobbered by a merge?)" >&2
    fail=1
  fi
  if ! grep -q "SUPERMUX:end $fence" "$file"; then
    echo "FAIL: $file is missing fence 'SUPERMUX:end $fence'" >&2
    fail=1
  fi
done < <(sed -n '/^| [0-9]/p' "$MANIFEST")

# 2. Every SUPERMUX fence in the tree must be registered in the manifest.
#    (Scan tracked files only; skip supermux-owned dirs where fences are unnecessary.)
while IFS=: read -r file _; do
  case "$file" in
    SUPERMUX*.md|Packages/SupermuxKit/*|Sources/Supermux/*|scripts/supermux-*) continue ;;
  esac
  while read -r fence; do
    registered=0
    if grep -q "\`$fence\`" "$MANIFEST"; then
      registered=1
    else
      # Accept membership in a registered wildcard family (`prefix-*`).
      while read -r wildcard; do
        prefix="${wildcard%\*}"
        if [[ "$fence" == "$prefix"* ]]; then
          registered=1
          break
        fi
      done < <(grep -o '`[a-zA-Z0-9_-]*\*`' "$MANIFEST" | tr -d '\`')
    fi
    if [[ $registered -eq 0 ]]; then
      echo "FAIL: $file has unregistered fence '$fence' — add it to SUPERMUX-TOUCHPOINTS.md" >&2
      fail=1
    fi
  done < <(grep -o 'SUPERMUX:begin [a-zA-Z0-9_-]*' "$file" | awk '{print $2}' | sort -u)
done < <(git grep -l 'SUPERMUX:begin' -- ':!SUPERMUX*.md' ':!Packages/SupermuxKit' ':!Sources/Supermux' ':!scripts/supermux-*' 2>/dev/null | sed 's/$/:/')

# 3. The pbxproj is unfenced (comments are unsafe there), so verify the count of
#    supermux-reserved IDs matches the manifest's stated expectation — this is
#    the only automatable drift check for that file. The manifest carries the
#    expected count on a line: `grep -c 50BE0001 ... should print `N``.
pbxproj="cmux.xcodeproj/project.pbxproj"
if [[ -f "$pbxproj" ]]; then
  expected="$(grep -oE 'grep -c 50BE0001[^`]*` should print `[0-9]+`' "$MANIFEST" | grep -oE 'print `[0-9]+`' | grep -oE '[0-9]+' | head -1)"
  actual="$(grep -c 50BE0001 "$pbxproj" || true)"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "FAIL: $pbxproj has $actual supermux IDs (50BE0001…); manifest expects $expected — a pbxproj entry was clobbered or added without updating SUPERMUX-TOUCHPOINTS.md" >&2
    fail=1
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Touchpoint check FAILED. See SUPERMUX-TOUCHPOINTS.md 'How to re-apply' section." >&2
  exit 1
fi

echo "OK: all supermux touchpoints present and registered."
