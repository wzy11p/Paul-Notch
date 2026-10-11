#!/bin/zsh
set -euo pipefail
model_root="${0:A:h:h}"
cd "$model_root"
model_output=$(mktemp -d /tmp/paul-cursor-model.XXXXXX)
swift build --disable-sandbox
model_bin=$(swift build --disable-sandbox --show-bin-path)
model_objects=("$model_bin"/PaulNotchCore.build/*.swift.o)
model_objects=(${model_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$model_bin/Modules" \
  Tests/QuotaOverview/CursorModelContextValidation.swift \
  "${model_objects[@]}" "$model_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$model_output/CursorModelContextValidation"
PAUL_PREVIEW_DIRECTORY="$model_output" "$model_output/CursorModelContextValidation"
for model_test in CursorModelReaderValidation CursorModelMonitorValidation CursorWebContextValidation; do
  swiftc -swift-version 6 -parse-as-library -I "$model_bin/Modules" \
    "Tests/QuotaOverview/$model_test.swift" \
    "${model_objects[@]}" "$model_bin"/LunarSwift.build/*.swift.o \
    -lsqlite3 -o "$model_output/$model_test"
  PAUL_PREVIEW_DIRECTORY="$model_output" "$model_output/$model_test"
done
print -r -- "Isolated model-context evidence: $model_output"
