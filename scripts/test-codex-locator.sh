#!/bin/zsh
set -euo pipefail
locator_root="${0:A:h:h}"
cd "$locator_root"
locator_output=$(mktemp -d /tmp/paul-codex-locator.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/CodexStatusModels.swift Sources/PaulNotchCore/CodexStatusClient.swift \
  Tests/IslandMemoTests/CodexExecutableLocatorValidation.swift -o "$locator_output/validate"
"$locator_output/validate"
if [[ "${1:-}" == "--live" ]]; then
  swiftc -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/CodexStatusModels.swift Sources/PaulNotchCore/CodexStatusClient.swift \
    Tests/IslandMemoTests/CodexQuotaLiveValidation.swift -o "$locator_output/live"
  "$locator_output/live"
fi
print -r -- "Evidence: $locator_output"
