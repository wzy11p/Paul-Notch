#!/bin/zsh
set -euo pipefail
workspace_root="${0:A:h:h}"
cd "$workspace_root"
workspace_output=$(mktemp -d /tmp/paul-workspace-window.XXXXXX)
trap 'rm -f "$workspace_output/WorkspaceWindowValidation"' EXIT
swift build
workspace_bin=$(swift build --show-bin-path)
if [[ -d Sources/PaulNotchCore ]]; then
  workspace_objects=("$workspace_bin"/PaulNotchCore.build/*.swift.o)
else
  workspace_objects=("$workspace_bin"/PaulNotchCore.build/*.swift.o)
  workspace_objects=(${workspace_objects:#*/main.swift.o})
fi
swiftc -swift-version 6 -parse-as-library -I "$workspace_bin/Modules" \
  Tests/WindowValidation/WorkspaceWindowValidation.swift \
  "${workspace_objects[@]}" "$workspace_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$workspace_output/WorkspaceWindowValidation"
PAUL_PREVIEW_DIRECTORY="$workspace_output" "$workspace_output/WorkspaceWindowValidation"
print -r -- "Isolated window fixtures: $workspace_output"
