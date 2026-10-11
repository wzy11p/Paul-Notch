#!/bin/zsh
set -euo pipefail
recovery_root="${0:A:h:h}"
cd "$recovery_root"
recovery_output=$(mktemp -d /tmp/paul-codex-recovery.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/CodexStatusModels.swift Sources/PaulNotchCore/CodexStatusClient.swift \
  Tests/IslandMemoTests/CodexClientRecoveryValidation.swift -o "$recovery_output/validate"
"$recovery_output/validate"
print -r -- "Evidence: $recovery_output"
