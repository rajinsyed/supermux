#!/usr/bin/env python3
"""Checks require_isolated_app.py against fake tagged apps, without any real app or account.

Each case builds a fake `.app` (an Info.plist only) and, under a temporary HOME, the
credentials files the guard reads. The bundle ids use a random tag, so no defaults domain
exists for them and the guard's `defaults export` finds nothing. Nothing is launched and no
defaults are written; the real HOME is never read.

The ways the guard could be wrong, and the case for each:

  plain_unsigned_passes         a plain tag that never signed in
  plain_empty_sign_in_passes    a plain tag whose sign-in wrote `{}` (the keychain path writes it too)
  plain_dev_sign_in_passes      a plain tag signed in with its own session (the ~/.secrets dogfood
                                account or a manual dev sign-in): another refresh token
  copied_release_session_refused
                                the tag holds the release app's own refresh token (--supermux-profile)
  tokens_never_printed          neither token appears in the guard's output
  production_auth_refused       LSEnvironment CMUX_AUTH_ENVIRONMENT=production
  production_mesh_refused       LSEnvironment CMUX_IROH_V2_ENVIRONMENT=production
  release_bundle_refused        the user's own app (com.supermux.app)

Exits non-zero on any failure and prints one line per case.

  python3 tests/supermux/require_isolated_app_check.py
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Dict, List, Optional, Tuple

GUARD = Path(__file__).resolve().parent / "require_isolated_app.py"
RELEASE_TOKEN = "release-refresh-" + uuid.uuid4().hex
TAG_TOKEN = "tag-refresh-" + uuid.uuid4().hex


def bundle_id_for(tag: str) -> str:
    return "com.cmuxterm.app.debug." + tag.replace("-", ".")


def make_app(root: Path, tag: str, bundle_id: Optional[str] = None, env: Optional[Dict[str, str]] = None) -> Path:
    app = root / f"cmux DEV {tag}.app"
    (app / "Contents").mkdir(parents=True)
    info = {
        "CFBundleIdentifier": bundle_id or bundle_id_for(tag),
        "LSEnvironment": {"CMUX_IROH_V2_ENVIRONMENT": "development", "CMUX_API_BASE_URL": "http://localhost:3777",
                          **(env or {})},
    }
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
    return app


def write_credentials(home: Path, bundle_id: str, body: object) -> None:
    folder = home / "Library" / "Application Support" / "cmux" / bundle_id
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "credentials.json").write_text(json.dumps(body))


def run_guard(home: Path, app: Path, tag: str) -> Tuple[int, str]:
    env = dict(os.environ, HOME=str(home))
    result = subprocess.run([sys.executable, str(GUARD), "--app", str(app), "--tag", tag],
                            capture_output=True, text=True, env=env)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    outcomes: List[Tuple[str, bool, str]] = []
    with tempfile.TemporaryDirectory(prefix="require-isolated-app-") as scratch:
        root = Path(scratch)
        home = root / "home"
        write_credentials(home, "com.supermux.app", {"accessToken": "release-access", "refreshToken": RELEASE_TOKEN})
        outputs: List[str] = []

        def case(name: str, expect_refused: bool, tag_body: object = None, bundle_id: Optional[str] = None,
                 env: Optional[Dict[str, str]] = None) -> None:
            tag = f"guardcheck-{uuid.uuid4().hex[:8]}"
            app = make_app(root / name, tag, bundle_id, env)
            if tag_body is not None:
                write_credentials(home, bundle_id or bundle_id_for(tag), tag_body)
            code, output = run_guard(home, app, tag)
            outputs.append(output)
            refused = code != 0
            detail = output.strip().splitlines()[1:2] if refused else []
            outcomes.append((name, refused == expect_refused,
                             f"{'refused' if refused else 'accepted'}{': ' + detail[0].strip() if detail else ''}"))

        case("plain_unsigned_passes", False)
        case("plain_empty_sign_in_passes", False, tag_body={})
        case("plain_dev_sign_in_passes", False, tag_body={"accessToken": "dev-access", "refreshToken": TAG_TOKEN})
        case("copied_release_session_refused", True,
             tag_body={"accessToken": "copied-access", "refreshToken": RELEASE_TOKEN})
        case("production_auth_refused", True, env={"CMUX_AUTH_ENVIRONMENT": "production"})
        case("production_mesh_refused", True, env={"CMUX_IROH_V2_ENVIRONMENT": "production"})
        case("release_bundle_refused", True, bundle_id="com.supermux.app")
        leaked = [token for token in (RELEASE_TOKEN, TAG_TOKEN) if any(token in out for out in outputs)]
        outcomes.append(("tokens_never_printed", not leaked, "leaked" if leaked else "no token in any output"))

    for name, ok, detail in outcomes:
        print(f"{'PASS' if ok else 'FAIL'} {name} ({detail})")
    return 0 if all(ok for _, ok, _ in outcomes) else 1


if __name__ == "__main__":
    sys.exit(main())
