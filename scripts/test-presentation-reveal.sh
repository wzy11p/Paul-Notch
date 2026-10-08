#!/bin/zsh
set -euo pipefail
presentation_root="${0:A:h:h}"
cd "$presentation_root"
presentation_output=$(mktemp -d /tmp/paul-presentation-reveal.XXXXXX)
swiftc -module-cache-path "$presentation_root/.cache/clang" -swift-version 6 -parse-as-library \
  Sources/PaulNotchCore/PresentationRevealPolicy.swift Tests/IslandMemoTests/PresentationRevealValidation.swift \
  -o "$presentation_output/PresentationRevealValidation"
"$presentation_output/PresentationRevealValidation"
print -r -- "Validation: $presentation_output"
