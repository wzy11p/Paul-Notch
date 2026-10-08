#!/bin/zsh
set -euo pipefail
geometry_root="${0:A:h:h}"
cd "$geometry_root"
geometry_output=$(mktemp -d /tmp/paul-workspace-geometry.XXXXXX)
print -r -- "Evidence: $geometry_output"
swift build
geometry_bin=$(swift build --show-bin-path)
geometry_objects=("$geometry_bin"/PaulNotchCore.build/*.swift.o)
geometry_objects=(${geometry_objects:#*/main.swift.o})
for geometry_fixture in WorkspaceGeometryValidation QuotaWebsiteLayoutValidation; do
  swiftc -swift-version 6 -parse-as-library -I "$geometry_bin/Modules" \
    "Tests/WindowValidation/$geometry_fixture.swift" \
    "${geometry_objects[@]}" "$geometry_bin"/LunarSwift.build/*.swift.o \
    -lsqlite3 -o "$geometry_output/$geometry_fixture"
  PAUL_PREVIEW_DIRECTORY="$geometry_output/$geometry_fixture-data" "$geometry_output/$geometry_fixture"
done
