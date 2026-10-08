#!/bin/zsh
set -euo pipefail
cursor_root="${0:A:h:h}"
cd "$cursor_root"
cursor_output=$(mktemp -d /tmp/paul-cursor-browser.XXXXXX)
print -r -- "Evidence: $cursor_output"
swift build --disable-sandbox
cursor_bin=$(swift build --show-bin-path)
cursor_objects=("$cursor_bin"/PaulNotchCore.build/*.swift.o)
cursor_objects=(${cursor_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$cursor_bin/Modules" \
  Tests/WindowValidation/CursorBrowserLaunchValidation.swift \
  "${cursor_objects[@]}" "$cursor_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$cursor_output/validate"
PAUL_PREVIEW_DIRECTORY="$cursor_output/workspace" "$cursor_output/validate"
