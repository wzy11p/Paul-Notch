#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"
test_data="$(mktemp -d /tmp/paul-notch-safety.XXXXXX)"

if swift -e 'import XCTest' >/dev/null 2>&1; then
  PAUL_PREVIEW_DIRECTORY="$test_data" swift test
else
  print -r -- 'XCTest is unavailable in Command Line Tools; running the same test bodies standalone.'
  swift build
  safety_sources=("${(@f)$(find Sources/PaulNotchCore -type f -name '*.swift' -print | sort)}")
  build_dir="$(swift build --show-bin-path)"
  lunar_objects=("$build_dir"/LunarSwift.build/*.o)
  swiftc -parse-as-library -I "$build_dir/Modules" "${safety_sources[@]}" \
    Tests/PaulNotchCoreTests/SafetyTests.swift "${lunar_objects[@]}" -lsqlite3 -o "$test_data/SafetyTests"
  PAUL_PREVIEW_DIRECTORY="$test_data" "$test_data/SafetyTests"
  PAUL_PREVIEW_DIRECTORY="$test_data" "$test_data/SafetyTests"
fi

print -r -- "Synthetic fixtures retained at: $test_data"
