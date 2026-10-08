#!/bin/zsh
set -euo pipefail
notices_root="${0:A:h:h}"
if [[ $# != 1 || ! -d "$1/Contents/Resources" ]]; then
  print -u2 -- 'Usage: zsh scripts/test-packaged-notices.sh <packaged Paul Notch.app>'
  exit 64
fi
for notices_file in LICENSE THIRD_PARTY_NOTICES.md; do
  test -s "$1/Contents/Resources/$notices_file"
  cmp "$notices_root/$notices_file" "$1/Contents/Resources/$notices_file"
done
print -r -- 'PASS: packaged license and third-party notices match their source'
