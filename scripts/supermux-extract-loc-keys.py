import re, json, os, sys

import pathlib
ROOT = str(pathlib.Path(__file__).resolve().parent.parent)
globs = [
    "Packages/SupermuxKit/Sources",
    "Sources/Supermux",
    "Sources/KeyboardShortcutSettings.swift",
    "Sources/RightSidebarPanelView.swift",
    "Sources/RightSidebarMode+Availability.swift",
    "CLI/cmux.swift",
]
files = []
for g in globs:
    p = os.path.join(ROOT, g)
    if os.path.isfile(p):
        files.append(p)
    elif os.path.isdir(p):
        for dp, _, fns in os.walk(p):
            for fn in fns:
                if fn.endswith(".swift"):
                    files.append(os.path.join(dp, fn))

pat = re.compile(
    r'String\(\s*localized:\s*"(supermux\.[^"]+)"\s*,\s*defaultValue:\s*"((?:[^"\\]|\\.)*)"',
    re.DOTALL,
)
def unescape(s):
    # only handle the escapes that actually appear: \" \\ \n
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')

keys = {}
for f in files:
    text = open(f, encoding="utf-8").read()
    for m in pat.finditer(text):
        keys[m.group(1)] = unescape(m.group(2))

json.dump(keys, open("/tmp/supermux_keys.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"total: {len(keys)} keys", file=sys.stderr)
