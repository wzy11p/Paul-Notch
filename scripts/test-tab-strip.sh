#!/bin/zsh
set -euo pipefail
tab_strip_root="${0:A:h:h}"
cd "$tab_strip_root"
tab_strip_output="$(mktemp -d /tmp/paul-tab-strip.XXXXXX)"
swiftc -module-cache-path "$tab_strip_root/.cache/clang" -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/ReorderableTabStrip.swift \
    Tests/IslandMemoTests/TabStripValidation.swift \
    -o "$tab_strip_output/TabStripValidation"
"$tab_strip_output/TabStripValidation" "$tab_strip_output"
print -r -- "Synthetic native snapshots retained at: $tab_strip_output"
