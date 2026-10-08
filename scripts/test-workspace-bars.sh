#!/bin/zsh
set -euo pipefail
workspace_bars_root="${0:A:h:h}"
cd "$workspace_bars_root"
workspace_bars_output="$(mktemp -d /tmp/paul-workspace-bars.XXXXXX)"
swiftc -module-cache-path "$workspace_bars_output/module-cache" -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/AppEnvironment.swift \
    Sources/PaulNotchCore/AppSettingsStore.swift \
    Sources/PaulNotchCore/HomeLayoutEngine.swift \
    Sources/PaulNotchCore/ShortcutSettings.swift \
    Sources/PaulNotchCore/TaskItem.swift \
    Tests/IslandMemoTests/WorkspaceBarSettingsValidation.swift \
    -o "$workspace_bars_output/WorkspaceBarSettingsValidation"
PAUL_PREVIEW_DIRECTORY="$workspace_bars_output" \
    "$workspace_bars_output/WorkspaceBarSettingsValidation" prepare "$workspace_bars_output"
PAUL_PREVIEW_DIRECTORY="$workspace_bars_output" \
    "$workspace_bars_output/WorkspaceBarSettingsValidation" restart "$workspace_bars_output"
print -r -- "Synthetic fixtures retained at: $workspace_bars_output"
