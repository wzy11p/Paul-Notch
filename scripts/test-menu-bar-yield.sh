#!/bin/zsh
set -euo pipefail
yield_root="${0:A:h:h}"
cd "$yield_root"
yield_output=$(mktemp -d /tmp/paul-menu-yield.XXXXXX)
print -r -- "Evidence: $yield_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
yield_bin=$(swift build -c release --show-bin-path)
yield_objects=("$yield_bin"/PaulNotchCore.build/*.swift.o)
yield_objects=(${yield_objects:#*/main.swift.o})
for yield_fixture in MenuBarYieldValidation MenuBarYieldStateValidation; do
  swiftc -O -swift-version 6 -parse-as-library -I "$yield_bin/Modules" \
    "Tests/WindowValidation/$yield_fixture.swift" "${yield_objects[@]}" \
    "$yield_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$yield_output/$yield_fixture"
  PAUL_PREVIEW_DIRECTORY="$yield_output/$yield_fixture-workspace" "$yield_output/$yield_fixture" \
    2>&1 | tee "$yield_output/$yield_fixture.log"
  grep -q '^PASS:' "$yield_output/$yield_fixture.log"
done
