#!/bin/zsh
set -euo pipefail
motion_root="${0:A:h:h}"
cd "$motion_root"
motion_output=$(mktemp -d /tmp/paul-workspace-motion.XXXXXX)
swiftc -swift-version 6 -parse-as-library -module-cache-path "$motion_root/.cache/clang" \
  Sources/PaulNotchCore/WorkspacePanelMotion.swift Tests/WindowValidation/WorkspaceMotionValidation.swift \
  -o "$motion_output/WorkspaceMotionValidation"
"$motion_output/WorkspaceMotionValidation"
print -r -- "Validation: $motion_output"
