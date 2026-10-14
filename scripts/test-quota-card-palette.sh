#!/bin/zsh
set -euo pipefail
palette_root="${0:A:h:h}"
cd "$palette_root"
palette_output=$(mktemp -d /tmp/paul-card-palette.XXXXXX)
print -r -- "Evidence: $palette_output"
swift build -c release --disable-sandbox --product PaulNotch -Xswiftc -enable-testing \
  -Xswiftc -no-whole-module-optimization -j 2
palette_bin=$(swift build -c release --show-bin-path)
palette_objects=("$palette_bin"/PaulNotchCore.build/*.swift.o)
palette_objects=(${palette_objects:#*/main.swift.o})
palette_app="$palette_output/CardPaletteValidation.app"
mkdir -p "$palette_app/Contents/MacOS" "$palette_app/Contents/Resources"
cp Tests/QuotaOverview/Info.plist "$palette_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CardPaletteValidation' "$palette_app/Contents/Info.plist"
ditto Resources/ProviderLogos "$palette_app/Contents/Resources/ProviderLogos"
swiftc -O -swift-version 6 -parse-as-library -I "$palette_bin/Modules" \
  Tests/WindowValidation/QuotaCardPaletteValidation.swift "${palette_objects[@]}" \
  "$palette_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$palette_app/Contents/MacOS/CardPaletteValidation"
zsh scripts/sign-local-app.sh "$palette_app"
PAUL_PREVIEW_DIRECTORY="$palette_output/workspace" \
  "$palette_app/Contents/MacOS/CardPaletteValidation" "$palette_output" 2>&1 | tee "$palette_output/result.log"
grep -q '^PASS:' "$palette_output/result.log"
