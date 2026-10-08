#!/bin/zsh
set -euo pipefail
feed_root="${0:A:h:h}"
cd "$feed_root"
feed_output=$(mktemp -d /tmp/paul-feed-layout.XXXXXX)
swift build --disable-sandbox
feed_bin=$(swift build --show-bin-path)
feed_objects=("$feed_bin"/PaulNotchCore.build/*.swift.o)
feed_objects=(${feed_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$feed_bin/Modules" \
  Tests/WindowValidation/QuotaFeedLayoutValidation.swift \
  "${feed_objects[@]}" "$feed_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$feed_output/validate"
PAUL_PREVIEW_DIRECTORY="$feed_output" "$feed_output/validate"
print -r -- "Evidence: $feed_output"
