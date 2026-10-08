#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
quota_output=$(mktemp -d /tmp/paul-quota-layout.XXXXXX)
swiftc -parse-as-library -swift-version 6 \
  "$quota_root/Sources/PaulNotchCore/AmbientQuotaLabel.swift" \
  "$quota_root/Tests/IslandMemoTests/AmbientQuotaLayoutValidation.swift" \
  -o "$quota_output/validate-quota"
"$quota_output/validate-quota" "$quota_output"
swiftc -parse-as-library -swift-version 6 \
  "$quota_root/Sources/PaulNotchCore/QuotaResetCountdown.swift" \
  "$quota_root/Tests/IslandMemoTests/QuotaResetCountdownValidation.swift" \
  -o "$quota_output/validate-countdown"
"$quota_output/validate-countdown"
