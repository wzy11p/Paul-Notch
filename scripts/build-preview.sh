#!/bin/zsh
set -euo pipefail

# Build an isolated debug app. Live Codex reads are a separate launch opt-in.
preview_root="${0:A:h:h}"
cd "$preview_root"
zsh "$preview_root/scripts/sign-local-app.sh" --check
CLANG_MODULE_CACHE_PATH="$preview_root/.cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$preview_root/.cache/swiftmodules" \
swift build --disable-sandbox --cache-path .cache/swiftpm --config-path .cache/config --security-path .cache/security
preview_dir="$(mktemp -d /tmp/paul-task-home.XXXXXX)"
preview_app="$preview_dir/PaulHomePreview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
cp .build/debug/PaulNotch "$preview_app/Contents/MacOS/PaulNotch"
cp Resources/Info.plist "$preview_app/Contents/Info.plist"
cp Resources/PkgInfo "$preview_app/Contents/PkgInfo"
cp Resources/PaulNotch.icns "$preview_app/Contents/Resources/PaulNotch.icns"
ditto Resources/ProviderLogos "$preview_app/Contents/Resources/ProviderLogos"
cp LICENSE THIRD_PARTY_NOTICES.md "$preview_app/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.paul.home-preview" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Paul Notch Preview" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Paul Notch Preview" "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PaulPreviewDataDirectory string $preview_dir" "$preview_app/Contents/Info.plist"
zsh "$preview_root/scripts/sign-local-app.sh" "$preview_app"
print -r -- "$preview_app"
print -r -- "Launch with: open '$preview_app' --args --memo-ui-preview '$preview_dir'"
