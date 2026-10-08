#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
quota_output=$(mktemp -d /tmp/paul-self-service.XXXXXX)
print -r -- "Evidence: $quota_output"
swift build --disable-sandbox
quota_bin=$(swift build --show-bin-path)
quota_objects=("$quota_bin"/PaulNotchCore.build/*.swift.o)
quota_objects=(${quota_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$quota_bin/Modules" \
  Tests/WindowValidation/QuotaSelfServiceUIValidation.swift \
  "${quota_objects[@]}" "$quota_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$quota_output/validate"
PAUL_PREVIEW_DIRECTORY="$quota_output/workspace" "$quota_output/validate" "$quota_output"
