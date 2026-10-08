#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
mode="${1:-}"
identity="${2:-}"

if [[ "$mode" != "--adhoc" && "$mode" != "--identity" ]]; then
  print -u2 'Usage: zsh scripts/build-app.sh --adhoc | --identity "Apple Development: Name (TEAMID)"'
  exit 64
fi
if [[ "$mode" == "--identity" && -z "$identity" ]]; then
  print -u2 'A signing identity is required after --identity.'
  exit 64
fi

cd "$root_dir"
swift build -c release

app_dir="$root_dir/dist/Paul Notch.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$root_dir/.build/release/PaulNotch" "$app_dir/Contents/MacOS/PaulNotch"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$root_dir/Resources/PkgInfo" "$app_dir/Contents/PkgInfo"
cp "$root_dir/Resources/PaulNotch.icns" "$app_dir/Contents/Resources/PaulNotch.icns"
ditto "$root_dir/Resources/ProviderLogos" "$app_dir/Contents/Resources/ProviderLogos"
cp "$root_dir/LICENSE" "$root_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"

if [[ "$mode" == "--adhoc" ]]; then
  /usr/bin/codesign --force --deep --sign - "$app_dir"
  print -u2 'Warning: ad-hoc signatures are for local testing; permissions may need to be granted again after rebuilding.'
else
  /usr/bin/codesign --force --deep --timestamp=none --sign "$identity" "$app_dir"
fi

/usr/bin/codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"
