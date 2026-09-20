#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"

if rg -n 'URLSession|data\(from:|data\(for:' Sources/PaulNotchCore/LinksStore.swift; then
  print -u2 'FAIL: link metadata networking is not part of the public 1.0 boundary.'
  exit 1
fi

if rg -n '/Users/mac|/Applications/Paul Notch|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|github_pat_|ghp_|gho_' \
  --hidden --glob '!.git/**' --glob '!.build/**' --glob '!dist/**' \
  --glob '!scripts/test-public-boundaries.sh' .; then
  print -u2 'FAIL: public tree contains a local path or credential-shaped value.'
  exit 1
fi

print -r -- 'PASS: public source boundaries'
