#!/bin/zsh
set -euo pipefail
focus_root="${0:A:h:h}"
cd "$focus_root"
focus_output=$(mktemp -d /tmp/paul-quota-input-focus.XXXXXX)
print -r -- "Evidence: $focus_output"
swift build --disable-sandbox
focus_bin=$(swift build --show-bin-path)
focus_objects=("$focus_bin"/PaulNotchCore.build/*.swift.o)
focus_objects=(${focus_objects:#*/main.swift.o})
swiftc -swift-version 6 -parse-as-library -I "$focus_bin/Modules" \
  Tests/WindowValidation/QuotaInputFocusValidation.swift \
  "${focus_objects[@]}" "$focus_bin"/LunarSwift.build/*.swift.o -lsqlite3 -o "$focus_output/validate"
PAUL_PREVIEW_DIRECTORY="$focus_output/workspace" "$focus_output/validate" 2>&1 | tee "$focus_output/result.log"
PAUL_PREVIEW_DIRECTORY="$focus_output/workspace-cross-app" "$focus_output/validate" --cross-app 2>&1 | tee -a "$focus_output/result.log"
PAUL_PREVIEW_DIRECTORY="$focus_output/workspace-edit-commands" "$focus_output/validate" --edit-commands 2>&1 | tee -a "$focus_output/result.log"
if ! grep -q '^PASS: one-click embedded login' "$focus_output/result.log"; then
  print -u2 -- 'BLOCKED: native keyboard assertions did not complete'
  exit 2
fi
if ! grep -q '^PASS: inactive accessory Muse' "$focus_output/result.log"; then
  print -u2 -- 'BLOCKED: cross-application keyboard assertions did not complete'
  exit 2
fi
if ! grep -q '^PASS: owned WebKit standard editing shortcut' "$focus_output/result.log"; then
  print -u2 -- 'BLOCKED: owned WebKit editing shortcut assertions did not complete'
  exit 2
fi
