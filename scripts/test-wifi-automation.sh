#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sii-wifi-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# A standalone harness also works with Command Line Tools without XCTest.
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$project_dir/Sources/NetWatchSII/WiFiPowerController.swift" \
    "$project_dir/Sources/NetWatchSII/WiFiAutomationManager.swift" \
    "$project_dir/Tests/Swift/WiFiAutomationRegression.swift" \
    -framework AppKit -framework CoreWLAN -framework Combine \
    -o "$test_dir/wifi-tests"
"$test_dir/wifi-tests"
