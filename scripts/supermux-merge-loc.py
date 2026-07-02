#!/usr/bin/env python3
"""Merge supermux en+ja localization entries into Resources/Localizable.xcstrings.

Idempotent: re-running overwrites only the supermux.* keys it manages, leaving
all other keys untouched — BYTE-untouched. The catalog mixes serialization
styles (Xcode writes `"key" : value`, other tools `"key": value`), so a JSON
round-trip would restyle the whole 3k-key file and swamp the diff. This script
therefore edits the file as text: new keys are appended at the end of
"strings" and updated keys have exactly their own entry block replaced. JSON
parsing is used only to validate input and output.
"""
import json
import sys

import pathlib
CATALOG = str(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Localizable.xcstrings")
EN = "/tmp/supermux_keys_en.json"   # key -> English format string
JA = "/tmp/supermux_keys_ja.json"   # key -> Japanese format string


def esc(value):
    """JSON string literal (keeps non-ASCII literal, matching the catalog)."""
    return json.dumps(value, ensure_ascii=False)


def render_entry(key, en_val, ja_val):
    """One xcstrings entry in the catalog's supermux style (` : ` separator,
    4-space base indent inside "strings")."""
    i = "    "
    return (
        f'{i}{esc(key)} : {{\n'
        f'{i}  "extractionState" : "manual",\n'
        f'{i}  "localizations" : {{\n'
        f'{i}    "en" : {{\n'
        f'{i}      "stringUnit" : {{\n'
        f'{i}        "state" : "translated",\n'
        f'{i}        "value" : {esc(en_val)}\n'
        f'{i}      }}\n'
        f'{i}    }},\n'
        f'{i}    "ja" : {{\n'
        f'{i}      "stringUnit" : {{\n'
        f'{i}        "state" : "translated",\n'
        f'{i}        "value" : {esc(ja_val)}\n'
        f'{i}      }}\n'
        f'{i}    }}\n'
        f'{i}  }}\n'
        f'{i}}}'
    )


def entry_span(text, key):
    """(start, end) of `key`'s whole entry: from the key's opening quote to the
    closing brace of its value object (exclusive of the trailing comma)."""
    for pattern in (f'\n    {esc(key)} : {{', f'\n    {esc(key)}: {{'):
        start = text.find(pattern)
        if start != -1:
            break
    else:
        raise KeyError(key)
    start += 1  # past the leading newline
    position = text.index("{", start)
    depth = 0
    while position < len(text):
        character = text[position]
        if character == '"':
            position += 1
            while text[position] != '"':
                position += 2 if text[position] == "\\" else 1
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return start, position + 1
        position += 1
    raise ValueError(f"unbalanced entry for {key}")


def main():
    en = json.load(open(EN, encoding="utf-8"))
    ja = json.load(open(JA, encoding="utf-8"))
    text = open(CATALOG, encoding="utf-8").read()
    strings = json.loads(text)["strings"]

    missing_ja = [k for k in en if k not in ja]
    if missing_ja:
        print("ERROR: ja missing keys:", missing_ja, file=sys.stderr)
        sys.exit(1)

    added, updated, unchanged = 0, 0, 0
    new_entries = []
    for key, en_val in sorted(en.items()):
        ja_val = ja[key]
        if key in strings:
            existing = strings[key].get("localizations", {})
            same = (
                existing.get("en", {}).get("stringUnit", {}).get("value") == en_val
                and existing.get("ja", {}).get("stringUnit", {}).get("value") == ja_val
            )
            if same:
                unchanged += 1
                continue
            start, end = entry_span(text, key)
            text = text[:start] + render_entry(key, en_val, ja_val) + text[end:]
            updated += 1
        else:
            new_entries.append(render_entry(key, en_val, ja_val))
            added += 1

    if new_entries:
        # Append at the end of "strings": the catalog ends `    }\n  }\n}\n`
        # (last entry, strings dict, root). Insert before the strings close.
        tail = "  }\n}\n"
        if not text.endswith(tail):
            print("ERROR: unexpected catalog tail; not appending", file=sys.stderr)
            sys.exit(1)
        body = text[: -len(tail)].rstrip("\n")
        if not body.endswith("{"):  # non-empty strings dict → comma after last entry
            body += ","
        text = body + "\n" + ",\n".join(new_entries) + "\n" + tail

    # The result must stay valid JSON with every merged key present.
    merged = json.loads(text)
    for key, en_val in en.items():
        unit_value = merged["strings"][key]["localizations"]["en"]["stringUnit"]["value"]
        assert unit_value == en_val, key

    with open(CATALOG, "w", encoding="utf-8") as f:
        f.write(text)

    print(f"merged supermux localization: {added} added, {updated} updated, "
          f"{unchanged} unchanged, {len(en)} given; catalog now {len(merged['strings'])} keys")


if __name__ == "__main__":
    main()
