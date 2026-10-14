#!/bin/zsh
set -euo pipefail
notch_root="${0:A:h:h}"
cd "$notch_root"
notch_output=$(mktemp -d /tmp/paul-notch-simplicity.XXXXXX)
print -r -- "Evidence: $notch_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
notch_bin=$(swift build -c release --show-bin-path)
notch_objects=("$notch_bin"/PaulNotchCore.build/*.swift.o)
notch_objects=(${notch_objects:#*/main.swift.o})
notch_fixture=Tests/QuotaOverview/NotchSimplicityValidation.swift
if [[ "${1:-}" == environment ]]; then notch_fixture=Tests/WindowValidation/AmbientEnvironmentValidation.swift; fi
swiftc -O -swift-version 6 -parse-as-library -I "$notch_bin/Modules" "$notch_fixture" \
  "${notch_objects[@]}" "$notch_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$notch_output/validate"
PAUL_PREVIEW_DIRECTORY="$notch_output/workspace" "$notch_output/validate" "$notch_output" \
  2>&1 | tee "$notch_output/result.log"
grep -q '^PASS: (native single/dual|ambient environment regression complete)' "$notch_output/result.log"
