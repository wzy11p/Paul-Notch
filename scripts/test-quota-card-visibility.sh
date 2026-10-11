#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
quota_output=$(mktemp -d /tmp/paul-quota-visibility.XXXXXX)
quota_suite="local.paul.visibility-tests.$(uuidgen)"
print -r -- "Evidence: $quota_output"
swiftc -swift-version 6 -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaCardOrder.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaCardVisibilityValidation.swift" \
  -o "$quota_output/validate-visibility"
"$quota_output/validate-visibility" "$quota_suite" write
"$quota_output/validate-visibility" "$quota_suite" read
