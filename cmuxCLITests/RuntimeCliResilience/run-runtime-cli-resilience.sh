#!/bin/sh
# SUPERMUX:begin runtime-cli-resilience-cli-harness
set -eu
: "${CMUX_CLI_PATH:?Set CMUX_CLI_PATH to an isolated, freshly built cmux-cli executable}"
export CMUX_CLI_PATH
test -x "$CMUX_CLI_PATH"
tests="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
harness="$(mktemp -d "${TMPDIR:-/tmp}/runtime-cli-resilience.XXXXXX")"
trap 'rm -rf "$harness"' EXIT HUP INT TERM
mkdir -p "$harness/Tests/RuntimeCliResilienceTests"
cat > "$harness/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RuntimeCliResilienceHarness", platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "RuntimeCliResilienceTests")])
SWIFT
ln -s "$tests/RuntimeCliResilienceInstallAndLabelTests.swift" "$harness/Tests/RuntimeCliResilienceTests/RuntimeCliResilienceInstallAndLabelTests.swift"
swift test --package-path "$harness" --filter RuntimeCliResilienceInstallAndLabelTests "$@"
# SUPERMUX:end runtime-cli-resilience-cli-harness
