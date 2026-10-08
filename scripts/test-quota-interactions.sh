#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
export CLANG_MODULE_CACHE_PATH="$quota_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
quota_output="${1:-$quota_root/.build/quota-interactions}"
quota_stage="${2:-after}"
quota_workspace=$(mktemp -d /tmp/paul-quota-interaction.XXXXXX)
mkdir -p "$quota_output" "$quota_root/.build/quota-interactions"
swift build --disable-sandbox
quota_bin=$(swift build --disable-sandbox --show-bin-path)
quota_objects=("$quota_bin"/PaulNotchCore.build/*.swift.o)
quota_objects=(${quota_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$quota_bin/Modules" \
  Tests/QuotaOverview/QuotaInteractionValidation.swift \
  "${quota_objects[@]}" "$quota_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$quota_root/.build/quota-interactions/validate-interactions"
PAUL_PREVIEW_DIRECTORY="$quota_workspace" "$quota_root/.build/quota-interactions/validate-interactions" "$quota_output" "$quota_stage"
