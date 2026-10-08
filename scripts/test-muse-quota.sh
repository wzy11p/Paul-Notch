#!/bin/zsh
set -euo pipefail
muse_root="${0:A:h:h}"
cd "$muse_root"
muse_output=$(mktemp -d /tmp/paul-muse-quota.XXXXXX)
print -r -- "Evidence: $muse_output"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaOverviewPresentation.swift \
  Sources/PaulNotchCore/QuotaConnectionModels.swift Sources/PaulNotchCore/WebsiteQuotaModels.swift \
  Tests/QuotaOverview/MuseQuotaValidation.swift -o "$muse_output/validate"
"$muse_output/validate"
