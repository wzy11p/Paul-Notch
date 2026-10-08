#!/bin/zsh
set -euo pipefail
muse_root="${0:A:h:h}"
cd "$muse_root"
muse_output=$(mktemp -d /tmp/paul-muse-lifecycle.XXXXXX)
print -r -- "Evidence: $muse_output"
swift build --disable-sandbox
muse_bin=$(swift build --show-bin-path)
muse_objects=("$muse_bin"/PaulNotchCore.build/*.swift.o)
muse_objects=(${muse_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$muse_bin/Modules" \
  Tests/WindowValidation/MuseQuotaLifecycleValidation.swift \
  "${muse_objects[@]}" "$muse_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$muse_output/validate"
PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/validate"
swiftc -swift-version 6 -parse-as-library -I "$muse_bin/Modules" \
  Tests/WindowValidation/WebsiteQuotaPersistenceValidation.swift \
  "${muse_objects[@]}" "$muse_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$muse_output/persistence"
muse_profile=$(/usr/bin/uuidgen)
trap 'PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/persistence" delete "$muse_profile" muse >/dev/null 2>&1 || true' EXIT
PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/persistence" write "$muse_profile" muse
PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/persistence" read "$muse_profile" muse
PAUL_PREVIEW_DIRECTORY="$muse_output/workspace" "$muse_output/persistence" delete "$muse_profile" muse
trap - EXIT
