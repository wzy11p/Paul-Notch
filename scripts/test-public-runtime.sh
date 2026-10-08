#!/bin/zsh
set -euo pipefail
public_runtime_root="${0:A:h:h}"
cd "$public_runtime_root"
public_runtime_output=$(mktemp -d /tmp/paul-public-runtime.XXXXXX)
swiftc -swift-version 6 -parse-as-library Sources/PaulNotchCore/AppEnvironment.swift \
  Tests/WindowValidation/PublicRuntimeValidation.swift -o "$public_runtime_output/validate"
env -u PAUL_PREVIEW_DIRECTORY "$public_runtime_output/validate"
PAUL_PREVIEW_DIRECTORY="$public_runtime_output" "$public_runtime_output/validate"
