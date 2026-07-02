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

# 0. Reject malformed registry rows. Two rows glued onto one line (e.g. by a
#    merge eating a newline: '… | || 18 | `path` | …') make loop 1 below parse
#    only the first row and silently skip verifying the second one's fences.
#    Match a second row-START cell (pipes, row number, backticked path) rather
#    than a bare ' || ', which legitimately appears when a description quotes
#    code like `tabs.count > 1 || allowEmptyingWindow`.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  echo "FAIL: malformed registry row (two rows glued onto one line?): ${line:0:100}" >&2
  fail=1
done < <(sed -n '/^| [0-9]/p' "$MANIFEST" | grep -E '\| *\| *[0-9]+[a-z]* *\| *`' || true)

# 1. Every registry row's fence id must exist in its file (begin AND end).
#    Registry rows look like: | 1 | `path` | `fence-id` | description |
while IFS='|' read -r _ _ file fences _; do
  file="$(echo "$file" | tr -d ' \`')"
  [[ -z "$file" || "$file" == "File" || "$file" == *"---"* ]] && continue
  if [[ ! -e "$file" ]]; then
    echo "FAIL: registered file missing: $file" >&2
    fail=1
    continue
  fi
  # A cell may register several fence ids, comma-separated.
  fences="$(echo "$fences" | tr ',' ' ' | tr -d '\`')"
  for fence in $fences; do
    [[ -z "$fence" ]] && continue
    # Rows marked 'unfenced' (e.g. project.pbxproj, where comments are unsafe)
    # only get the file-existence check above; instructions live in the manifest.
    [[ "$fence" == "unfenced" ]] && continue
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
  done
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
