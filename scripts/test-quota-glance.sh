#!/bin/zsh
set -euo pipefail
glance_root="${0:A:h:h}"
cd "$glance_root"
glance_output=$(mktemp -d /tmp/paul-quota-glance.XXXXXX)
print -r -- "Evidence: $glance_output"
ditto Resources/ProviderLogos "$glance_output/ProviderLogos"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
glance_bin=$(swift build -c release --show-bin-path)
glance_objects=("$glance_bin"/PaulNotchCore.build/*.swift.o)
glance_objects=(${glance_objects:#*/main.swift.o})
swiftc -O -swift-version 6 -parse-as-library -I "$glance_bin/Modules" \
  Tests/QuotaOverview/QuotaGlanceValidation.swift Tests/QuotaOverview/QuotaGlancePreview.swift \
  "${glance_objects[@]}" "$glance_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$glance_output/validate-glance"
PAUL_PREVIEW_DIRECTORY="$glance_output/workspace" PAUL_GLANCE_EVIDENCE="$glance_output" "$glance_output/validate-glance"
