#!/bin/zsh
set -euo pipefail
floating_root="${0:A:h:h}"
cd "$floating_root"
floating_output=$(mktemp -d /tmp/paul-floating-quota.XXXXXX)
print -r -- "Evidence: $floating_output"
swift build --disable-sandbox
floating_bin=$(swift build --show-bin-path)
floating_objects=("$floating_bin"/PaulNotchCore.build/*.swift.o)
floating_objects=(${floating_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$floating_bin/Modules" \
  Tests/WindowValidation/FloatingQuotaValidation.swift \
  "${floating_objects[@]}" "$floating_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$floating_output/validate-floating-quota"
PAUL_PREVIEW_DIRECTORY="$floating_output/workspace" "$floating_output/validate-floating-quota"
