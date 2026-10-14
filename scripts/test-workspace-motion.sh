#!/bin/zsh
set -euo pipefail
motion_root="${0:A:h:h}"
cd "$motion_root"
motion_output=$(mktemp -d /tmp/paul-workspace-motion.XXXXXX)
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
motion_bin=$(swift build -c release --show-bin-path)
motion_objects=("$motion_bin"/PaulNotchCore.build/*.swift.o)
motion_objects=(${motion_objects:#*/main.swift.o})
swiftc -O -swift-version 6 -parse-as-library -I "$motion_bin/Modules" \
  Tests/WindowValidation/WorkspaceMotionValidation.swift "${motion_objects[@]}" \
  "$motion_bin"/LunarSwift.build/*.swift.o -lsqlite3 \
  -o "$motion_output/WorkspaceMotionValidation"
"$motion_output/WorkspaceMotionValidation"
print -r -- "Validation: $motion_output"
