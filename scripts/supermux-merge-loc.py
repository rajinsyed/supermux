#!/usr/bin/env python3
"""Merge supermux en+ja localization entries into Resources/Localizable.xcstrings.

Idempotent: re-running overwrites only the supermux.* keys it manages, leaving
all other keys untouched and preserving the file's key order for a clean diff.
"""
import json
import sys

import pathlib
CATALOG = str(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Localizable.xcstrings")
EN = "/tmp/supermux_keys_en.json"   # key -> English format string
JA = "/tmp/supermux_keys_ja.json"   # key -> Japanese format string


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    en = json.load(open(EN, encoding="utf-8"))
    ja = json.load(open(JA, encoding="utf-8"))
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    strings = catalog["strings"]

    missing_ja = [k for k in en if k not in ja]
    if missing_ja:
        print("ERROR: ja missing keys:", missing_ja, file=sys.stderr)
        sys.exit(1)

    added, updated = 0, 0
    new_keys = []
    for key, en_val in en.items():
        ja_val = ja[key]
        entry = {
            "extractionState": "manual",
            "localizations": {
                "en": unit(en_val),
                "ja": unit(ja_val),
            },
        }
        if key in strings:
            strings[key] = entry  # update in place, preserve position
            updated += 1
        else:
            new_keys.append((key, entry))
            added += 1

    # Append brand-new supermux keys (sorted among themselves) at the end so the
    # existing 2999 keys keep their order — a minimal, reviewable diff.
    for key, entry in sorted(new_keys):
        strings[key] = entry

    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"merged supermux localization: {added} added, {updated} updated, "
          f"{len(en)} total; catalog now {len(catalog['strings'])} keys")


if __name__ == "__main__":
    main()
