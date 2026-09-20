#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"

if grep -nE 'URLSession|data\((from|for):' Sources/PaulNotchCore/LinksStore.swift; then
  print -u2 'FAIL: link metadata networking is not part of the public 1.0 boundary.'
  exit 1
fi

found_sensitive=0
while IFS= read -r -d '' public_file; do
  if grep -nE '/Users/mac|/Applications/Paul Notch|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|github_pat_|ghp_|gho_' \
    "$public_file"; then
    found_sensitive=1
  fi
done < <(find . -type f \
  \( -name '*.swift' -o -name '*.md' -o -name '*.plist' -o -name '*.yml' -o -name '*.sh' \) \
  ! -path './.git/*' ! -path './.build/*' ! -path './dist/*' \
  ! -path './scripts/test-public-boundaries.sh' -print0)
if (( found_sensitive )); then
  print -u2 'FAIL: public tree contains a local path or credential-shaped value.'
  exit 1
fi

print -r -- 'PASS: public source boundaries'
