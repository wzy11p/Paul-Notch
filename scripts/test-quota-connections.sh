#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
quota_output=$(mktemp -d /tmp/paul-quota-connections.XXXXXX)
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Tests/QuotaOverview/QuotaConnectionsValidation.swift -o "$quota_output/validate"
"$quota_output/validate"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Sources/PaulNotchCore/QuotaHTTPClient.swift Sources/PaulNotchCore/QuotaConnectionsStore.swift \
  Sources/PaulNotchCore/MiniMaxWalletBalance.swift Sources/PaulNotchCore/MiniMaxWalletStore.swift \
  Sources/PaulNotchCore/QuotaOverviewPresentation.swift \
  Sources/PaulNotchCore/DesktopQuotaModels.swift Sources/PaulNotchCore/DesktopQuotaStore.swift \
  Sources/PaulNotchCore/CursorQuotaModels.swift Sources/PaulNotchCore/CursorQuotaAccountStore.swift \
  Sources/PaulNotchCore/WebsiteQuotaModels.swift Sources/PaulNotchCore/WebsiteQuotaStore.swift Sources/PaulNotchCore/WebsiteQuotaBrowser.swift Sources/PaulNotchCore/MuseQuotaCapture.swift Sources/PaulNotchCore/MuseBackgroundLayout.swift Sources/PaulNotchCore/QuotaInteractiveWebView.swift \
  Tests/QuotaOverview/QuotaConnectionLifecycleValidation.swift -o "$quota_output/lifecycle"
"$quota_output/lifecycle"
print -r -- "Evidence: $quota_output"
