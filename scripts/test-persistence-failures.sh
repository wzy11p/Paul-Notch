#!/bin/zsh
set -euo pipefail
persistence_root="${0:A:h:h}"
cd "$persistence_root"
persistence_output=$(mktemp -d /tmp/paul-persistence-failures.XXXXXX)
trap 'rm -f "$persistence_output/PersistenceFailureValidation"' EXIT
swift build
persistence_bin=$(swift build --show-bin-path)
if [[ -d Sources/PaulNotchCore ]]; then
  persistence_objects=("$persistence_bin"/PaulNotchCore.build/*.swift.o)
else
  persistence_objects=("$persistence_bin"/PaulNotchCore.build/*.swift.o)
  persistence_objects=(${persistence_objects:#*/main.swift.o})
fi
swiftc -swift-version 6 -parse-as-library -I "$persistence_bin/Modules" \
  Tests/WindowValidation/PersistenceFailureValidation.swift \
  "${persistence_objects[@]}" "$persistence_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$persistence_output/PersistenceFailureValidation"
PAUL_PREVIEW_DIRECTORY="$persistence_output" "$persistence_output/PersistenceFailureValidation"
print -r -- "Synthetic failure fixtures: $persistence_output"
