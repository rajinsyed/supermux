#!/usr/bin/env bash
# supermux: prune dev-build macOS registrations (and optionally DerivedData).
#
# THE PROBLEM
#   Every `./scripts/reload.sh --tag <tag>` build leaves app bundles on disk:
#     - cmux DEV <tag>.app   (the real tagged build you run)
#     - cmux DEV.app         (a redundant leftover: reload.sh copies this base
#                             bundle to make the tagged one, then never uses it)
#     - .cmux DEV <tag>.reload-<pid>.app  (staging copies from crashed reloads)
#   Each bundle ships a sidebar ExtensionKit app-extension (-> "Allow in the
#   Background" list) and a Dock Tile plugin (-> "Added Extensions" list), so
#   macOS registers every one of them. cmux's cleanup-dev-builds.sh deletes
#   DerivedData but never deregisters, so System Settings > General > Login
#   Items & Extensions fills up with stale "cmux DEV" rows forever.
#
# WHAT THIS DOES
#   - Deregisters stale "cmux DEV" bundles from LaunchServices (lsregister -u).
#   - Removes the redundant base "cmux DEV.app" + ".reload-*.app" staging copies
#     (always safe: they are never the app you run).
#   - With --prune-derived, also deletes DerivedData + sockets/logs for prunable
#     tags by delegating the disk sweep to cleanup-dev-builds.sh.
#   - With --rebuild-lsdb, rebuilds the LaunchServices database afterwards so
#     entries whose bundles were already deleted also drop out.
#
# SAFETY (always on)
#   Never deregisters or deletes the *tagged* app for the active tag
#   (/tmp/cmux-last-cli-path) or a running "cmux DEV <tag>". Use --keep <tag>
#   to protect more. Redundant base/staging bundles are pruned regardless,
#   since they are never launched.
#
# Defaults to dry-run. Pass --apply to act.
#
# Options:
#   --apply                 Deregister + remove (default is preview only).
#   --prune-derived         Also delete DerivedData + sockets/logs for prunable
#                           tags (runs cleanup-dev-builds.sh --apply).
#   --rebuild-lsdb          Rebuild the LaunchServices DB at the end (clears
#                           registrations whose bundles were already deleted).
#   --keep <tag>            Protect a tag (repeatable).
#   --reload-leftover PATH  Internal mode for reload.sh: deregister + remove the
#                           sibling base "cmux DEV.app" and dead ".reload-*.app"
#                           staging bundles next to the given final app PATH.
#                           Always applies (no dry-run), keeps PATH itself and
#                           any staging whose reload pid is still running.
#   -h, --help
#
# Examples:
#   ./scripts/supermux-prune-dev-builds.sh                       # preview
#   ./scripts/supermux-prune-dev-builds.sh --apply               # registrations only
#   ./scripts/supermux-prune-dev-builds.sh --apply --prune-derived --rebuild-lsdb
#   ./scripts/supermux-prune-dev-builds.sh --apply --prune-derived --keep my-wip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
TMP_BUILD_GLOB_ROOT="/private/tmp"
LAST_CLI_PATH_FILE="/tmp/cmux-last-cli-path"
BASE_APP_NAME="cmux DEV"

apply=0
prune_derived=0
rebuild_lsdb=0
reload_leftover=""
keep_tags=()

usage() {
    awk '/^# / && !/^#!/ {sub(/^# ?/, ""); print; next} /^set -euo/ {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) apply=1; shift ;;
        --prune-derived) prune_derived=1; shift ;;
        --rebuild-lsdb) rebuild_lsdb=1; shift ;;
        --keep) keep_tags+=("${2:?--keep requires TAG}"); shift 2 ;;
        --reload-leftover) reload_leftover="${2:?--reload-leftover requires PATH}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
done

deregister() {
    # lsregister -u removes a bundle's LaunchServices registration. Tolerate a
    # missing binary or already-gone path; the goal is best-effort cleanup.
    local path="$1"
    [[ -x "$LSREGISTER" ]] || return 0
    "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
}

# ---- internal reload.sh hook ------------------------------------------------
# Remove the redundant base + staging bundles left next to a freshly built
# tagged app. Kept deliberately tiny so it adds no meaningful time to a reload.
if [[ -n "$reload_leftover" ]]; then
    products_dir="$(dirname "$reload_leftover")"
    final_app="$(basename "$reload_leftover")"
    shopt -s nullglob
    for bundle in "$products_dir/$BASE_APP_NAME.app" "$products_dir/".*.reload-*.app; do
        [[ -d "$bundle" ]] || continue
        name="$(basename "$bundle")"
        [[ "$name" == "$final_app" ]] && continue
        # This hook runs automatically on every reload. A staging bundle is
        # named ".<app>.reload-<pid>.app" with the live reload.sh pid; skip one
        # whose reload is still running so a concurrent same-tag reload's
        # in-progress staging is never deleted out from under it. Crashed/dead
        # staging copies fall through and are swept here.
        if [[ "$name" =~ \.reload-([0-9]+)\.app$ ]] && kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
            continue
        fi
        deregister "$bundle"
        rm -rf -- "$bundle"
    done
    shopt -u nullglob
    exit 0
