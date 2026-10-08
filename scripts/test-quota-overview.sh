#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
quota_output=$(mktemp -d /tmp/paul-quota-overview.XXXXXX)
print -r -- "Evidence: $quota_output"
swiftc -swift-version 6 -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewPresentation.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewFixtures.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewModelValidation.swift" \
  -o "$quota_output/validate-model"
"$quota_output/validate-model"
swiftc -swift-version 6 -D DEBUG -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewPresentation.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewView.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaCardOrder.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaReorderableGrid.swift" \
  "$quota_root/Sources/PaulNotchCore/ProviderBrandAssets.swift" \
  "$quota_root/Sources/PaulNotchCore/PaulBrand.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewFixtures.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewUIValidation.swift" \
  -o "$quota_output/validate-ui"
"$quota_output/validate-ui" "$quota_output"
print -r -- "Evidence: $quota_output"
