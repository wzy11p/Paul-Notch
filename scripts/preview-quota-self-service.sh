#!/bin/zsh
set -euo pipefail
quota_root="${0:A:h:h}"
cd "$quota_root"
swift build --disable-sandbox
quota_bin=$(swift build --show-bin-path)
quota_objects=("$quota_bin"/PaulNotchCore.build/*.swift.o)
quota_objects=(${quota_objects:#*/main.swift.o})
quota_output=$(mktemp -d /tmp/paul-self-service-preview.XXXXXX)
quota_app="$quota_output/PaulSelfServicePreview.app"
mkdir -p "$quota_app/Contents/MacOS" "$quota_app/Contents/Resources"
swiftc -swift-version 6 -parse-as-library -I "$quota_bin/Modules" \
  Tests/WindowValidation/QuotaSelfServicePreview.swift \
  "${quota_objects[@]}" "$quota_bin"/LunarSwift.build/*.swift.o \
  -lsqlite3 -o "$quota_app/Contents/MacOS/PaulQuotaPreview"
cp Tests/QuotaOverview/Info.plist "$quota_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PaulPreviewDataDirectory string $quota_output/workspace" "$quota_app/Contents/Info.plist"
cp Resources/PaulNotch.icns "$quota_app/Contents/Resources/PaulNotch.icns"
ditto Resources/ProviderLogos "$quota_app/Contents/Resources/ProviderLogos"
zsh scripts/sign-local-app.sh "$quota_app"
print -r -- "Isolated native acceptance app: $quota_app"
