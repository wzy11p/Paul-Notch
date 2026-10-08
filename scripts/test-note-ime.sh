#!/bin/zsh
set -euo pipefail
ime_root="${0:A:h:h}"
cd "$ime_root"
ime_output=$(mktemp -d /tmp/paul-note-ime.XXXXXX)
swiftc -module-cache-path "$ime_root/.cache/clang" -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/NoteRepository.swift Sources/PaulNotchCore/NoteStore.swift \
    Sources/PaulNotchCore/NoteTextEditor.swift Tests/IslandMemoTests/NoteIMEValidation.swift \
    -o "$ime_output/NoteIMEValidation"
"$ime_output/NoteIMEValidation" "$ime_output"
print -r -- "Synthetic fixtures: $ime_output"
