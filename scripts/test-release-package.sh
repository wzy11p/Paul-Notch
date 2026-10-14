#!/bin/zsh
set -euo pipefail
release_root="${0:A:h:h}"
release_app="${1:-$release_root/dist/Paul Notch.app}"
release_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$release_app/Contents/Info.plist")
release_original="$release_root/.build/release/$release_name"
release_binary="$release_app/Contents/MacOS/$release_name"
[[ -f "$release_original" && -f "$release_binary" ]]
release_before=$(stat -f %z "$release_original")
release_after=$(stat -f %z "$release_binary")
if (( release_after >= release_before )); then
  print -u2 'FAIL: package still contains all development symbol overhead'; exit 1
fi
# Re-signing alone can save a few bytes. Check the symbol table as well, so
# that a newly signed but unstripped executable cannot satisfy this test.
release_symbols=$(xcrun nm -m "$release_binary")
if print -r -- "$release_symbols" | awk '/non-external/ || !/external/ { found=1 } END { exit !found }'; then
  print -u2 'FAIL: package still contains local or debug symbols'; exit 1
fi
release_check=$(mktemp -d /tmp/paul-release-sections.XXXXXX)
swiftc "$release_root/Tests/SigningValidation/ReleaseSectionsValidation.swift" -o "$release_check/validate"
"$release_check/validate" "$release_original" "$release_binary"
diff -qr "$release_root/Resources/ProviderLogos" "$release_app/Contents/Resources/ProviderLogos"
cmp "$release_root/Resources/PaulNotch.icns" "$release_app/Contents/Resources/PaulNotch.icns"
cmp "$release_root/LICENSE" "$release_app/Contents/Resources/LICENSE"
cmp "$release_root/THIRD_PARTY_NOTICES.md" "$release_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --verify --deep --strict "$release_app"
print -r -- "PASS: release executable $release_before -> $release_after bytes; original artwork and valid signature preserved"
