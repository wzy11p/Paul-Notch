#!/bin/zsh
set -euo pipefail
connection_root="${0:A:h:h}"
cd "$connection_root"
connection_output=$(mktemp -d /tmp/paul-cursor-connection.XXXXXX)
print -r -- "Evidence: $connection_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
connection_bin=$(swift build -c release --show-bin-path)
connection_objects=("$connection_bin"/PaulNotchCore.build/*.swift.o)
connection_objects=(${connection_objects:#*/main.swift.o})
swiftc -O -swift-version 6 -parse-as-library -I "$connection_bin/Modules" \
  Tests/WindowValidation/CursorConnectionNativeValidation.swift \
  "${connection_objects[@]}" "$connection_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$connection_output/validate"
PAUL_PREVIEW_DIRECTORY="$connection_output/workspace" "$connection_output/validate"
