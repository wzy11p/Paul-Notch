#!/bin/zsh
set -euo pipefail
note_store_root="${0:A:h:h}"
cd "$note_store_root"
note_store_test_directory="$(mktemp -d /tmp/paul-note-store-validation.XXXXXX)"
swiftc -swift-version 6 -parse-as-library \
    Sources/PaulNotchCore/NoteRepository.swift \
    Sources/PaulNotchCore/NoteStore.swift \
    Tests/IslandMemoTests/NoteStoreValidation.swift \
    -o "$note_store_test_directory/NoteStoreValidation"
"$note_store_test_directory/NoteStoreValidation" "$note_store_test_directory"
print -r -- "Synthetic fixtures retained at: $note_store_test_directory"
