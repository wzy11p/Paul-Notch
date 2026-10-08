#!/bin/zsh
set -euo pipefail
clipboard_root="${0:A:h:h}"
cd "$clipboard_root"
clipboard_output=$(mktemp -d /tmp/paul-clipboard-lifecycle.XXXXXX)
swiftc -module-cache-path "$clipboard_root/.cache/clang" -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/AppEnvironment.swift Sources/PaulNotchCore/AppSettingsStore.swift \
  Sources/PaulNotchCore/HomeLayoutEngine.swift Sources/PaulNotchCore/ShortcutSettings.swift \
  Sources/PaulNotchCore/TaskItem.swift Sources/PaulNotchCore/IslandTheme.swift \
  Sources/PaulNotchCore/ClipboardEntry.swift Sources/PaulNotchCore/ClipboardStore.swift \
  Sources/PaulNotchCore/SensitivePasteboard.swift Sources/PaulNotchCore/ClipboardHistoryView.swift \
  Tests/IslandMemoTests/ClipboardLifecycleValidation.swift -o "$clipboard_output/ClipboardLifecycleValidation"
PAUL_PREVIEW_DIRECTORY="$clipboard_output" "$clipboard_output/ClipboardLifecycleValidation" prepare "$clipboard_output"
PAUL_PREVIEW_DIRECTORY="$clipboard_output" "$clipboard_output/ClipboardLifecycleValidation" restart "$clipboard_output"
print -r -- "Synthetic fixtures: $clipboard_output"
