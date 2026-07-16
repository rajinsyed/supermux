#!/usr/bin/env python3
"""Verify cmux-owned SwiftPM lockfiles are not ignored."""

from __future__ import annotations

from fnmatch import fnmatchcase
import os
from pathlib import Path
import re
import subprocess
import sys


ALLOWED_IGNORED_PREFIXES = (
    "vendor/",
    "ghostty/",
)

XCODE_PACKAGE_RESOLVED = (
    "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
XCODE_PROJECT_FILE = "cmux.xcodeproj/project.pbxproj"
XCODE_PACKAGE_REFERENCE_TOKENS = (
    "XCRemoteSwiftPackageReference",
    "repositoryURL",
    "minimumVersion",
    "exactVersion",
    "revision",
    "branch",
    "requirement =",
)
PACKAGE_DEPENDENCY_RE = re.compile(r"\.package\(([^)]*)\)", re.DOTALL)
PACKAGE_PATH_ARGUMENT_RE = re.compile(r'\bpath\s*:\s*"([^"]+)"')
PACKAGE_URL_ARGUMENT_RE = re.compile(r'\burl\s*:\s*"[^"]+"')

SKIPPED_DIRS = {
    ".build",
    ".git",
    ".swiftpm",
    ".ci-source-packages",
    "DerivedData",
    "node_modules",
}


def git_ls_files(*args: str) -> list[str]:
    return [line for line in git_stdout("ls-files", *args).splitlines() if line]


def git_stdout(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def is_allowed_vendor_path(path: str) -> bool:
    return path.startswith(ALLOWED_IGNORED_PREFIXES)


def has_skipped_part(path: str) -> bool:
    return any(part in SKIPPED_DIRS for part in Path(path).parts)


def tracked_package_manifests(*, include_allowed_vendor: bool) -> dict[str, Path]:
    manifests: dict[str, Path] = {}
    for manifest in git_ls_files("*Package.swift"):
        if has_skipped_part(manifest):
            continue
        if not include_allowed_vendor and is_allowed_vendor_path(manifest):
            continue
        path = Path(manifest)
        manifests[path.parent.as_posix()] = path
    return manifests


def package_graph(manifests: dict[str, Path]) -> dict[str, tuple[bool, list[str]]]:
    root_by_resolved_path = {
        manifest.parent.resolve(): root for root, manifest in manifests.items()
    }
    graph: dict[str, tuple[bool, list[str]]] = {}

    for root, manifest in manifests.items():
        text = manifest.read_text(encoding="utf-8")
        path_dependencies: list[str] = []
        has_url_dependency = False
        for dependency in PACKAGE_DEPENDENCY_RE.findall(text):
            if PACKAGE_URL_ARGUMENT_RE.search(dependency):
                has_url_dependency = True
            path_match = PACKAGE_PATH_ARGUMENT_RE.search(dependency)
            if path_match is None:
                continue
            dependency_root = (manifest.parent / path_match.group(1)).resolve()
            if dependency_root in root_by_resolved_path:
                path_dependencies.append(root_by_resolved_path[dependency_root])
        graph[root] = (has_url_dependency, path_dependencies)

    return graph


def package_dependency_calls(text: str) -> list[str]:
    return [" ".join(dependency.split()) for dependency in PACKAGE_DEPENDENCY_RE.findall(text)]


def dependency_calls_include_url(calls: list[str]) -> bool:
    return any(PACKAGE_URL_ARGUMENT_RE.search(call) for call in calls)


# SUPERMUX:begin fix-resolved-policy-path-deps
def lockfile_recorded_dependency_calls(calls: list[str]) -> list[str]:
    """Dependency calls that SwiftPM records in Package.resolved.

    `.package(path:)` dependencies are resolved by location and never written
    to any lockfile, so manifest changes limited to path-based dependencies
    cannot produce a legitimate Package.resolved diff (`swift package resolve`
    rewrites nothing). Only url/registry (version/branch/revision-pinned)
    dependency changes must come with lockfile churn.
    """
    return [
        call
        for call in calls
        if PACKAGE_URL_ARGUMENT_RE.search(call)
        or PACKAGE_PATH_ARGUMENT_RE.search(call) is None
    ]
# SUPERMUX:end fix-resolved-policy-path-deps


def has_remote_dependency(
    root: str,
    graph: dict[str, tuple[bool, list[str]]],
    memo: dict[str, bool],
    visiting: set[str],
) -> bool:
    if root in memo:
        return memo[root]
    if root in visiting:
        return False
    has_url_dependency, path_dependencies = graph.get(root, (False, []))
    visiting.add(root)
    needs_lockfile = has_url_dependency or any(
        has_remote_dependency(dependency, graph, memo, visiting)
        for dependency in path_dependencies
    )
    visiting.remove(root)
    memo[root] = needs_lockfile
    return needs_lockfile


# SUPERMUX:begin fix-resolved-policy-path-deps
def path_dependency_remote_pin_roots(
    calls: list[str],
    manifest: Path,
    all_manifests: dict[str, Path],
    graph: dict[str, tuple[bool, list[str]]],
    memo: dict[str, bool],
) -> set[str]:
    """Graph roots reachable through this manifest's `.package(path:)` deps
    that carry remote (url/registry) pins.

    A path-dependency-only manifest change is invisible to Package.resolved
    ONLY when it does not alter which remote-pinned packages the root pulls
    into its resolution closure. Retargeting a path dep to a pinned package —
    or adding such a path dep — changes this set and MUST still demand a
    lockfile diff; adding/retargeting among pin-free local packages (the
    mission's local package graph) does not. Comparing this set current-vs-
    previous distinguishes the two, so the exemption stays satisfiable for
    pin-free path deps without letting closure-changing path deps escape.
    """
    root_by_resolved_path = {
        candidate.parent.resolve(): root
        for root, candidate in all_manifests.items()
    }
    pins: set[str] = set()
    for call in calls:
        if PACKAGE_URL_ARGUMENT_RE.search(call):
            continue
        match = PACKAGE_PATH_ARGUMENT_RE.search(call)
        if match is None:
            continue
        target = (manifest.parent / match.group(1)).resolve()
        target_root = root_by_resolved_path.get(target)
        if target_root is not None and has_remote_dependency(
            target_root, graph, memo, set()
        ):
            pins.add(target_root)
    return pins
# SUPERMUX:end fix-resolved-policy-path-deps


def package_dependency_closure(
    root: str,
    graph: dict[str, tuple[bool, list[str]]],
) -> set[str]:
    closure: set[str] = set()

    def visit(current: str) -> None:
        if current in closure:
            return
        closure.add(current)
        _has_url_dependency, path_dependencies = graph.get(current, (False, []))
        for dependency in path_dependencies:
            visit(dependency)

    visit(root)
    return closure


def package_roots_requiring_lockfiles(
    cmux_manifests: dict[str, Path] | None = None,
    graph: dict[str, tuple[bool, list[str]]] | None = None,
) -> set[str]:
    if cmux_manifests is None or graph is None:
        all_manifests = tracked_package_manifests(include_allowed_vendor=True)
        cmux_manifests = tracked_package_manifests(include_allowed_vendor=False)
        graph = package_graph(all_manifests)
    memo: dict[str, bool] = {}

    return {
        root for root in cmux_manifests
        if has_remote_dependency(root, graph, memo, set())
    }


def package_lockfile_path(root: str) -> str:
    if root == ".":
        return "Package.resolved"
    return f"{root}/Package.resolved"


def base_ref() -> str:
    if override := os.environ.get("PACKAGE_RESOLVED_POLICY_BASE_REF"):
        return override
    if github_base := os.environ.get("GITHUB_BASE_REF"):
        return f"origin/{github_base}"
    return "origin/main"


def merge_base_with_base_ref() -> str | None:
    try:
        return git_stdout("merge-base", base_ref(), "HEAD").strip()
    except subprocess.CalledProcessError:
        if os.environ.get("GITHUB_BASE_REF") or os.environ.get(
            "PACKAGE_RESOLVED_POLICY_BASE_REF"
        ):
            raise
        return None


def changed_files_since(merge_base: str | None) -> set[str]:
    if merge_base is None:
        return set()
    return set(git_stdout("diff", "--name-only", f"{merge_base}..HEAD").splitlines())


def file_text_at(ref: str, path: str) -> str:
    # SUPERMUX:begin fix-resolved-policy-path-deps
    # A manifest new since the merge-base has no blob at `ref`; that is
    # expected (it reads as ""), so silence git's `fatal: path … exists on
    # disk, but not in <ref>` stderr noise instead of letting it leak
    # into the check output.
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout
    # SUPERMUX:end fix-resolved-policy-path-deps


def xcode_package_reference_changed(
    merge_base: str | None,
    changed_files: set[str],
) -> bool:
    if merge_base is None or XCODE_PROJECT_FILE not in changed_files:
        return False
    diff = git_stdout(
        "diff",
        "--unified=0",
        f"{merge_base}..HEAD",
        "--",
        XCODE_PROJECT_FILE,
    )
    for line in diff.splitlines():
        if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
            continue
        if any(token in line for token in XCODE_PACKAGE_REFERENCE_TOKENS):
            return True
    return False


def is_expected_lockfile_path(lockfile: str, roots: set[str]) -> bool:
    if lockfile == XCODE_PACKAGE_RESOLVED:
        return True
    if has_skipped_part(lockfile):
        return False
    return Path(lockfile).parent.as_posix() in roots


def ignores_package_resolved(gitignore: Path) -> bool:
    ignored = False

    for raw_line in gitignore.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        is_negated = line.startswith("!")
        pattern = line[1:] if is_negated else line
        pattern = pattern.rstrip("/").lstrip("/")
        if pattern == "Package.resolved" or pattern.endswith("/Package.resolved"):
            ignored = not is_negated
            continue
        if fnmatchcase("Package.resolved", pattern):
            ignored = not is_negated
    return ignored


def main() -> int:
    errors: list[str] = []
    all_manifests = tracked_package_manifests(include_allowed_vendor=True)
    cmux_manifests = {
        root: manifest for root, manifest in all_manifests.items()
        if not is_allowed_vendor_path(manifest.as_posix())
    }
    graph = package_graph(all_manifests)
    roots = set(cmux_manifests)
    tracked_lockfiles = set(git_ls_files("*Package.resolved"))
    required_lockfile_roots = package_roots_requiring_lockfiles(cmux_manifests, graph)
    merge_base = merge_base_with_base_ref()
    changed_files = changed_files_since(merge_base)
    changed_dependency_roots: set[str] = set()

    if merge_base is not None:
        remote_memo: dict[str, bool] = {}
        for root, manifest in all_manifests.items():
            if manifest.as_posix() not in changed_files:
                continue
            current_calls = package_dependency_calls(
                manifest.read_text(encoding="utf-8")
            )
            previous_calls = package_dependency_calls(
                file_text_at(merge_base, manifest.as_posix())
            )
            if current_calls == previous_calls:
                continue
            # SUPERMUX:begin fix-resolved-policy-path-deps
            # Path-based dependency changes never appear in Package.resolved
            # directly, so requiring a lockfile diff for a change limited to
            # them is normally unsatisfiable. BUT a path dep retargeted to (or
            # newly pointed at) a package that carries remote pins DOES change
            # the root's recorded resolution closure — `swift package resolve`
            # would rewrite Package.resolved with the new transitive pins. So
            # skip only when BOTH the recorded (url) calls are unchanged AND
            # the set of remote-pin-bearing packages reachable via the root's
            # path deps is unchanged. Pinned (url) changes still demand churn.
            if (
                lockfile_recorded_dependency_calls(current_calls)
                == lockfile_recorded_dependency_calls(previous_calls)
                and path_dependency_remote_pin_roots(
                    current_calls, manifest, all_manifests, graph, remote_memo
                )
                == path_dependency_remote_pin_roots(
                    previous_calls, manifest, all_manifests, graph, remote_memo
                )
            ):
                continue
            # SUPERMUX:end fix-resolved-policy-path-deps
            if (
                root in cmux_manifests
                or dependency_calls_include_url(current_calls + previous_calls)
                or has_remote_dependency(root, graph, remote_memo, set())
            ):
                changed_dependency_roots.add(root)

    if (
        xcode_package_reference_changed(merge_base, changed_files)
        and XCODE_PACKAGE_RESOLVED not in changed_files
    ):
        errors.append(
            f"{XCODE_PROJECT_FILE} changed SwiftPM package references without "
            f"matching Xcode Package.resolved diff: {XCODE_PACKAGE_RESOLVED}"
        )

    for gitignore in sorted(Path(".").rglob(".gitignore")):
        rel = gitignore.as_posix()
        if rel.startswith("./"):
            rel = rel[2:]
        if has_skipped_part(rel):
            continue
        if not ignores_package_resolved(gitignore):
            continue
        if is_allowed_vendor_path(rel):
            continue
        errors.append(
            f"{rel} ignores Package.resolved. cmux-owned SwiftPM lockfiles must be tracked."
        )

    for expected_root in sorted(required_lockfile_roots):
        expected_lockfile = package_lockfile_path(expected_root)
        if expected_lockfile in tracked_lockfiles:
            continue
        errors.append(
            f"Missing Package.resolved for SwiftPM package with remote pins: {expected_lockfile}"
        )

    for root, manifest in sorted(cmux_manifests.items()):
        expected_lockfile = package_lockfile_path(root)
        has_or_requires_lockfile = (
            root in required_lockfile_roots or expected_lockfile in tracked_lockfiles
        )
        if not has_or_requires_lockfile:
            continue
        affected_dependency_roots = (
            package_dependency_closure(root, graph) & changed_dependency_roots
        )
        if not affected_dependency_roots:
            continue
        if expected_lockfile in changed_files:
            continue
        changed_manifests = ", ".join(
            all_manifests[changed_root].as_posix()
            for changed_root in sorted(affected_dependency_roots)
        )
        errors.append(
            f"{changed_manifests} changed SwiftPM package dependencies without "
            f"matching Package.resolved diff: {expected_lockfile}"
        )

    for lockfile in tracked_lockfiles:
        if is_allowed_vendor_path(lockfile):
            continue
        if is_expected_lockfile_path(lockfile, roots):
            continue
        errors.append(f"Unexpected cmux Package.resolved location: {lockfile}")

    if errors:
        print("Package.resolved policy violations:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Package.resolved policy OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
