#!/usr/bin/env python3
# SUPERMUX:begin runtime-ssh-tmux-test-runner
"""Headless Swift Testing against whole production files, without Xcode wiring."""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
TESTS = pathlib.Path(__file__).resolve().parent
SOURCES = [
    "CLI/CLIError.swift",
    "CLI/LocalTmuxSessionIdentity.swift",
    "CLI/LocalTmuxSessionBinding.swift",
    "CLI/LocalTmuxCommandBuilder.swift",
    "CLI/LocalTmuxProcessRunner.swift",
    "CLI/LocalTmuxSessionRegistry.swift",
    "CLI/LocalTmuxSessionIdentityResolver.swift",
]
parser = argparse.ArgumentParser()
parser.add_argument("--suite", choices=["tmux", "progress"], default="tmux")
suite = parser.parse_args().suite
if suite == "progress":
    SOURCES = ["CLI/CLIError.swift", "CLI/CMUXCLI+SSHAuthentication.swift"]
    TEST_FILES = ["RuntimeSshTmuxProgressSupport.swift", "RuntimeSshTmuxProgressTests.swift"]
else:
    TEST_FILES = ["RuntimeSshTmuxTests.swift"]
DEVELOPER = pathlib.Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
FRAMEWORKS = DEVELOPER / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
PLUGINS = DEVELOPER / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"

with tempfile.TemporaryDirectory(prefix="runtime-ssh-tmux-build-") as temporary:
    binary = pathlib.Path(temporary) / "runtime-ssh-tmux-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-D", "RUNTIME_SSH_TMUX_HARNESS",
        "-F", str(FRAMEWORKS), "-framework", "Testing",
        "-Xlinker", "-rpath", "-Xlinker", str(FRAMEWORKS),
        "-plugin-path", str(PLUGINS),
        "-parse-as-library", "-o", str(binary),
        *[str(ROOT / source) for source in SOURCES],
        *[str(TESTS / source) for source in TEST_FILES], str(TESTS / "RuntimeSshTmuxMain.swift"),
    ], check=True, timeout=120)
    result = subprocess.run([str(binary)], timeout=60)
    raise SystemExit(result.returncode)
# SUPERMUX:end runtime-ssh-tmux-test-runner
