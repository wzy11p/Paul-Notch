#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
quota_output=$(mktemp -d /tmp/paul-custom-quota.XXXXXX)
print -r -- "Evidence: $quota_output"
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/CustomQuotaModels.swift \
  Sources/PaulNotchCore/CustomQuotaHTTPClient.swift Sources/PaulNotchCore/QuotaHTTPClient.swift \
  Sources/PaulNotchCore/QuotaConnectionModels.swift \
  Tests/QuotaOverview/CustomQuotaModelValidation.swift -o "$quota_output/model"
"$quota_output/model"
swift build --disable-sandbox
quota_bin=$(swift build --show-bin-path)
quota_objects=("$quota_bin"/PaulNotchCore.build/*.swift.o)
quota_objects=(${quota_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$quota_bin/Modules" \
  Tests/QuotaOverview/CustomQuotaLifecycleValidation.swift \
  "${quota_objects[@]}" "$quota_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$quota_output/lifecycle"
PAUL_PREVIEW_DIRECTORY="$quota_output/workspace" "$quota_output/lifecycle"
