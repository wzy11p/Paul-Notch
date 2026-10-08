#!/bin/zsh
set -euo pipefail
native_input_root="${0:A:h:h}"
cd "$native_input_root"
native_input_output=$(mktemp -d /tmp/paul-native-input.XXXXXX)
native_input_app="$native_input_output/Paul Input Check.app"
swift build --disable-sandbox
native_input_bin=$(swift build --show-bin-path)
native_input_objects=("$native_input_bin"/PaulNotchCore.build/*.swift.o)
native_input_objects=(${native_input_objects:#*/main.swift.o})
mkdir -p "$native_input_app/Contents/MacOS"
cp Tests/WindowValidation/QuotaNativeClickInfo.plist "$native_input_app/Contents/Info.plist"
swiftc -swift-version 6 -parse-as-library -I "$native_input_bin/Modules" \
  Tests/WindowValidation/QuotaNativeClickValidation.swift \
  "${native_input_objects[@]}" "$native_input_bin"/LunarSwift.build/*.swift.o -lsqlite3 \
  -o "$native_input_app/Contents/MacOS/QuotaNativeClickValidation"
print -r -- "Synthetic input app prepared: $native_input_app"
