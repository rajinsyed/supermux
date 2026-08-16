#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WEB="$ROOT/harness-web"
OUT="$ROOT/Resources/supermux-harness"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to build harness-web" >&2
  exit 1
fi

if [ ! -d "$WEB/node_modules" ]; then
  (cd "$WEB" && bun install --frozen-lockfile)
fi

(cd "$WEB" && bun run build)

if [ ! -f "$WEB/dist/index.html" ]; then
  echo "error: harness-web build produced no dist/index.html" >&2
  exit 1
fi

mkdir -p "$OUT"
cp "$WEB/dist/index.html" "$OUT/index.html"

# The bundle inlines all CSS/JS and escapes </script and <!-- (see
# harness-web/scripts/build.ts); strip trailing whitespace to match repo hygiene.
/usr/bin/perl -0pi -e 's/[ \t]+(?=\r?\n)//g; s/[ \t]+\z//' "$OUT/index.html"

echo "wrote $OUT/index.html"
