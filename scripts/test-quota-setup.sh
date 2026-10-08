#!/bin/zsh
set -euo pipefail
setup_root="${0:A:h:h}"
cd "$setup_root"
setup_output=$(mktemp -d /tmp/paul-quota-setup.XXXXXX)
print -r -- "Evidence: $setup_output"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Sources/PaulNotchCore/QuotaSetupProvider.swift Tests/QuotaOverview/QuotaSetupSafetyValidation.swift \
  -o "$setup_output/validate"
"$setup_output/validate"
