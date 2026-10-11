#!/bin/zsh
set -euo pipefail
custom_root="${0:A:h:h}"
cd "$custom_root"
custom_output=$(mktemp -d /tmp/paul-public-custom.XXXXXX)
swiftc -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/CustomQuotaCredentialVault.swift \
  Sources/PaulNotchCore/QuotaCredentialAgentClient.swift \
  Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Tests/QuotaOverview/PublicCustomQuotaVaultValidation.swift -o "$custom_output/validate"
"$custom_output/validate"
