#!/bin/zsh
set -euo pipefail
orb_root="${0:A:h:h}"
cd "$orb_root"
orb_output=$(mktemp -d /tmp/paul-quota-orb.XXXXXX)
print -r -- "Evidence: $orb_output"
swift build --disable-sandbox
orb_bin=$(swift build --disable-sandbox --show-bin-path)
orb_objects=("$orb_bin"/PaulNotchCore.build/*.swift.o)
orb_objects=(${orb_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$orb_bin/Modules" \
  Tests/WindowValidation/QuotaLiquidOrbValidation.swift \
  "${orb_objects[@]}" "$orb_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$orb_output/validate-orb"
PAUL_PREVIEW_DIRECTORY="$orb_output/workspace" PAUL_ORB_EVIDENCE="$orb_output" "$orb_output/validate-orb"
