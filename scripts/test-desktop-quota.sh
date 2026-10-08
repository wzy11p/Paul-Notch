#!/bin/zsh
set -euo pipefail
desktop_root="${0:A:h:h}"
desktop_output=$(mktemp -d /tmp/paul-desktop-quota.XXXXXX)
print -r -- "Evidence: $desktop_output"
swiftc -swift-version 6 -parse-as-library "$desktop_root/Sources/PaulNotchCore/DesktopQuotaModels.swift" \
  "$desktop_root/Tests/QuotaOverview/DesktopQuotaValidation.swift" -o "$desktop_output/validate-model"
"$desktop_output/validate-model"
swiftc -swift-version 6 -parse-as-library "$desktop_root/Sources/PaulNotchCore/DesktopQuotaModels.swift" \
  "$desktop_root/Sources/PaulNotchCore/DesktopQuotaStore.swift" \
  "$desktop_root/Sources/PaulNotchCore/QuotaOverviewPresentation.swift" \
  "$desktop_root/Tests/QuotaOverview/DesktopQuotaStoreValidation.swift" -o "$desktop_output/validate-store"
"$desktop_output/validate-store"
