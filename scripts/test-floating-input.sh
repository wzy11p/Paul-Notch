#!/bin/zsh
set -euo pipefail
input_root="${0:A:h:h}"
cd "$input_root"
input_output=$(mktemp -d /tmp/paul-floating-input.XXXXXX)
print -r -- "Evidence: $input_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
input_bin=$(swift build -c release --show-bin-path)
input_objects=("$input_bin"/PaulNotchCore.build/*.swift.o)
input_objects=(${input_objects:#*/main.swift.o})
swiftc -O -swift-version 6 -parse-as-library -I "$input_bin/Modules" \
  Tests/WindowValidation/FloatingQuotaInputValidation.swift \
  "${input_objects[@]}" "$input_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$input_output/validate-input"
PAUL_PREVIEW_DIRECTORY="$input_output/workspace" "$input_output/validate-input"
