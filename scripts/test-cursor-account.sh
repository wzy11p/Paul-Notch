#!/bin/zsh
set -euo pipefail
cursor_root="${0:A:h:h}"
cd "$cursor_root"
cursor_output=$(mktemp -d /tmp/paul-cursor-account.XXXXXX)
print -r -- "Evidence: $cursor_output"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Sources/PaulNotchCore/QuotaHTTPClient.swift Sources/PaulNotchCore/QuotaConnectionsStore.swift \
  Sources/PaulNotchCore/MiniMaxWalletBalance.swift Sources/PaulNotchCore/MiniMaxWalletStore.swift \
  Sources/PaulNotchCore/DesktopQuotaModels.swift Sources/PaulNotchCore/DesktopQuotaStore.swift \
  Sources/PaulNotchCore/QuotaOverviewPresentation.swift Sources/PaulNotchCore/CursorQuotaModels.swift \
  Sources/PaulNotchCore/CursorQuotaAccountStore.swift Sources/PaulNotchCore/WebsiteQuotaModels.swift \
  Sources/PaulNotchCore/WebsiteQuotaStore.swift Sources/PaulNotchCore/WebsiteQuotaBrowser.swift Sources/PaulNotchCore/MuseQuotaCapture.swift Sources/PaulNotchCore/MuseBackgroundLayout.swift Sources/PaulNotchCore/QuotaInteractiveWebView.swift \
  Tests/QuotaOverview/CursorAccountValidation.swift \
  -o "$cursor_output/validate"
"$cursor_output/validate"