fi

# ---- safety probes ----------------------------------------------------------

active_tag=""
if [[ -r "$LAST_CLI_PATH_FILE" ]]; then
    last_path="$(cat "$LAST_CLI_PATH_FILE" 2>/dev/null || true)"
    if [[ "$last_path" =~ /cmux-([A-Za-z0-9._-]+)/ ]]; then
        active_tag="${BASH_REMATCH[1]}"
    fi
fi

running_tags=()
while IFS= read -r line; do
    # The running process path is ".../cmux DEV <slug>.app/Contents/MacOS/cmux DEV".
    # Capture the slug only: the char class excludes '.' and the literal ".app"
    # anchor stops the match at the bundle suffix, so the tag equals the
    # cmux-<slug> DerivedData dir name discover_bundles derives the tag from.
    # (Slugs are sanitize_path output: [a-z0-9-]+, never '.' or '_'.) Without
    # the anchor the greedy class ate ".app", yielding "<slug>.app" and silently
    # failing every running-app protection.
    if [[ "$line" =~ cmux\ DEV\ ([A-Za-z0-9-]+)\.app ]]; then
        running_tags+=("${BASH_REMATCH[1]}")
    fi
done < <(pgrep -fl "cmux DEV " 2>/dev/null || true)

contains() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

tag_protected() {
    local tag="$1"
    [[ "$tag" == "$active_tag" ]] && return 0
    contains "$tag" ${running_tags[@]+"${running_tags[@]}"} && return 0
    contains "$tag" ${keep_tags[@]+"${keep_tags[@]}"} && return 0
    return 1
}

# ---- discovery --------------------------------------------------------------
# Emit one record per dev-build app bundle:  KIND<TAB>TAG<TAB>PATH
#   KIND = redundant | tagged
# "redundant" = base "cmux DEV.app" or a ".reload-*.app" staging copy (never run).
# "tagged"    = a renamed "cmux DEV <tag>.app" (the real build).
discover_bundles() {
    local dir products tag bundle name
    shopt -s nullglob
    for products in \
        "$DERIVED_DATA_ROOT"/cmux-*/Build/Products/Debug \
        "$TMP_BUILD_GLOB_ROOT"/cmux-*/Build/Products/Debug; do
        [[ -d "$products" ]] || continue
        dir="${products%/Build/Products/Debug}"
        tag="${dir##*/}"; tag="${tag#cmux-}"
        for bundle in "$products"/"$BASE_APP_NAME"*.app "$products"/.*.reload-*.app; do
            [[ -d "$bundle" ]] || continue
            name="$(basename "$bundle")"
            if [[ "$name" == "$BASE_APP_NAME.app" || "$name" == .*reload-*.app ]]; then
                printf 'redundant\t%s\t%s\n' "$tag" "$bundle"
            else
                printf 'tagged\t%s\t%s\n' "$tag" "$bundle"
            fi
        done
    done
    shopt -u nullglob
}

# Every "cmux DEV" app-bundle path the LaunchServices DB still lists (one per
# line). Includes stale orphan records whose bundles were already deleted —
# those are exactly what keeps showing in System Settings, and `lsregister -u`
# clears them even when the path no longer exists on disk.
ls_registered_cmux_paths() {
    [[ -x "$LSREGISTER" ]] || return 0
    "$LSREGISTER" -dump 2>/dev/null \
        | grep -E "^[[:space:]]*path:.*cmux DEV.*\.app \(" \
        | grep -vE "Sparkle.framework|Updater.app" \
        | sed -E 's/.*path: *//; s/ \(0x[0-9a-f]+\)$//' \
        | sort -u
}

# ---- planning ---------------------------------------------------------------

prune_redundant=()   # always pruned (base/staging leftovers, never launched)
prune_tagged=()      # pruned (deregister; disk handled by the sweep)
keep_tagged=()       # protected (active / running / --keep)

while IFS=$'\t' read -r kind tag bundle; do
    [[ -n "$bundle" ]] || continue
    if [[ "$kind" == "redundant" ]]; then
        prune_redundant+=("$bundle")
        continue
    fi
    if tag_protected "$tag"; then
        keep_tagged+=("$tag|$bundle")
    else
        prune_tagged+=("$tag|$bundle")
    fi
done < <(discover_bundles)

# ---- output -----------------------------------------------------------------

