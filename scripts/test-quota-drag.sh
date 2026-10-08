#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
quota_output=$(mktemp -d /tmp/paul-quota-drag.XXXXXX)
print -r -- "Evidence: $quota_output"
swiftc -swift-version 6 -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaCardOrder.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaCardOrderValidation.swift" \
  -o "$quota_output/validate-order"
"$quota_output/validate-order"
swiftc -swift-version 6 -D DEBUG -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewPresentation.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewView.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaCardOrder.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaReorderableGrid.swift" \
  "$quota_root/Sources/PaulNotchCore/ProviderBrandAssets.swift" \
  "$quota_root/Sources/PaulNotchCore/PaulBrand.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewFixtures.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaGridDragValidation.swift" \
  -o "$quota_output/validate-drag"
"$quota_output/validate-drag"
