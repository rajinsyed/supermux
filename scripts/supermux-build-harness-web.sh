#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WEB="$ROOT/harness-web"
OUT="$ROOT/Resources/supermux-harness"
MODE=write

case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

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

# The bundle inlines all CSS/JS and escapes </script and <!-- (see
# harness-web/scripts/build.ts); normalize the built artifact before either
# comparing or copying it.
/usr/bin/perl -0pi -e 's/[ \t]+(?=\r?\n)//g; s/[ \t]+\z//' "$WEB/dist/index.html"

if [ "$MODE" = check ]; then
  if [ ! -f "$OUT/index.html" ] || ! cmp -s "$WEB/dist/index.html" "$OUT/index.html"; then
    echo "error: $OUT/index.html is out of date" >&2
    echo "run scripts/supermux-build-harness-web.sh" >&2
    exit 1
  fi
  echo "checked $OUT/index.html"
  exit 0
fi

mkdir -p "$OUT"
cp "$WEB/dist/index.html" "$OUT/index.html"
echo "wrote $OUT/index.html"
