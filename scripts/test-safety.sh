#!/bin/zsh
set -euo pipefail
test_root="${0:A:h:h}"
cd "$test_root"
test_data="$(mktemp -d /tmp/paul-safety-run.XXXXXX)"
if swift -e 'import XCTest' >/dev/null 2>&1; then
    PAUL_PREVIEW_DIRECTORY="$test_data" swift test
else
    print -r -- "XCTest unavailable in Command Line Tools; running identical test bodies standalone."
    swift build
    safety_sources=(Sources/PaulNotchCore/**/*.swift(N))
    safety_sources=(${safety_sources:#*/main.swift})
    build_dir="$(swift build --show-bin-path)"
    lunar_objects=("$build_dir"/LunarSwift.build/*.o)
    swiftc -parse-as-library -I "$build_dir/Modules" "${safety_sources[@]}" \
        Tests/PaulNotchCoreTests/SafetyTests.swift "${lunar_objects[@]}" -lsqlite3 -o "$test_data/SafetyTests"
    PAUL_PREVIEW_DIRECTORY="$test_data" "$test_data/SafetyTests"
    # A second process validates that the same preview namespace survives restart.
    PAUL_PREVIEW_DIRECTORY="$test_data" "$test_data/SafetyTests"
fi
print -r -- "Synthetic fixtures retained at: $test_data"
