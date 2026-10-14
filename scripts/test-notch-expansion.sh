#!/bin/zsh
set -euo pipefail
expansion_root="${0:A:h:h}"
cd "$expansion_root"
expansion_output=$(mktemp -d /tmp/paul-notch-expansion.XXXXXX)
print -r -- "Evidence: $expansion_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
expansion_bin=$(swift build -c release --show-bin-path)
expansion_objects=("$expansion_bin"/PaulNotchCore.build/*.swift.o)
expansion_objects=(${expansion_objects:#*/main.swift.o})
swiftc -O -swift-version 6 -parse-as-library -I "$expansion_bin/Modules" \
  Tests/WindowValidation/NotchExpansionValidation.swift "${expansion_objects[@]}" \
  "$expansion_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$expansion_output/NotchExpansionValidation"
PAUL_PREVIEW_DIRECTORY="$expansion_output/workspace" \
  "$expansion_output/NotchExpansionValidation" "$expansion_output" 2>&1 | tee "$expansion_output/result.log"
grep -q '^PASS:' "$expansion_output/result.log"
