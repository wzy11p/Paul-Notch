#!/bin/zsh
set -euo pipefail
website_root="${0:A:h:h}"
cd "$website_root"
website_output=$(mktemp -d /tmp/paul-website-quota.XXXXXX)
print -r -- "Evidence: $website_output"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaOverviewPresentation.swift \
  Sources/PaulNotchCore/QuotaConnectionModels.swift Sources/PaulNotchCore/WebsiteQuotaModels.swift \
  Tests/QuotaOverview/WebsiteQuotaValidation.swift -o "$website_output/validate"
"$website_output/validate"
