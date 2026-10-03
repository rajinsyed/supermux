#!/usr/bin/env python3
"""Refuses a tagged app that could reach the user's real account, Macs or app.

The loopback E2E suites quit, relaunch, resize, raise and drive the app they test. They must
only ever touch an agent-only tagged DEBUG build: one built with plain `--tag`
(`CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <tag>`), never with `--supermux-profile`
or `--prod-auth`. A `--supermux-profile` build copies the user's release defaults and Stack
credentials and talks to production cmux.com: it announces itself on the user's account
(presence heartbeats and device-registry rows under this Mac's device id), and anything it does
there is done as the user.

Ways a run could reach the user's real account, Macs or app, and the check for each:

  1. The suites drive the user's running app instead of the tagged one: a shell inside a
     Supermux terminal exports CMUX_SOCKET_PATH (/tmp/supermux.sock). The suites no longer read
     it, and run_all_loopback_e2e.sh passes the tag's socket explicitly.
  2. The app is not a tagged DEV bundle (`com.supermux.app`, `com.cmuxterm.app`, a staging id):
     the bundle id must be `com.cmuxterm.app.debug.<tag slug>`.
  3. The app was built with production auth (`--prod-auth`, `--supermux-profile`): its
     Info.plist LSEnvironment sets CMUX_AUTH_ENVIRONMENT=production or points the API at
     https://cmux.com.
  4. The app joins the production Mac-to-Mac mesh: CMUX_IROH_V2_ENVIRONMENT=production in its
     LSEnvironment or its defaults.
  5. The tag was seeded from the release earlier, and a later plain rebuild kept that state:
     the tag's own defaults carry the production Stack project id or a signed-in session, its
     credentials file (`~/Library/Application Support/cmux/<bundle id>/credentials.json`) exists,
     or its mirror bindings name a Mac that is not the loopback device.

Exit status 0 when every check passes, 1 with one line per reason otherwise. Read-only: it
reads the app's Info.plist, the tag's defaults domain and one file's existence.

  python3 tests/supermux/require_isolated_app.py --app "<App path>" --tag <tag>
"""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

PRODUCTION_ORIGIN = "https://cmux.com"
# Kept in sync with productionStackProjectID (AuthEnvironment.swift), as
# scripts/supermux-seed-dev-profile.sh does.
PRODUCTION_STACK_PROJECT_ID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
LOOPBACK_DEVICE_ID = "5e1f10b0-0000-4000-8000-000000000001"
REBUILD = "rebuild it with a tag that never had --supermux-profile: CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag <new-tag>"


def tag_slug(tag: str) -> str:
    """reload.sh's slug: lowercase, every run of other characters becomes '-'."""
    return re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")


def production_auth_stack_project_id(repo_root: Path) -> str:
    source = repo_root / "Packages/macOS/CmuxCloud/Sources/CmuxCloud/Environment/AuthEnvironment.swift"
    try:
        match = re.search(r'productionStackProjectID = "([^"]+)"', source.read_text())
    except OSError:
        match = None
    return match.group(1) if match else PRODUCTION_STACK_PROJECT_ID


def read_defaults(bundle_id: str) -> Dict[str, Any]:
    exported = subprocess.run(["defaults", "export", bundle_id, "-"], capture_output=True)
    if exported.returncode != 0 or not exported.stdout:
        return {}
    try:
        return plistlib.loads(exported.stdout)
    except Exception:  # an unreadable domain is not a reason to refuse; the build checks still run
        return {}


def text(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return "" if value is None else str(value)


def reasons(app: Path, tag: str, repo_root: Path) -> List[str]:
    info_path = app / "Contents" / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except OSError as error:
        return [f"cannot read {info_path}: {error}"]
    found: List[str] = []
    bundle_id = str(info.get("CFBundleIdentifier") or "")
    expected = "com.cmuxterm.app.debug." + tag_slug(tag).replace("-", ".")
    if bundle_id != expected:
        found.append(f"bundle id is {bundle_id!r}, not the tagged DEV id {expected!r}")
    env = info.get("LSEnvironment") or {}
    if str(env.get("CMUX_AUTH_ENVIRONMENT", "")).strip().lower() == "production":
        found.append("built with production auth (LSEnvironment CMUX_AUTH_ENVIRONMENT=production: --prod-auth or --supermux-profile)")
    production_keys = [key for key in ("CMUX_API_BASE_URL", "CMUX_AUTH_WWW_ORIGIN", "CMUX_IROH_BROKER_BASE_URL")
                       if str(env.get(key, "")).rstrip("/") == PRODUCTION_ORIGIN]
    if production_keys:
        found.append(f"built against production {PRODUCTION_ORIGIN} (LSEnvironment {', '.join(production_keys)})")
    if str(env.get("CMUX_IROH_V2_ENVIRONMENT", "")).strip().lower() == "production":
        found.append("joins the production Mac-to-Mac mesh (LSEnvironment CMUX_IROH_V2_ENVIRONMENT=production)")
    if not bundle_id.startswith("com.cmuxterm.app.debug."):
        return found  # never read the user's own defaults domain

    defaults = read_defaults(bundle_id)
    production_project = production_auth_stack_project_id(repo_root)
    if text(defaults.get("cmux.auth.stackProjectID")) == production_project:
        found.append(f"its defaults ({bundle_id}) hold the production Stack project: seeded from the release by --supermux-profile")
    if text(defaults.get("cmux.iroh.v2.config.CMUX_IROH_V2_ENVIRONMENT")).lower() == "production":
        found.append(f"its defaults ({bundle_id}) select the production Mac-to-Mac mesh")
    bindings = text(defaults.get("supermux.devices.mirrorBindings.v1"))
    machines = sorted(set(re.findall(r"device:([0-9a-fA-F-]+)@[A-Za-z0-9._-]+", bindings)))
    real = [m for m in machines if m.lower() != LOOPBACK_DEVICE_ID]
    if real:
        found.append(f"its defaults ({bundle_id}) mirror real Macs ({', '.join(real)}): seeded from the release")
    credentials = Path.home() / "Library/Application Support/cmux" / bundle_id / "credentials.json"
    if credentials.exists():
        found.append(f"a copied sign-in exists ({credentials}): --supermux-profile seeded the user's Stack session")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the tagged .app the suites will launch")
    parser.add_argument("--tag", required=True, help="its build tag (CMUX_TAG)")
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    found = reasons(Path(args.app), args.tag, repo_root)
    if not found:
        return 0
    print(f"REFUSING to run loopback E2E against {Path(args.app).name}: it can reach your real account, Macs or app.",
          file=sys.stderr)
    for reason in found:
        print(f"  - {reason}", file=sys.stderr)
    print(f"Agent E2E runs use agent-only builds; {REBUILD}.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
