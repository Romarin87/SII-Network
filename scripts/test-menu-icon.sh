#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sii-icon-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$project_dir/.build/icon-test-cache" \
    "$project_dir/Sources/NetWatchSII/MenuBarIcon.swift" \
    "$project_dir/Tests/Swift/MenuBarIconRegression.swift" \
    -framework AppKit -o "$test_dir/icon-tests"
"$test_dir/icon-tests" "$project_dir/Resources/MenuBarTemplate.png" "$@"
