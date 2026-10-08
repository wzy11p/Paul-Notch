#!/bin/zsh
set -euo pipefail
website_root="${0:A:h:h}"
cd "$website_root"
website_output=$(mktemp -d /tmp/paul-website-persistence.XXXXXX)
print -r -- "Evidence: $website_output"
swift build --disable-sandbox
website_bin=$(swift build --show-bin-path)
website_objects=("$website_bin"/PaulNotchCore.build/*.swift.o)
website_objects=(${website_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$website_bin/Modules" \
  Tests/WindowValidation/WebsiteQuotaPersistenceValidation.swift \
  "${website_objects[@]}" "$website_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$website_output/validate"
PAUL_PREVIEW_DIRECTORY="$website_output/workspace" "$website_output/validate"
website_profile=$(/usr/bin/uuidgen)
trap 'PAUL_PREVIEW_DIRECTORY="$website_output/workspace" "$website_output/validate" delete "$website_profile" >/dev/null 2>&1 || true' EXIT
PAUL_PREVIEW_DIRECTORY="$website_output/workspace" "$website_output/validate" write "$website_profile"
PAUL_PREVIEW_DIRECTORY="$website_output/workspace" "$website_output/validate" read "$website_profile"
PAUL_PREVIEW_DIRECTORY="$website_output/workspace" "$website_output/validate" delete "$website_profile"
trap - EXIT
