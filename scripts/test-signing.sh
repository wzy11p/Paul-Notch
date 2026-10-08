#!/bin/zsh
set -euo pipefail
signing_root="${0:A:h:h}"
zsh "$signing_root/scripts/sign-local-app.sh" --check
signing_test_dir="$(mktemp -d /private/tmp/paul-signing-validation.XXXXXX)"
print -r -- "Synthetic fixtures (not launched): $signing_test_dir"
for signing_version in A B; do
  signing_bundle="$signing_test_dir/$signing_version.app"
  mkdir -p "$signing_bundle/Contents/MacOS"
  cp "$signing_root/Tests/SigningValidation/Info.plist" "$signing_bundle/Contents/Info.plist"
  signing_defines=()
  if [[ "$signing_version" == B ]]; then signing_defines=(-DSECOND_BUILD); fi
  xcrun clang "${signing_defines[@]}" "$signing_root/Tests/SigningValidation/main.c" -o "$signing_bundle/Contents/MacOS/SigningValidation"
  zsh "$signing_root/scripts/sign-local-app.sh" "$signing_bundle"
  /usr/bin/codesign -d -r "$signing_test_dir/$signing_version.requirement" "$signing_bundle"
  /usr/bin/sed -i '' -e 's/^designated => //' "$signing_test_dir/$signing_version.requirement"
  test -s "$signing_test_dir/$signing_version.requirement"
done
if cmp -s "$signing_test_dir/A.app/Contents/MacOS/SigningValidation" "$signing_test_dir/B.app/Contents/MacOS/SigningValidation"; then
  print -u2 -- 'Fixture builds must differ.'
  exit 1
fi
cmp "$signing_test_dir/A.requirement" "$signing_test_dir/B.requirement"
/usr/bin/codesign --verify --strict -R "$signing_test_dir/A.requirement" "$signing_test_dir/B.app"
/usr/bin/codesign --verify --strict -R "$signing_test_dir/B.requirement" "$signing_test_dir/A.app"
print -r -- 'PASS: Different builds have identical certificate-backed requirements and satisfy each other. No TCC/GUI test implied.'
