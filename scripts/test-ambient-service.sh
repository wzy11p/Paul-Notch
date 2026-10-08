#!/bin/zsh
set -euo pipefail
ambient_root="${0:A:h:h}"
cd "$ambient_root"
ambient_output=$(mktemp -d /tmp/paul-ambient-service.XXXXXX)
swift build --disable-sandbox
ambient_bin=$(swift build --disable-sandbox --show-bin-path)
ambient_objects=("$ambient_bin"/PaulNotchCore.build/*.swift.o)
ambient_objects=(${ambient_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$ambient_bin/Modules" \
  Tests/QuotaOverview/AmbientServiceValidation.swift \
  "${ambient_objects[@]}" "$ambient_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$ambient_output/AmbientServiceValidation"
PAUL_PREVIEW_DIRECTORY="$ambient_output" "$ambient_output/AmbientServiceValidation"
swiftc -swift-version 6 -parse-as-library -I "$ambient_bin/Modules" \
  Tests/QuotaOverview/AmbientConnectedValidation.swift \
  "${ambient_objects[@]}" "$ambient_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$ambient_output/AmbientConnectedValidation"
PAUL_PREVIEW_DIRECTORY="$ambient_output" "$ambient_output/AmbientConnectedValidation" "$ambient_output"
print -r -- "Isolated service evidence: $ambient_output"
