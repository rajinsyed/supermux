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
parser.add_argument("--suite", choices=["tmux", "progress", "tui"], default="tmux")
suite = parser.parse_args().suite
if suite == "tui":
    SOURCES = ["CLI/CLIError.swift", "CLI/CMUXCLI+SSHAuthentication.swift", "CLI/CMUXCLI+SSHCommandOptions.swift",
               "CLI/CMUXCLI+SSHConnectionSharing.swift", "CLI/CMUXCLI+SSHTui.swift", "CLI/CMUXCLI+Process.swift",
               "CLI/CLIWriteDescriptor.swift", "CLI/CMUXCLI+ProcessSignalState.swift"]
    TEST_FILES = ["RuntimeSshTmuxProgressSupport.swift", "RuntimeSshTmuxTuiSupport.swift", "RuntimeSshTmuxTuiTests.swift"]
elif suite == "progress":
    SOURCES = ["CLI/CLIError.swift", "CLI/CMUXCLI+SSHAuthentication.swift"]
    TEST_FILES = ["RuntimeSshTmuxProgressSupport.swift", "RuntimeSshTmuxProgressTests.swift"]
else:
    SOURCES += ["CLI/CMUXCLI+LocalTmux.swift", "CLI/CMUXCLI+LocalTmuxAttachment.swift",
                "CLI/LocalTmuxInvocation.swift", "CLI/LocalSessionAttachProfile.swift"]
    TEST_FILES = ["RuntimeSshTmuxTests.swift", "RuntimeSshTmuxWriteCASSupport.swift",
                  "RuntimeSshTmuxWriteCASTests.swift"]
DEVELOPER = pathlib.Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
FRAMEWORKS = DEVELOPER / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
PLUGINS = DEVELOPER / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
extra = []
if suite == "tui":
    scratch = ROOT / ".build/runtime-ssh-tmux-foundation"
    subprocess.run(["swift", "build", "--package-path", str(ROOT / "Packages/macOS/CmuxFoundation"),
                    "--scratch-path", str(scratch)], check=True, timeout=120)
    debug = scratch / "debug"
    extra = ["-D", "RUNTIME_SSH_TMUX_TUI_HARNESS", "-I", str(debug / "Modules"),
             "-I", str(debug / "CmuxFoundationAtomicsC.build")]
    extra += [str(path) for target in ["CmuxFoundation", "CmuxFoundationAtomicsC"]
              for path in (debug / (target + ".build")).rglob("*.o")]

with tempfile.TemporaryDirectory(prefix="runtime-ssh-tmux-build-") as temporary:
    binary = pathlib.Path(temporary) / "runtime-ssh-tmux-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-D", "RUNTIME_SSH_TMUX_HARNESS",
        "-F", str(FRAMEWORKS), "-framework", "Testing",
        "-Xlinker", "-rpath", "-Xlinker", str(FRAMEWORKS),
        "-plugin-path", str(PLUGINS),
        *extra,
        "-parse-as-library", "-o", str(binary),
        *[str(ROOT / source) for source in SOURCES],
        *[str(TESTS / source) for source in TEST_FILES], str(TESTS / "RuntimeSshTmuxMain.swift"),
    ], check=True, timeout=120)
    result = subprocess.run([str(binary)], timeout=60)
    raise SystemExit(result.returncode)
# SUPERMUX:end runtime-ssh-tmux-test-runner
