#!/bin/zsh
set -euo pipefail
ambient_root="${0:A:h:h}"
cd "$ambient_root"
export CLANG_MODULE_CACHE_PATH="$ambient_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
ambient_output=$(mktemp -d /tmp/paul-ambient-environment.XXXXXX)
print -r -- "Isolated ambient regression: $ambient_output"
swift build --disable-sandbox
ambient_bin=$(swift build --disable-sandbox --show-bin-path)
ambient_objects=("$ambient_bin"/PaulNotchCore.build/*.swift.o)
ambient_objects=(${ambient_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -I "$ambient_bin/Modules" Tests/WindowValidation/AmbientEnvironmentValidation.swift \
  "${ambient_objects[@]}" "$ambient_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$ambient_output/AmbientEnvironmentValidation"
mkdir -p "$ambient_output/workspace"
PAUL_PREVIEW_DIRECTORY="$ambient_output/workspace" "$ambient_output/AmbientEnvironmentValidation" \
  2>&1 | tee "$ambient_output/result.log"
# AppKit can terminate a restricted process with exit 0 during status-item setup.
# A missing completion marker is blocked, never a passing regression.
if ! grep -q '^PASS: ambient environment regression complete' "$ambient_output/result.log"; then
  print -u2 -- 'BLOCKED: native assertions did not complete'
  exit 2
fi
