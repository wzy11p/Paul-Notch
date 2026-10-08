#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
quota_output=$(mktemp -d /tmp/paul-quota-keychain.XXXXXX)
print -r -- "Evidence: $quota_output"
quota_sources=(Sources/PaulNotchCore/QuotaConnectionModels.swift Sources/PaulNotchCore/QuotaConnectionsStore.swift
  Sources/PaulNotchCore/MiniMaxWalletStore.swift Sources/PaulNotchCore/MiniMaxWalletBalance.swift
  Sources/PaulNotchCore/QuotaHTTPClient.swift Sources/PaulNotchCore/QuotaOverviewPresentation.swift
  Sources/PaulNotchCore/DesktopQuotaModels.swift Sources/PaulNotchCore/DesktopQuotaStore.swift
  Sources/PaulNotchCore/CursorQuotaModels.swift Sources/PaulNotchCore/CursorQuotaAccountStore.swift
  Sources/PaulNotchCore/WebsiteQuotaModels.swift Sources/PaulNotchCore/WebsiteQuotaStore.swift Sources/PaulNotchCore/WebsiteQuotaBrowser.swift Sources/PaulNotchCore/MuseQuotaCapture.swift Sources/PaulNotchCore/MuseBackgroundLayout.swift
  Sources/PaulNotchCore/QuotaInteractiveWebView.swift)
swiftc -swift-version 6 -parse-as-library $quota_sources Sources/PaulNotchCore/QuotaCredentialVault.swift Sources/PaulNotchCore/QuotaCredentialAgentClient.swift \
  Tests/QuotaOverview/QuotaKeychainPromptValidation.swift -o "$quota_output/prompt-policy"
swiftc -swift-version 6 -parse-as-library $quota_sources \
  Tests/QuotaOverview/QuotaCredentialRetryValidation.swift -o "$quota_output/retry-policy"
quota_failed=0
"$quota_output/prompt-policy" || quota_failed=1
"$quota_output/retry-policy" || quota_failed=1
exit "$quota_failed"