printf 'supermux-prune-dev-builds  (mode: %s%s%s)\n\n' \
    "$([[ $apply -eq 1 ]] && echo APPLY || echo DRY-RUN)" \
    "$([[ $prune_derived -eq 1 ]] && echo ' +prune-derived' || true)" \
    "$([[ $rebuild_lsdb -eq 1 ]] && echo ' +rebuild-lsdb' || true)"

[[ -n "$active_tag" ]] && printf 'protected active tag: %s\n' "$active_tag"
((${#running_tags[@]})) && printf 'protected running tags: %s\n' "${running_tags[*]}"
((${#keep_tags[@]})) && printf 'protected --keep tags: %s\n' "${keep_tags[*]}"
echo

if ((${#keep_tagged[@]})); then
    printf 'keeping (registered):\n'
    for e in "${keep_tagged[@]}"; do printf '  %s\n' "${e#*|}"; done
    echo
fi

printf 'deregister + remove (redundant leftovers): %d\n' "${#prune_redundant[@]}"
printf 'deregister (tagged builds): %d\n' "${#prune_tagged[@]}"
if ((${#prune_tagged[@]})); then
    for e in "${prune_tagged[@]}"; do printf '  %s\n' "${e#*|}"; done
fi
echo

# Build cleanup-dev-builds.sh --keep args (empty-array safe under bash 3.2 + set -u).
# Forward this script's own active/running protections too, so --prune-derived
# never deletes a tag we are keeping even if the delegate re-derives the
# active/running sets differently.
keep_args=()
for t in ${keep_tags[@]+"${keep_tags[@]}"}; do keep_args+=(--keep "$t"); done
[[ -n "$active_tag" ]] && keep_args+=(--keep "$active_tag")
for t in ${running_tags[@]+"${running_tags[@]}"}; do keep_args+=(--keep "$t"); done

# Newline-fenced set of protected app paths so the orphan sweep never
# deregisters a build we are keeping.
kept_paths=$'\n'
for e in ${keep_tagged[@]+"${keep_tagged[@]}"}; do kept_paths+="${e#*|}"$'\n'; done

# LaunchServices records to clear: every registered "cmux DEV" path that is not
# a protected/kept bundle (covers stale orphans whose bundles are already gone).
ls_orphan_paths() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        case "$kept_paths" in *$'\n'"$p"$'\n'*) continue ;; esac
        printf '%s\n' "$p"
    done < <(ls_registered_cmux_paths)
}

if ((apply == 0)); then
    printf 'Dry run. Re-run with --apply to deregister/remove.\n'
    orphan_count="$(ls_orphan_paths | grep -c . || true)"
    printf 'stale LaunchServices records to clear: %s\n' "${orphan_count:-0}"
    if ((prune_derived)); then
        echo; echo 'DerivedData sweep preview (cleanup-dev-builds.sh):'; echo
        "$SCRIPT_DIR/cleanup-dev-builds.sh" ${keep_args[@]+"${keep_args[@]}"} || true
    fi
    exit 0
fi

# ---- apply ------------------------------------------------------------------

echo 'applying...'
for bundle in ${prune_redundant[@]+"${prune_redundant[@]}"}; do
    deregister "$bundle"
    rm -rf -- "$bundle"
done
((${#prune_redundant[@]})) && printf '  removed %d redundant leftover bundle(s)\n' "${#prune_redundant[@]}"

for e in ${prune_tagged[@]+"${prune_tagged[@]}"}; do
    deregister "${e#*|}"
done
((${#prune_tagged[@]})) && printf '  deregistered %d tagged build(s)\n' "${#prune_tagged[@]}"

if ((prune_derived)); then
    echo; echo 'DerivedData sweep (cleanup-dev-builds.sh --apply):'; echo
    "$SCRIPT_DIR/cleanup-dev-builds.sh" --apply ${keep_args[@]+"${keep_args[@]}"}
fi

# Clear stale LaunchServices records last, so bundles just deleted by the sweep
# are caught too. Done after disk removal because the dump reflects the DB, not
# the filesystem.
ls_cleared=0
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    deregister "$p"
    ls_cleared=$((ls_cleared + 1))
done < <(ls_orphan_paths)
((ls_cleared)) && printf '  cleared %d stale LaunchServices record(s)\n' "$ls_cleared"

if ((rebuild_lsdb)); then
    echo; echo 'rebuilding LaunchServices database...'
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -kill -r -domain local -domain user >/dev/null 2>&1 || true
        echo '  done'
    else
        echo '  lsregister not found; skipped'
    fi
fi

echo
echo 'Done. Reopen System Settings > General > Login Items & Extensions to refresh.'
echo 'If any "Allow in the Background" rows linger, log out/in or run: sfltool resetbtm'
