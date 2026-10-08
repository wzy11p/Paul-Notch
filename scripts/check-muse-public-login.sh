#!/bin/zsh
set -euo pipefail
muse_root="${0:A:h:h}"
cd "$muse_root"
muse_output=$(mktemp -d /tmp/paul-muse-public-login.XXXXXX)
print -r -- "Anonymous login evidence: $muse_output"
swift build --disable-sandbox
muse_bin=$(swift build --show-bin-path)
muse_objects=("$muse_bin"/PaulNotchCore.build/*.swift.o)
muse_objects=(${muse_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$muse_bin/Modules" \
  Tests/WindowValidation/MusePublicLoginValidation.swift \
  "${muse_objects[@]}" "$muse_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$muse_output/validate"
PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/validate" "$muse_output/anonymous-login.png"
