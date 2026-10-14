#!/bin/zsh
set -euo pipefail
glass_root="${0:A:h:h}"
cd "$glass_root"
glass_output=$(mktemp -d /tmp/paul-glass-return.XXXXXX)
print -r -- "Evidence: $glass_output"
swift build --disable-sandbox --product PaulNotch
glass_bin=$(swift build --show-bin-path)
glass_objects=("$glass_bin"/PaulNotchCore.build/*.swift.o)
glass_objects=(${glass_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$glass_bin/Modules" \
  Tests/WindowValidation/QuotaGlassReturnValidation.swift \
  "${glass_objects[@]}" "$glass_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$glass_output/validate-glass-return"
PAUL_PREVIEW_DIRECTORY="$glass_output/workspace" "$glass_output/validate-glass-return" "$@"
