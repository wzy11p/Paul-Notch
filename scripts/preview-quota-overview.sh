#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
quota_preview=$(mktemp -d /tmp/paul-quota-preview.XXXXXX)
quota_app="$quota_preview/PaulQuotaPreview.app"
mkdir -p "$quota_app/Contents/MacOS" "$quota_app/Contents/Resources"
swiftc -swift-version 6 -parse-as-library \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewPresentation.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaOverviewView.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaCardOrder.swift" \
  "$quota_root/Sources/PaulNotchCore/QuotaReorderableGrid.swift" \
  "$quota_root/Sources/PaulNotchCore/ProviderBrandAssets.swift" \
  "$quota_root/Sources/PaulNotchCore/PaulBrand.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewFixtures.swift" \
  "$quota_root/Tests/QuotaOverview/QuotaOverviewPreview.swift" \
  -o "$quota_app/Contents/MacOS/PaulQuotaPreview"
cp "$quota_root/Tests/QuotaOverview/Info.plist" "$quota_app/Contents/Info.plist"
cp "$quota_root/Resources/PaulNotch.icns" "$quota_app/Contents/Resources/PaulNotch.icns"
ditto "$quota_root/Resources/ProviderLogos" "$quota_app/Contents/Resources/ProviderLogos"
zsh "$quota_root/scripts/sign-local-app.sh" "$quota_app"
print -r -- "Isolated preview: $quota_app"
# No app stores, live integrations, login service, or personal preference suite are linked.
exec "$quota_app/Contents/MacOS/PaulQuotaPreview"
