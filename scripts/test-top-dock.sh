#!/bin/zsh
set -euo pipefail
dock_root="${0:A:h:h}"
cd "$dock_root"
dock_output=$(mktemp -d /tmp/paul-top-dock.XXXXXX)
print -r -- "Evidence: $dock_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
dock_bin=$(swift build -c release --show-bin-path)
dock_objects=("$dock_bin"/PaulNotchCore.build/*.swift.o)
dock_objects=(${dock_objects:#*/main.swift.o})
dock_fixtures=(TopDockValidation)
if [[ "${1:-}" == --suite ]]; then
  dock_fixtures+=(AmbientEnvironmentValidation FloatingQuotaValidation QuotaGlassReturnValidation)
fi
for dock_fixture in "${dock_fixtures[@]}"; do
  swiftc -O -swift-version 6 -parse-as-library -I "$dock_bin/Modules" \
    "Tests/WindowValidation/$dock_fixture.swift" "${dock_objects[@]}" \
    "$dock_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$dock_output/$dock_fixture"
  PAUL_PREVIEW_DIRECTORY="$dock_output/$dock_fixture-workspace" \
    "$dock_output/$dock_fixture" "$dock_output" 2>&1 | tee "$dock_output/$dock_fixture.log"
  grep -q '^PASS:' "$dock_output/$dock_fixture.log"
done
if [[ "${1:-}" == --suite ]]; then
  for dock_mode in glass lifecycle; do
    PAUL_PREVIEW_DIRECTORY="$dock_output/$dock_mode-workspace" \
      "$dock_output/QuotaGlassReturnValidation" "--$dock_mode" 2>&1 | tee "$dock_output/$dock_mode.log"
    grep -q '^PASS:' "$dock_output/$dock_mode.log"
  done
fi
