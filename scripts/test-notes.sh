#!/bin/zsh
set -euo pipefail
notes_root="${0:A:h:h}"
cd "$notes_root"
notes_test_directory="$(mktemp -d /tmp/paul-notes-validation.XXXXXX)"
swiftc -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/NoteRepository.swift \
    Tests/IslandMemoTests/NoteRepositoryValidation.swift \
    -o "$notes_test_directory/NoteRepositoryValidation"
"$notes_test_directory/NoteRepositoryValidation" "$notes_test_directory"
print -r -- "Synthetic fixtures retained at: $notes_test_directory"
