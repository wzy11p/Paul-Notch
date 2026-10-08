#!/bin/zsh
set -euo pipefail
foreground_root="${0:A:h:h}"
cd "$foreground_root"
foreground_output=$(mktemp -d /tmp/paul-foreground-native.XXXXXX)
print -r -- "Isolated foreground shelf regression: $foreground_output"
swift build --disable-sandbox
foreground_bin=$(swift build --disable-sandbox --show-bin-path)
foreground_objects=("$foreground_bin"/PaulNotchCore.build/*.swift.o)
foreground_objects=(${foreground_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$foreground_bin/Modules" \
  Tests/WindowValidation/AmbientForegroundNativeValidation.swift \
  "${foreground_objects[@]}" "$foreground_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$foreground_output/ForegroundNativeValidation"
mkdir -p "$foreground_output/workspace"
PAUL_PREVIEW_DIRECTORY="$foreground_output/workspace" "$foreground_output/ForegroundNativeValidation" \
  2>&1 | tee "$foreground_output/result.log"
if ! rg -q '^PASS: foreground native shelf switching' "$foreground_output/result.log"; then
  print -u2 -- 'BLOCKED: native foreground assertions did not complete'
  exit 2
fi
