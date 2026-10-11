#!/bin/zsh
set -euo pipefail
adaptive_root="${0:A:h:h}"
cd "$adaptive_root"
adaptive_output=$(mktemp -d /tmp/paul-quota-adaptive.XXXXXX)
print -r -- "Evidence: $adaptive_output"
swift build --disable-sandbox
adaptive_bin=$(swift build --show-bin-path)
adaptive_objects=("$adaptive_bin"/PaulNotchCore.build/*.swift.o)
adaptive_objects=(${adaptive_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$adaptive_bin/Modules" \
  Tests/WindowValidation/QuotaAdaptiveLayoutValidation.swift \
  "${adaptive_objects[@]}" "$adaptive_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$adaptive_output/validate-adaptive"
PAUL_PREVIEW_DIRECTORY="$adaptive_output/data" "$adaptive_output/validate-adaptive"
