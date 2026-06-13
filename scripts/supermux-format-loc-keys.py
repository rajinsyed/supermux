import json, re

d = json.load(open("/tmp/supermux_keys.json"))

# Interpolations that are integers -> %lld; everything else -> %@
INT_KEYS = {
    "supermux.changes.aheadBadge", "supermux.changes.behindBadge",
    "supermux.changes.pushCount", "supermux.changes.pullCount",
}

def to_format(key, val):
    # replace \(...) with %lld for int keys else %@
    placeholder = "%lld" if key in INT_KEYS else "%@"
    return re.sub(r"\\\([^)]*\)", placeholder, val)

out = {}
for k, v in d.items():
    out[k] = to_format(k, v)

json.dump(out, open("/tmp/supermux_keys_en.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
# show the interpolated ones to verify
for k, v in out.items():
    if "%@" in v or "%lld" in v:
        print(f"{k}: {v!r}")
